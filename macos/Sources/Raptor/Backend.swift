import Foundation
import Darwin

struct LaunchOptions: Sendable {
    let mode: String
    let session: String
    let block: String
    let client: String
    let title: String
    let repo: String?
    let demo: Bool

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var demo = false
        var index = 0
        let supported = ["--mode", "--session", "--block", "--client", "--title", "--repo"]
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--demo" { demo = true; index += 1; continue }
            guard supported.contains(flag), index + 1 < arguments.count else {
                throw APIError.message("Invalid launch argument: \(flag)")
            }
            values[flag] = arguments[index + 1]
            index += 2
        }
        let mode = values["--mode"] ?? "dirs"
        guard ["dirs", "wt", "wt-create", "agents", "sessions"].contains(mode) else { throw APIError.message("Mode must be dirs, wt, wt-create, agents or sessions.") }
        self.mode = mode
        session = values["--session"] ?? ""
        block = values["--block"] ?? ""
        client = values["--client"] ?? ""
        title = values["--title"] ?? ""
        repo = values["--repo"].flatMap { $0.isEmpty ? nil : $0 }
        self.demo = demo
    }

    var backendArguments: [String] {
        ["--session", session, "--block", block, "--client", client, "--title", title, "api"]
    }

    /// Resident opens compare the full origin context: a repeated ⌘S with the
    /// same context toggles the panel closed.
    func matches(_ other: LaunchOptions) -> Bool {
        mode == other.mode && session == other.session && block == other.block
            && client == other.client && title == other.title && repo == other.repo && demo == other.demo
    }

    /// A resident-host socket request converted into launch options.
    init(panelRequest: PanelRequest) throws {
        var arguments: [String] = []
        if let mode = panelRequest.mode, !mode.isEmpty { arguments += ["--mode", mode] }
        if let session = panelRequest.session, !session.isEmpty { arguments += ["--session", session] }
        if let block = panelRequest.block, !block.isEmpty { arguments += ["--block", block] }
        if let client = panelRequest.client, !client.isEmpty { arguments += ["--client", client] }
        if let title = panelRequest.title, !title.isEmpty { arguments += ["--title", title] }
        if let repo = panelRequest.repo, !repo.isEmpty { arguments += ["--repo", repo] }
        try self.init(arguments: arguments)
    }
}

// One request per connection on the resident host socket: the CLI writes a
// JSON line and reads one back. The host answers on the main actor.
struct PanelRequest: Codable {
    var action: String?
    var mode: String?
    var session: String?
    var block: String?
    var client: String?
    var title: String?
    var repo: String?
}

struct PanelReply: Codable {
    var ok: Bool
    var error: String?
}

enum APIError: Error, LocalizedError, Sendable {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

enum APIValue: Encodable, Sendable {
    case text(String), flag(Bool)
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value): try container.encode(value)
        case .flag(let value): try container.encode(value)
        }
    }
}

enum AgentGroup: String, CaseIterable, Sendable {
    case blocked = "Blocked", working = "Working", idle = "Idle"
}

struct ActivityProjection: Equatable, Sendable {
    let blocked: Bool
    let working: Bool

    func shouldPulse(reduceMotion: Bool, visible: Bool) -> Bool {
        working && !reduceMotion && visible
    }

    static func workingDotOpacities(at time: TimeInterval?) -> [Double] {
        (0..<3).map { index in
            guard let time else { return 1 }
            let phase = time * .pi * 2 / 1.4 - Double(index) * .pi * 2 / 3
            return 0.4 + 0.6 * (1 + sin(phase)) / 2
        }
    }
}

