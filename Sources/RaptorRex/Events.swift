import Foundation
import RaptorExecx

/// EventChange is a coalesced invalidation, not a state snapshot. Host identifies
/// one cause (empty for local). A queued change can merge causes from other hosts;
/// consumers must refresh all watched hosts, each with its own host-scoped API.
public struct EventChange: Equatable {
    public var host: String

    public init(host: String) {
        self.host = host
    }
}

/// Bounded channel standing in for Go's `chan EventChange` with buffer size 1:
/// sends when full are dropped (the non-blocking send default case), receives
/// block until an item or timeout.
public final class ChangeChannel {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var pending: [EventChange] = []

    public init() {}

    func send(_ change: EventChange) {
        lock.lock()
        if pending.count >= 1 {
            lock.unlock()
            return
        }
        pending.append(change)
        lock.unlock()
        semaphore.signal()
    }

    /// Blocks up to timeout for one change; nil on timeout.
    public func wait(timeout: TimeInterval) -> EventChange? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        let change = pending.isEmpty ? nil : pending.removeFirst()
        lock.unlock()
        return change
    }

    /// Go's len(ch) for tests.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }
}

/// EventWatcher owns long-lived CLI children. Close cancels and reaps all of
/// them. Its bounded channel deliberately merges bursts: snapshots are truth.
public final class EventWatcher {
    /// Receive side of the Go Changes channel.
    public let changes: ChangeChannel

    private let mu = NSLock()
    private var cancelled = false
    private var hosts = Set<String>()
    private var procs = [Process]()
    private let group = DispatchGroup()

    /// Internal for tests (Go's &EventWatcher{ctx, changes} literal).
    init(changes: ChangeChannel) {
        self.changes = changes
    }

    deinit {
        mu.lock()
        let procs = self.procs
        self.procs = []
        mu.unlock()
        for p in procs where p.isRunning {
            p.terminate()
        }
    }

    func changed(_ host: String) {
        changes.send(EventChange(host: host))
    }

    /// Go's len(changes) for tests.
    var pendingChangeCount: Int {
        changes.count
    }

    /// Go's ctx.Err() != nil.
    var isCancelled: Bool {
        mu.lock()
        defer { mu.unlock() }
        return cancelled
    }

    func register(_ p: Process) {
        mu.lock()
        procs.append(p)
        mu.unlock()
    }

    func unregister(_ p: Process) {
        mu.lock()
        procs.removeAll { $0 === p }
        mu.unlock()
    }
}

public extension Rex {
    /// Go's WatchEvents: creates the watcher and starts following the local host.
    /// The Go parent context has no Swift equivalent; Close is the cancel signal.
    static func watchEvents() -> EventWatcher {
        let watcher = EventWatcher(changes: ChangeChannel())
        watcher.addHost("")
        return watcher
    }
}

extension EventWatcher {
    func addHost(_ host: String) {
        var host = host
        if host == Rex.localHostLabel {
            host = ""
        }
        mu.lock()
        if cancelled || hosts.contains(host) {
            mu.unlock()
            return
        }
        hosts.insert(host)
        group.enter()
        mu.unlock()
        let thread = Thread { [weak self] in
            guard let self else { return }
            defer { self.group.leave() }
            self.follow(host)
        }
        thread.name = "rex-events-\(host.isEmpty ? "local" : host)"
        thread.start()
    }

    /// Discover adds configured remote servers without a finite subprocess helper
    /// or an uncancellable host-list request. Host-list output is bounded too.
    func discover() {
        mu.lock()
        if cancelled {
            mu.unlock()
            return
        }
        mu.unlock()
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            guard let data = self.runBounded(name: "rex",
                args: ["--autostart=false", "api", "call", "hosts.list"],
                timeout: 10, limit: 1 << 20) else {
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hosts = obj["hosts"] as? [[String: Any]] else {
                return
            }
            for h in hosts {
                if let label = h["label"] as? String, !label.isEmpty {
                    self.addHost(label)
                }
            }
        }
    }

