import Foundation
import RaptorRex
import RaptorWorktree

let focusQueueLimit = 32

struct FocusObservation {
    var sid: String
    var pid: Int
    var at: Date
    var initial: Bool
    var origin: Bool
}

struct FocusKey: Hashable {
    var pid: Int
    var sid: String
}

/// Bounded pending queue plus a high-water table that rejects duplicate and
/// out-of-order delivery.
final class FocusWorker {
    private let lock = NSLock()
    private var pending: [FocusObservation] = []
    private var latest: [FocusKey: FocusObservation] = [:]
    private let wake = Wakeup()

    func enqueue(_ o: FocusObservation) {
        lock.lock()
        defer { lock.unlock() }
        let key = FocusKey(pid: o.pid, sid: o.sid)
        if let last = latest[key], o.at <= last.at {
            return
        }
        if latest.count >= 128 { // Keep memory bounded even for hostile PID churn.
            var oldestKey = key
            var oldestAt = Date.distantFuture
            for (k, last) in latest where last.at < oldestAt {
                oldestKey = k
                oldestAt = last.at
            }
            latest.removeValue(forKey: oldestKey)
        }
        latest[key] = o
        // Only the same session can be coalesced. Distinct visits from one
        // client must survive slow validation (A → B → C is three visits).
        for i in pending.indices where pending[i].pid == o.pid && pending[i].sid == o.sid {
            pending.remove(at: i)
            break
        }
        if pending.count == focusQueueLimit {
            var oldest = 0
            for i in pending.indices where pending[i].at < pending[oldest].at {
                oldest = i
            }
            if o.at <= pending[oldest].at {
                return
            }
            pending.remove(at: oldest)
        }
        pending.append(o)
        wake.notify()
    }

    func pop() -> FocusObservation? {
        lock.lock()
        defer { lock.unlock() }
        if pending.isEmpty {
            return nil
        }
        return pending.removeFirst()
    }

    func wait(_ timeout: TimeInterval) {
        wake.wait(timeout)
    }

    // Test seams (Go tests read pending/latest directly).
    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    var latestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return latest.count
    }

    var lastPendingPID: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.last?.pid ?? 0
    }
}

func fullSessionID(_ s: String) -> Bool {
    guard s.hasPrefix("session:"), s.count > "session:".count, s.count <= 256 else { return false }
    for scalar in s.unicodeScalars {
        let isControl = scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value)
        if isControl || scalar.properties.isWhitespace || scalar.value == 0x85 || scalar.value == 0xA0 {
            return false
        }
    }
    return true
}

extension Handler {
    /// Rank maps are detached and immutable after publication. Never load history
    /// from sessions queries, live events, or the observation worker.
    func captureRecency(_ visitOrigin: Bool) {
        cacheMu.lock()
        defer { cacheMu.unlock() }
        let load = loadRecency ?? { Rex.loadSessionRecency() }
        // SessionRecency is a value type: assignment detaches the snapshot, so a
        // caller mutating its source map cannot change the published ranks.
        ranks = load()
        if visitOrigin && fullSessionID(ctx.session), let focus {
            focus.enqueue(FocusObservation(sid: ctx.session, pid: 0, at: Date(), initial: false, origin: true))
        }
    }

    func observeFocus(_ params: [UInt8]) throws -> MethodResult {
        if params.count > 2048 {
            throw MessageError("observation too large")
        }
        var parser = JSONParser(params)
        let obj: JSONValue
        do {
            obj = try parser.parseTop().value
        } catch {
            throw MessageError("invalid character looking for beginning of value")
        }
        let sessionID = try Params.string(obj, "session_id")
        let clientPID = try Params.string(obj, "client_pid")
        let observedAt = try Params.string(obj, "observed_at")
        let initial = try Params.bool(obj, "initial")
        guard let pid = Int(clientPID), pid > 0, clientPID.count <= 10, fullSessionID(sessionID) else {
            throw MessageError("invalid focus observation")
        }
        guard let at = parseRFC3339(observedAt),
            at > Date(timeIntervalSince1970: 0), at <= Date() else {
            throw MessageError("invalid observed_at")
        }
        cacheMu.lock()
        if let focus {
            focus.enqueue(FocusObservation(sid: sessionID, pid: pid, at: at, initial: initial, origin: false))
        }
        cacheMu.unlock()
        return .empty
    }