struct PickerItem: Codable, Identifiable, Equatable, Sendable {
    let path: String
    var label: String? = nil
    var branch: String? = nil
    var isMain: Bool? = nil
    // Tabs & Sessions entries reuse the same shape: path carries the session
    // or window id, and the extra fields carry the sidebar context.
    var kind: String? = nil // "session" | "window" | nil (directory/worktree)
    var sessionID: String? = nil
    var sessionLabel: String? = nil
    var app: String? = nil
    var state: String? = nil
    var working: Bool? = nil
    var updatedAt: String? = nil
    var cwd: String? = nil
    var agentID: String? = nil
    var windowID: String? = nil
    var windowLabel: String? = nil
    var blockID: String? = nil
    var active: Bool? = nil
    var isLocal: Bool? = nil
    var isPinned: Bool? = nil
    var host: String? = nil
    var id: String { path }
    var isSessionEntry: Bool { kind == "session" || kind == "window" }

    var agentContext: String {
        // Leading dots are presentation only: .dotfiles and dotfiles name the same tab.
        func name(_ value: String) -> String {
            String(value.drop(while: { $0 == "." })).lowercased()
        }
        let title = name(label ?? agentID ?? "Agent")
        return [sessionLabel ?? sessionID, windowLabel ?? windowID]
            .compactMap { $0 }.filter { !$0.isEmpty && name($0) != title }.joined(separator: " / ")
    }

    var agentActivity: String? {
        switch state?.lowercased().filter({ $0.isLetter }) {
        case "working": return "Working"
        case "waiting", "blocked", "needsinput": return "Blocked"
        default: return nil
        }
    }

    var activity: ActivityProjection {
        ActivityProjection(blocked: agentActivity == "Blocked",
                           working: kind == "agent" ? agentActivity == "Working" : (working == true || agentActivity == "Working"))
    }

    var agentGroup: AgentGroup {
        activity.blocked ? .blocked : (activity.working ? .working : .idle)
    }

