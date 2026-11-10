import Foundation
import RaptorRex

/// Local hostname resolution and host normalization, ported from internal/rex
/// hosts.go (the Rex equivalents are module-internal). One process-wide cache,
/// like Go's localHostnameOnce.
extension Rex {
    static let apiHostnameLock = NSLock()
    static var apiHostnameCache: String?

    /// LocalHostname resolves a display name, not server identity: Rex's Tailscale
    /// DNS label when available, else the OS hostname, else the generic label.
    /// Cached for the process lifetime — badges render it on every row.
    static func apiLocalHostname() -> String {
        apiHostnameLock.lock()
        if let cached = apiHostnameCache {
            apiHostnameLock.unlock()
            return cached
        }
        apiHostnameLock.unlock()

        var name = ""
        if let out = try? runOnBounded("", 2, "api", "call", "server.status"),
            let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
            let tailscale = obj["tailscale"] as? [String: Any] {
            let dnsName = (tailscale["dns_name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let label = dnsName.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if !label.isEmpty {
                name = label
            }
        }
        if name.isEmpty {
            var hostname = [CChar](repeating: 0, count: 1024)
            if gethostname(&hostname, hostname.count) == 0 {
                let trimmed = String(cString: hostname).trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    name = trimmed
                }
            }
        }
        if name.isEmpty {
            name = localHostLabel
        }
        apiHostnameLock.lock()
        apiHostnameCache = name
        apiHostnameLock.unlock()
        return name
    }

    /// IsLocalHost reports whether a host label refers to the local server.
    /// Rows carry the display hostname; actions must treat it as local.
    static func apiIsLocalHost(_ host: String) -> Bool {
        if host.isEmpty || host == localHostLabel {
            return true
        }
        return host.caseInsensitiveCompare(apiLocalHostname()) == .orderedSame
    }

    /// NormalizeHost collapses a local display name to the empty host so actions
    /// take the local code path.
    static func apiNormalizeHost(_ host: String) -> String {
        if apiIsLocalHost(host) {
            return ""
        }
        return host
    }
}

/// Per-host rex event streams feeding live refreshes: the handler-visible slice
/// of Rex's EventWatcher (its multi-host wiring is module-internal). One thread
/// per host follows `rex do -e <eventsScript> --all --fail-fast`; relevant lines
/// invoke onChange. Close cancels and reaps every child.
final class APIEventPump: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var hosts = Set<String>()
    private var procs = [Process]()
    private let group = DispatchGroup()
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        addHost("")
        discover()
    }

    func close() {
        lock.lock()
        cancelled = true
        let procs = self.procs
        self.procs = []
        lock.unlock()
        for p in procs where p.isRunning {
            p.terminate()
        }
        group.wait()
    }

    private func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func changed(_ host: String) {
        onChange()
    }

    private func addHost(_ host: String) {
        var host = host
        if host == Rex.localHostLabel {
            host = ""
        }
        lock.lock()
        if cancelled || hosts.contains(host) {
            lock.unlock()
            return
        }
        hosts.insert(host)
        group.enter()
        lock.unlock()
        let thread = Thread { [weak self] in
            guard let self else { return }
            defer { self.group.leave() }
            self.follow(host)
        }
        thread.name = "api-events-\(host.isEmpty ? "local" : host)"
        thread.start()
    }

    /// Discover adds configured remote servers without a finite subprocess helper
    /// or an uncancellable host-list request. Host-list output is bounded too.
    private func discover() {
        lock.lock()
        if cancelled {
            lock.unlock()
            return
        }
        lock.unlock()
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
    private func runBounded(name: String, args: [String], timeout: TimeInterval, limit: Int) -> Data? {
        guard let executable = ExecxLookup.lookup(name) else { return nil }
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
        lock.lock()
        procs.append(process)
        lock.unlock()
        defer {
            lock.lock()
            procs.removeAll { $0 === process }
            lock.unlock()
        }
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

    private func follow(_ host: String) {
        var backoff: TimeInterval = 0.1
        while !isCancelled() {
            let started = Date()
            stream(host)
            if isCancelled() {
                return
            }
            if Date().timeIntervalSince(started) > 30 {
                backoff = 0.1
            }
            // Cancellable timer wait.
            let deadline = Date().addingTimeInterval(backoff)
            while Date() < deadline && !isCancelled() {
                usleep(20_000)
            }
            if isCancelled() {
                return
            }
            backoff = min(backoff * 2, 5)
        }
    }

    private func stream(_ host: String) {
        guard !isCancelled() else { return }
        guard let executable = ExecxLookup.lookup("rex") else { return }
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
        lock.lock()
        procs.append(process)
        lock.unlock()
        defer {
            lock.lock()
            procs.removeAll { $0 === process }
            lock.unlock()
        }
        var connected = false
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        var readLoop = true
        while readLoop {
            if isCancelled() {
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
        if connected && !isCancelled() {
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

/// Bare-name PATH lookup shared by the pump (mirrors Execx.lookup, which is
/// module-public anyway).
enum ExecxLookup {
    static func lookup(_ name: String) -> String? {
        if name.contains("/") {
            return FileManager.default.fileExists(atPath: name) ? name : nil
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":") {
            let candidate = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: String(candidate)) {
                return String(candidate)
            }
        }
        return nil
    }
}
