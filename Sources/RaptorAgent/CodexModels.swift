import Darwin
import Foundation

/// Codex model discovery over the app-server's NDJSON protocol:
/// initialize → initialized → paginated model/list → close. No terminal
/// parsing; responses are matched by id and decoded defensively because the
/// payload shape is owned by Codex, not Raptor.
public enum CodexModels {
    /// Request deadline for the whole handshake.
    static let timeout: TimeInterval = 25

    public static func discover(codexPath: String) async -> AgentCatalog {
        let session = AppServerSession(executable: codexPath, timeout: timeout)
        do {
            try session.start()
            let initResponse = try session.request(id: 1, method: "initialize", params: [
                "clientInfo": ["name": "raptor", "version": "1.0.0"],
            ])
            if let error = initResponse["error"] {
                throw MessageError("initialize failed: " + describe(error))
            }
            session.notify(method: "initialized", params: [:])
            var models: [AgentModel] = []
            var cursor: String? = nil
            var page = 0
            repeat {
                page += 1
                var params: [String: Any] = ["limit": 100]
                if let cursor { params["cursor"] = cursor }
                let response = try session.request(id: page + 1, method: "model/list", params: params)
                if let error = response["error"] {
                    throw MessageError("model/list failed: " + describe(error))
                }
                let result = response["result"] as? [String: Any] ?? [:]
                let data = result["data"] as? [[String: Any]] ?? []
                models += data.compactMap(Self.model(from:))
                cursor = result["nextCursor"] as? String
            } while cursor != nil && page < 10
            // model/list reports catalog defaults, not config.toml overrides.
            // config/read asks Codex to resolve its own settings (including profiles).
            var config: [String: Any]?
            do {
                let response = try session.request(id: 100, method: "config/read", params: ["includeLayers": false])
                config = (response["result"] as? [String: Any])?["config"] as? [String: Any]
                session.close()
            } catch {
                session.kill()
            }
            guard let config else {
                // Older servers may not support config/read. Do not advertise a
                // catalog recommendation as the user's effective default model.
                models = models.map {
                    var model = $0
                    model.isDefault = false
                    model.defaultReasoning = ""
                    return model
                }
                return AgentCatalog(agent: "codex", models: models,
                    warning: "Codex configured defaults unavailable: config/read did not return settings")
            }
            return AgentCatalog(agent: "codex", models: applying(config: config, to: models))
        } catch {
            session.kill()
            return AgentCatalog(agent: "codex", models: [], warning: "Codex model discovery failed: " + describe(error))
        }
    }

    /// Config overrides apply to explicit model launches too. Missing config
    /// values preserve the server's model defaults; no model/effort is invented.
    static func applying(config: [String: Any], to models: [AgentModel]) -> [AgentModel] {
        let configuredModel = (config["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let effort = (config["model_reasoning_effort"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var resolved = models.map { original in
            var model = original
            if let configuredModel { model.isDefault = model.id == configuredModel }
            if let effort { model.defaultReasoning = effort }
            return model
        }
        // Custom configured models need not appear in model/list. Keep the exact
        // configured identity; do not manufacture supported reasoning levels.
        if let configuredModel, !resolved.contains(where: { $0.id == configuredModel }) {
            resolved.append(AgentModel(id: configuredModel, label: configuredModel,
                defaultReasoning: effort ?? "", isDefault: true))
        }
        return resolved
    }

    struct MessageError: Error, CustomStringConvertible {
        let text: String
        var description: String { text }
        init(_ text: String) { self.text = text }
    }

    static func describe(_ error: Any) -> String {
        if let dict = error as? [String: Any] {
            let message = dict["message"] as? String ?? String(describing: dict)
            return String(message.prefix(200))
        }
        return String(String(describing: error).prefix(200))
    }

    /// Pure for tests: maps one raw model/list `data` row.
    public static func model(from row: [String: Any]) -> AgentModel? {
        guard let id = (row["model"] as? String) ?? (row["id"] as? String), !id.isEmpty else { return nil }
        var model = AgentModel(id: id)
        if let label = row["displayName"] as? String, !label.isEmpty { model.label = label }
        if model.label.isEmpty { model.label = id }
        if let efforts = row["supportedReasoningEfforts"] as? [Any] {
            model.reasoning = efforts.compactMap { effort -> String? in
                if let value = effort as? String { return value }
                if let dict = effort as? [String: Any], let value = dict["reasoningEffort"] as? String { return value }
                return nil
            }
        }
        if let effort = row["defaultReasoningEffort"] as? String { model.defaultReasoning = effort }
        if let isDefault = row["isDefault"] as? Bool { model.isDefault = isDefault }
        return model
    }
}

/// Minimal NDJSON app-server session: write requests, collect response lines,
/// never log raw payloads (model metadata can carry provider endpoints).
final class AppServerSession {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let timeout: TimeInterval
    private var buffer = Data()
    private let queue = DispatchQueue(label: "raptor.codex.appserver")
    private var responses: [Int: [String: Any]] = [:]
    private var sawExit = false

    init(executable: String, timeout: TimeInterval) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        self.timeout = timeout
    }

    func start() throws {
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData // drain; never surfaced
        }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                self.queue.sync { self.sawExit = true }
                handle.readabilityHandler = nil
                return
            }
            self.queue.sync { self.ingest(data) }
        }
        try process.run()
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let range = buffer.range(of: Data("\n".utf8)) {
            let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = obj["id"] as? Int else { continue }
            responses[id] = obj
        }
    }

    private func waitFor(_ id: Int, deadline: TimeInterval) throws -> [String: Any] {
        while Date().timeIntervalSince1970 < deadline {
            if let response = queue.sync(execute: { responses.removeValue(forKey: id) }) {
                return response
            }
            if queue.sync(execute: { sawExit }) {
                throw CodexModels.MessageError("app-server exited before answering request \(id)")
            }
            usleep(20_000)
        }
        throw CodexModels.MessageError("timed out waiting for request \(id)")
    }

    func request(id: Int, method: String, params: [String: Any]) throws -> [String: Any] {
        let deadline = Date().timeIntervalSince1970 + timeout
        try send(["id": id, "method": method, "params": params])
        return try waitFor(id, deadline: deadline)
    }

    func notify(method: String, params: [String: Any]) {
        // Best effort: a broken pipe during discovery is reported by the next request.
        sendNoThrow(["method": method, "params": params])
    }

    private func sendNoThrow(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        stdin.fileHandleForWriting.write(Data(data + Data("\n".utf8)))
    }

    private func send(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        try stdin.fileHandleForWriting.write(Data(data + Data("\n".utf8)))
    }

    /// Normal end of discovery: closing stdin lets the server exit.
    func close() {
        try? stdin.fileHandleForWriting.close()
        let deadline = Date().timeIntervalSince1970 + 3
        while process.isRunning && Date().timeIntervalSince1970 < deadline { usleep(10_000) }
        if process.isRunning { process.terminate() }
    }

    func kill() {
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        let deadline = Date().timeIntervalSince1970 + 2
        while process.isRunning && Date().timeIntervalSince1970 < deadline { usleep(10_000) }
        if process.isRunning {
            let pid = process.processIdentifier
            Darwin.kill(pid, SIGKILL)
        }
    }
}