    var updatedDate: Date? {
        guard let updatedAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: updatedAt) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: updatedAt)
    }

    func updatedAge(now: Date = Date()) -> String? {
        guard let date = updatedDate else { return nil }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }

    var activityAccessibility: String {
        [activity.blocked ? "Blocked" : nil, activity.working ? "Working" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    var agentAccessibility: String {
        [label ?? agentID ?? "Agent", app, agentActivity, agentContext.isEmpty ? nil : agentContext]
            .compactMap { $0 }.joined(separator: ", ")
    }

    var agentHelp: String {
        [app, agentActivity, active == true ? "Current pane" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }
    enum CodingKeys: String, CodingKey {
        case path, label, branch, kind, active, isLocal = "is_local", app, state, working, cwd
        case updatedAt = "updated_at"
        case agentID = "agent_id"
        case windowID = "window_id"
        case windowLabel = "window_label"
        case blockID = "block_id"
        case isMain = "is_main"
        case sessionID = "session_id"
        case sessionLabel = "session_label"
        case isPinned = "is_pinned"
        case host
    }
}

/// One host header from the sessions response. Rows carry `host` labels that
/// match `label`, so the list can group sessions per machine.
struct HostHeader: Codable, Equatable, Sendable {
    let label: String
    let local: Bool?
    let reachable: Bool
    let error: String?
}

struct APIResult: Codable, Sendable {
    var items: [PickerItem]? = nil
    var hosts: [HostHeader]? = nil
    var targets: [String]? = nil
    var target: String? = nil
    var repo: String? = nil
    var destinationRoot: String? = nil
    var needsRepo: Bool? = nil
    var branches: [String]? = nil
    var baseBranch: String? = nil
    var suggestedBranch: String? = nil
    var path: String? = nil
    var validationError: String? = nil
    var theme: ThemePayload? = nil
    enum CodingKeys: String, CodingKey {
        case items, hosts, targets, target, repo, branches, path, theme
        case destinationRoot = "destination_root"
        case suggestedBranch = "suggested_branch"
        case needsRepo = "needs_repo", baseBranch = "base_branch", validationError = "validation_error"
    }
}

protocol BackendClient: Sendable {
    func request(_ method: String, params: [String: APIValue]) async throws -> APIResult
    func close()
    func setChangeHandler(_ handler: (@Sendable () -> Void)?) async throws -> Bool
}

extension BackendClient {
    // Request-only mocks and DemoBackend never opt into the wire API.
    func setChangeHandler(_ handler: (@Sendable () -> Void)?) async throws -> Bool { false }
}

// Serial requests and a dedicated idle reader run off the UI executor.
// The condition protects reply, event-handler and shutdown/timeout state;
// it is never held during pipe I/O.
final class ProcessBackend: BackendClient, @unchecked Sendable {
    private let queue = DispatchQueue(label: "raptor.backend.io", qos: .userInitiated)
    private let lock = NSCondition()
    private var reply: Result<APIResult, Error>?
    private var connectionFailure: String?
    private var changeHandler: (@Sendable () -> Void)?
    private let reader = DispatchQueue(label: "raptor.backend.reader", qos: .userInitiated)
    private var options: LaunchOptions // queue-only after init
    private var process: Process?
    private var closed = false
    private var activeID: Int?
    private var nextID = 0 // I/O queue only
    private var input: FileHandle? // I/O queue only
    private var output: FileHandle? // I/O queue only

    init(options: LaunchOptions) { self.options = options }

    /// Retarget the shared backend for a new picker open. A running child is
    /// retold its context in place; an idle one simply takes new launch flags.
    func updateContext(_ options: LaunchOptions) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    if process != nil {
                        _ = try exchange("context", params: [
                            "session": .text(options.session),
                            "block": .text(options.block),
                            "client": .text(options.client),
                            "title": .text(options.title),
                        ])
                    }
                    self.options = options
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func startIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw APIError.message("Backend connection is closed. Close and reopen Raptor.") }
        if process != nil { return }
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/raptor-cli")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw APIError.message("Bundled backend is missing: \(executable.path)")
        }
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        child.executableURL = executable
        child.arguments = options.backendArguments
        child.standardInput = stdin
        child.standardOutput = stdout
        // Do not merge stderr into the NDJSON stream or leave an unread stderr pipe.
        child.standardError = FileHandle.standardError
        try child.run()
        input = stdin.fileHandleForWriting
        // A backend crash must produce a write error, not terminate the app with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        output = stdout.fileHandleForReading
        process = child
        let handle = stdout.fileHandleForReading
        reader.async { [self] in readMessages(from: handle) }
    }

    /// True once the connection is broken or shut down. The resident host
    /// checks this to swap in a fresh backend; per-open flows surface the error.
    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    // Cancellation only drops reads which have not claimed the pipe. An issued
    // read must drain its matching ID; mutations always run exactly once.
    private final class QueuedRead: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func claim() throws {
            lock.lock(); defer { lock.unlock() }
            if cancelled { throw CancellationError() }
        }
    }

    func request(_ method: String, params: [String: APIValue]) async throws -> APIResult {
        let read = ["sessions", "agents", "directories", "worktrees.list", "worktrees.branches",
                    "worktrees.preview", "theme"].contains(method) ? QueuedRead() : nil
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        try read?.claim()
                        continuation.resume(returning: try exchange(method, params: params, read: read))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { read?.cancel() }
    }

    private func exchange(_ method: String, params: [String: APIValue], read: QueuedRead? = nil) throws -> APIResult {
        struct Request: Encodable { let id: Int; let method: String; let params: [String: APIValue] }
        try startIfNeeded()
        // Process launch can take time. Recheck before reserving a wire ID.
        try read?.claim()
        nextID += 1
        let id = nextID
        lock.lock()
        guard !closed else { lock.unlock(); throw APIError.message("Backend connection closed.") }
        activeID = id
        reply = nil
        lock.unlock()
        let timeout = DispatchWorkItem { [weak self] in self?.timeout(id) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        defer {
            timeout.cancel()
            lock.lock(); activeID = nil; lock.unlock()
        }
        let response: Result<APIResult, Error>
        do {
            var data = try JSONEncoder().encode(Request(id: id, method: method, params: params))
            data.append(0x0A)
            try input?.write(contentsOf: data)
            lock.lock()
            while reply == nil && !closed { lock.wait() }
            let received = reply
            let failure = connectionFailure
            lock.unlock()
            // EOF can race the waiter after a complete reply. Keep that reply;
            // the closed connection still rejects every subsequent request.
            guard let received else {
                throw APIError.message(failure ?? "Backend exited or timed out. Close and reopen Raptor. Check whether an operation completed before retrying.")
            }
            response = received
        } catch {
            close()
            throw APIError.message("Backend connection failed: \(error.localizedDescription)")
        }
        // Application errors are valid responses; keep the persistent connection open.
        return try response.get()
    }

    func setChangeHandler(_ handler: (@Sendable () -> Void)?) async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            queue.async { [self] in
                lock.lock(); changeHandler = handler; lock.unlock()
                do {
                    _ = try exchange("events.subscribe", params: ["enabled": .flag(handler != nil)])
                    continuation.resume(returning: true)
                } catch {
                    lock.lock(); changeHandler = nil; lock.unlock()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // The reader drains stdout while idle. exchange remains the only writer.
    private func readMessages(from output: FileHandle) {
        struct Message: Decodable {
            let id: Int?
            let event: String?
            let result: APIResult?
            let error: String?
        }
        var buffer = Data()
        do {
            while true {
                let chunk = try readChunk(from: output)
                guard !chunk.isEmpty else { throw APIError.message("Backend exited.") }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    guard newline <= 8 * 1024 * 1024 else { throw APIError.message("Backend response exceeds 8 MB.") }
                    let message = try JSONDecoder().decode(Message.self, from: buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if let event = message.event {
                        guard event == "rex.changed", message.id == nil, message.result == nil, message.error == nil else {
                            throw APIError.message("Invalid backend event envelope.")
                        }
                        lock.lock(); let handler = changeHandler; lock.unlock()
                        handler?()
                    } else {
                        lock.lock()
                        guard let id = message.id, id == activeID, reply == nil,
                              (message.result != nil) != (message.error != nil) else {
                            lock.unlock()
                            throw APIError.message("Backend response ID or envelope does not match the request.")
                        }
                        if let error = message.error { reply = .failure(APIError.message(error)) }
                        else { reply = .success(message.result!) }
                        lock.broadcast()
                        lock.unlock()
                    }
                }
                guard buffer.count <= 8 * 1024 * 1024 else { throw APIError.message("Backend response exceeds 8 MB.") }
            }
        } catch {
            lock.lock()
            if !closed { connectionFailure = error.localizedDescription }
            lock.unlock()
            close()
        }
    }

    private func readChunk(from output: FileHandle) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            lock.lock(); let stopped = closed; lock.unlock()
            if stopped { throw APIError.message("Backend connection closed or timed out. Check whether an operation completed before retrying.") }
            // Poll also lets shutdown interrupt a request if a descendant keeps stdout open.
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, 200)
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            // FileHandle.read(upToCount:) can wait for a full buffer on a pipe.
            // One POSIX read returns available bytes and preserves NDJSON latency.
            let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
            if count >= 0 { return Data(bytes.prefix(count)) }
            if errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
    }

    private func timeout(_ id: Int) {
        lock.lock()
        guard activeID == id else { lock.unlock(); return }
        closed = true
        changeHandler = nil
        lock.broadcast()
        let child = process
        lock.unlock()
        stop(child, input: input)
    }

    func close() {
        lock.lock()
        closed = true
        changeHandler = nil
        lock.broadcast()
        let child = process
        lock.unlock()
        stop(child, input: input)
    }

    private func stop(_ child: Process?, input: FileHandle?) {
        // EOF lets Go run deferred watcher cleanup before escalation. Its
        // SIGTERM handler also cancels subscriptions during a blocked request.
        try? input?.close()
        if let child, child.isRunning {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                guard child.isRunning else { return }
                child.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                }
            }
        }
    }
}
