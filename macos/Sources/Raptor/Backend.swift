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
        guard ["dirs", "wt", "wt-create"].contains(mode) else { throw APIError.message("Mode must be dirs, wt or wt-create.") }
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

struct PickerItem: Codable, Identifiable, Equatable, Sendable {
    let path: String
    var label: String? = nil
    var branch: String? = nil
    var isMain: Bool? = nil
    var current: Bool? = nil
    var id: String { path }
    enum CodingKeys: String, CodingKey { case path, label, branch, current; case isMain = "is_main" }
}

struct APIResult: Codable, Sendable {
    var items: [PickerItem]? = nil
    var targets: [String]? = nil
    var target: String? = nil
    var repo: String? = nil
    var destinationRoot: String? = nil
    var needsRepo: Bool? = nil
    var branches: [String]? = nil
    var baseBranch: String? = nil
    var path: String? = nil
    var validationError: String? = nil
    enum CodingKeys: String, CodingKey {
        case items, targets, target, repo, branches, path
        case destinationRoot = "destination_root"
        case needsRepo = "needs_repo", baseBranch = "base_branch", validationError = "validation_error"
    }
}

protocol BackendClient: Sendable {
    func request(_ method: String, params: [String: APIValue]) async throws -> APIResult
    func close()
}

// All blocking pipe I/O runs on one private queue, never the UI executor.
// The lock protects only shutdown/timeout state; it is never held during pipe I/O.
final class ProcessBackend: BackendClient, @unchecked Sendable {
    private let queue = DispatchQueue(label: "raptor.backend.io", qos: .userInitiated)
    private let lock = NSLock()
    private let options: LaunchOptions
    private var process: Process?
    private var closed = false
    private var activeID: Int?
    private var nextID = 0 // I/O queue only
    private var input: FileHandle? // I/O queue only
    private var output: FileHandle? // I/O queue only
    private var buffer = Data() // I/O queue only

    init(options: LaunchOptions) { self.options = options }

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
    }

    func request(_ method: String, params: [String: APIValue]) async throws -> APIResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do { continuation.resume(returning: try exchange(method, params: params)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func exchange(_ method: String, params: [String: APIValue]) throws -> APIResult {
        struct Request: Encodable { let id: Int; let method: String; let params: [String: APIValue] }
        struct Response: Decodable { let id: Int; let result: APIResult?; let error: String? }
        try startIfNeeded()
        nextID += 1
        let id = nextID
        lock.lock()
        guard !closed else { lock.unlock(); throw APIError.message("Backend connection closed.") }
        activeID = id
        lock.unlock()
        let timeout = DispatchWorkItem { [weak self] in self?.timeout(id) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        defer {
            timeout.cancel()
            lock.lock(); activeID = nil; lock.unlock()
        }
        let response: Response
        do {
            var data = try JSONEncoder().encode(Request(id: id, method: method, params: params))
            data.append(0x0A)
            try input?.write(contentsOf: data)
            while !buffer.contains(0x0A) {
                let chunk = try readChunk()
                guard !chunk.isEmpty else {
                    throw APIError.message("Backend exited or timed out. Close and reopen Raptor. Check whether an operation completed before retrying.")
                }
                buffer.append(chunk)
                guard buffer.count <= 8 * 1024 * 1024 else { throw APIError.message("Backend response exceeds 8 MB.") }
            }
            let newline = buffer.firstIndex(of: 0x0A)!
            let line = buffer[..<newline]
            response = try JSONDecoder().decode(Response.self, from: line)
            buffer.removeSubrange(...newline)
            guard response.id == id else { throw APIError.message("Backend response ID does not match the request.") }
            guard (response.result != nil) != (response.error != nil) else {
                throw APIError.message("Backend must return either a result or an error.")
            }
        } catch {
            close()
            throw APIError.message("Backend connection failed: \(error.localizedDescription)")
        }
        // Application errors are valid responses; keep the persistent connection open.
        if let error = response.error { throw APIError.message(error) }
        return response.result!
    }

    private func readChunk() throws -> Data {
        guard let output else { throw APIError.message("Backend output is unavailable.") }
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
        let child = process
        lock.unlock()
        stop(child)
    }

    func close() {
        lock.lock()
        closed = true
        let child = process
        lock.unlock()
        stop(child)
    }

    private func stop(_ child: Process?) {
        if let child, child.isRunning {
            child.terminate()
            // A stuck backend must not survive the panel.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
    }
}