    func startFocusWorker(_ cancel: CancelToken) -> () -> Void {
        let worker = FocusWorker()
        cacheMu.lock()
        focus = worker
        let validateHook = validateFocus
        let resolveHook = resolveFocus
        let recordHook = recordFocus
        cacheMu.unlock()
        let validate = validateHook ?? { _, pid in
            Rex.validateFocusClientPIDContext(parentTimeout: 0, pid: pid)
        }
        let resolve = resolveHook ?? { [weak self] sid in
            self?.resolveFocusHost(sid) ?? ("", false)
        }
        let record = recordHook ?? { host, sid, at, initial in
            try? Rex.recordSessionVisit(host, sid, at, initial)
        }
        let done = Broadcast()
        let thread = Thread {
            defer { done.fire() }
            while !cancel.isCancelled {
                worker.wait(0.1)
                while !cancel.isCancelled {
                    guard let o = worker.pop() else {
                        break
                    }
                    if !o.origin && !validate(cancel, o.pid) {
                        continue
                    }
                    if cancel.isCancelled {
                        return
                    }
                    let (host, ok) = resolve(o.sid)
                    if !ok || cancel.isCancelled {
                        continue
                    }
                    if o.origin && !host.isEmpty && host != Rex.localHostLabel {
                        continue
                    }
                    // History sorts by observation time. A completed older visit
                    // remains useful behind newer visits; it must not be discarded.
                    if !cancel.isCancelled {
                        record(host, o.sid, o.at, o.initial)
                    }
                }
            }
        }
        thread.name = "api-focus-worker"
        thread.start()
        return { [weak self] in
            guard let self else { return }
            self.cacheMu.lock()
            if self.focus === worker {
                self.focus = nil
            }
            self.cacheMu.unlock()
            cancel.cancel()
            done.wait(until: Date().addingTimeInterval(10))
        }
    }

    /// Cached full IDs carry host identity. A cache miss uses native read-only
    /// listings, never agent snapshots or client.session_ids attachments.
    func resolveFocusHost(_ sid: String) -> (host: String, ok: Bool) {
        cacheMu.lock()
        var hosts = Set<String>()
        for item in launcher.items ?? [] where item.kind == "session" && item.sessionID == sid {
            var host = item.host
            if item.local || host == Rex.localHostLabel {
                host = ""
            }
            hosts.insert(host)
        }
        cacheMu.unlock()
        if hosts.count > 1 {
            return ("", false)
        }
        if let host = hosts.first {
            return (host, true)
        }
        return resolveNativeFocusHost(sid)
    }
}

/// One total budget also bounds configurations with many/unreachable hosts.
/// Fail closed if any listing fails: uniqueness cannot then be established.
func resolveNativeFocusHost(_ sid: String) -> (host: String, ok: Bool) {
    let deadline = Date().addingTimeInterval(10)
    func list(_ host: String) -> (match: Bool, valid: Bool) {
        var args = ["ls", "--json"]
        if !host.isEmpty {
            args = ["-S", host, "--timeout", "2s"] + args
        }
        guard let data = focusRead(deadline: deadline, args: args),
            let sessions = data["sessions"] as? [[String: Any]] else {
            return (false, false)
        }
        for session in sessions {
            if session["session_id"] as? String == sid {
                return (true, true)
            }
        }
        return (false, true)
    }
    let (foundLocal, localValid) = list("")
    if !localValid {
        return ("", false)
    }
    var found = foundLocal
    guard let hostsData = focusRead(deadline: deadline, args: ["api", "call", "hosts.list"]),
        let hostList = hostsData["hosts"] as? [[String: Any]] else {
        return ("", false)
    }
    var selected = ""
    var seen = Set<String>(["", Rex.localHostLabel])
    for host in hostList {
        guard let label = host["label"] as? String else { continue }
        if seen.contains(label) {
            continue
        }
        seen.insert(label)
        let (match, valid) = list(label)
        if !valid || (match && found) {
            return ("", false)
        }
        if match {
            selected = label
            found = true
        }
    }
    return (selected, found && Date() < deadline)
}

func focusRead(deadline: Date, args: [String]) -> [String: Any]? {
    let remaining = deadline.timeIntervalSinceNow
    guard remaining > 0 else { return nil }
    guard let data = Rex.runCapture(timeout: min(remaining, 3), name: "rex", args: args) else {
        return nil
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}