    /// Go: exec.CommandContext + io.ReadAll(io.LimitReader(..., 1<<20)). Runs with
    /// a timeout and a byte cap; the child is killed on either bound.
    func runBounded(name: String, args: [String], timeout: TimeInterval, limit: Int) -> Data? {
        guard let executable = Execx.lookup(name: name) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        register(process)
        defer { unregister(process) }
        var data = Data()
        let deadline = Date().addingTimeInterval(timeout)
        let handle = pipe.fileHandleForReading
        while data.count < limit {
            if Date() >= deadline {
                if process.isRunning { process.terminate() }
                break
            }
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        if data.count > limit {
            data = data.prefix(limit)
        }
        return data
    }

    /// Go's ctx.Done(); returns once Close has been requested.
    public func isDone() -> Bool {
        isCancelled
    }

    /// Close cancels and reaps all children; safe to call repeatedly (Go's
    /// cancel + wg.Wait()).
    public func close() {
        mu.lock()
        cancelled = true
        let procs = self.procs
        mu.unlock()
        for p in procs where p.isRunning {
            p.terminate()
        }
        group.wait()
    }

    func follow(_ host: String) {
        var backoff: TimeInterval = 0.1
        while !isCancelled {
            let started = Date()
            stream(host)
            if isCancelled {
                return
            }
            if Date().timeIntervalSince(started) > 30 {
                backoff = 0.1
            }
            // Cancellable timer wait.
            let deadline = Date().addingTimeInterval(backoff)
            while Date() < deadline && !isCancelled {
                usleep(20_000)
            }
            if isCancelled {
                return
            }
            backoff = min(backoff * 2, 5)
        }
    }

    func stream(_ host: String) {
        guard !isCancelled else { return }
        guard let executable = Execx.lookup(name: "rex") else { return }
        var args = ["--autostart=false", "--timeout", "2s"]
        if !host.isEmpty {
            args.append(contentsOf: ["-S", host])
        }
        args.append(contentsOf: ["do", "-e", Rex.eventsScript, "--all", "--fail-fast"])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return
        }
        register(process)
        defer { unregister(process) }
        var connected = false
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        var readLoop = true
        while readLoop {
            if isCancelled {
                if process.isRunning { process.terminate() }
            }
            let chunk = handle.availableData
            if chunk.isEmpty {
                break
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                handleLine(line, host: host, connected: &connected)
                if buffer.count > 1 << 20 {
                    // Go's bufio.Scanner fails on oversized tokens and ends the stream.
                    readLoop = false
                    break
                }
            }
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        // Invalidate once when an established stream drops; failed reconnects
        // must not turn into periodic state polling while the server is offline.
        if connected && !isCancelled {
            changed(host)
        }
    }

    private func handleLine(_ line: Data, host: String, connected: inout Bool) {
        struct EventLine: Decodable {
            var type: String?
        }
        if let event = try? JSONDecoder().decode(EventLine.self, from: line), let type = event.type {
            if type == "raptor_ready" {
                connected = true
                changed(host)
                return
            }
            if type == "hosts_changed" {
                discover()
            }
        }
        if Rex.relevantEvent(line) {
            changed(host)
        }
    }
}

public extension Rex {
    /// Ignore CLI/client churn: snapshot CLI requests themselves generate these
    /// events, and feeding them back would create a refresh loop.
    static func relevantEvent(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return false
        }
        let payload = obj["payload"] as? [String: Any] ?? [:]
        switch type {
        case "session_event":
            if let event = payload["event"], let encoded = try? JSONSerialization.data(withJSONObject: event) {
                return relevantEvent(encoded)
            }
            return false
        case "block_event":
            switch payload["name"] as? String {
            case "title_changed", "program_status_changed", "program_status_removed", "pwd_changed", "process_changed", "child_exited":
                return true
            default:
                return false
            }
        case "activity_changed", "session_created", "session_destroyed", "session_moved", "session_label_changed", "session_view_changed", "active_window_changed", "window_created", "window_closed", "window_destroyed", "window_label_changed", "block_created", "block_closed", "block_destroyed", "layout_changed", "hosts_changed", "tailscale_status_changed", "server_connected", "server_disconnected":
            return true
        default:
            return false
        }
    }
}
