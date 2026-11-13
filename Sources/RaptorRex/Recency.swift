import Foundation
import RaptorExecx
import RaptorPaths

public extension Rex {
    static let recencyLimit = 256
    static let recencyLockTimeout: TimeInterval = 0.25
    static let recencyLockRetry: TimeInterval = 0.001

    /// Process start time, mirroring Go's package var captured at init.
    static let recencyStartedAt = Date()
}

/// SessionRecency is a detached rank snapshot. Treat it as immutable.
public struct SessionRecency: Equatable {
    var ranks: [String: Int] = [:]

    public init() {}

    public init(_ ranks: [String: Int]) {
        self.ranks = ranks
    }

    public var count: Int { ranks.count }

    /// Rank returns zero for the newest visit and max int for unknown sessions.
    public func rank(_ host: String, _ sessionID: String) -> Int {
        let (host, sessionID, ok) = Rex.recencyTarget(host, sessionID)
        if ok, let rank = ranks[Rex.recencyKey(host, sessionID)] {
            return rank
        }
        return Int.max
    }
}

public struct RecencyVisit: Equatable {
    public var host: String
    public var sessionID: String
    public var at: Date

    public init(host: String = "", sessionID: String = "", at: Date = Rex.zeroTime) {
        self.host = host
        self.sessionID = sessionID
        self.at = at
    }
}

public struct RecencyDocument: Equatable {
    public var version: Int
    public var visits: [RecencyVisit]

    public init(version: Int = 0, visits: [RecencyVisit] = []) {
        self.version = version
        self.visits = visits
    }
}

public extension Rex {
    static func recencyKey(_ host: String, _ sessionID: String) -> String {
        host + "\u{00}" + sessionID
    }

    static func recencyTarget(_ host: String, _ sessionID: String) -> (String, String, Bool) {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        if host == localHostLabel {
            host = ""
        }
        // Rex host labels can contain spaces; session IDs cannot.
        let hostValid = validRecencyString(host, allowSpaces: true)
        let sessionValid = validRecencyString(sessionID, allowSpaces: false)
            && sessionID.hasPrefix("session:")
            && sessionID.count > "session:".count
        return (host, sessionID, hostValid && sessionValid)
    }

    /// Mirrors Go's strings.ContainsFunc control/space rejection with a byte cap.
    static func validRecencyString(_ s: String, allowSpaces: Bool) -> Bool {
        guard s.utf8.count <= 4096 else { return false }
        for scalar in s.unicodeScalars {
            let isControl = scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
            let isSpace = scalar.properties.isWhitespace
            if isControl || (!allowSpaces && isSpace) {
                return false
            }
        }
        return true
    }

    /// LoadSessionRecency reads history only. It never calls Rex or changes history.
    static func loadSessionRecency() -> SessionRecency {
        let (doc, _, error) = readRecency(recencyPath(), Date())
        var ranks: [String: Int] = [:]
        if error != nil {
            return SessionRecency(ranks)
        }
        for (i, visit) in doc.visits.enumerated() {
            ranks[recencyKey(visit.host, visit.sessionID)] = i
        }
        return SessionRecency(ranks)
    }

    /// Returns (document, damaged original bytes, error). A nil error with a nil
    /// damaged payload means the file did not exist yet.
    static func readRecency(_ path: String, _ now: Date) -> (RecencyDocument, Data?, Error?) {
        var doc = RecencyDocument(version: 1)
        guard let data = FileManager.default.contents(atPath: path) else {
            return (doc, nil, nil)
        }
        // Go's json.Unmarshal treats the literal `null` as a zero document, so
        // version 0 fails the version check below rather than parse failing.
        let trimmed = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "null" {
            doc = RecencyDocument(version: 0)
            return (doc, data, RexError("unsupported session history version 0"))
        }
        if trimmed != "null" {
            guard let obj = try? JSONSerialization.jsonObject(with: data) else {
                return (doc, data, RexError("invalid JSON"))
            }
            guard let dict = obj as? [String: Any] else {
                return (doc, data, RexError("invalid document"))
            }
            doc = RecencyDocument(
                version: dict["version"] as? Int ?? 0,
                visits: [])
            if let visits = dict["visits"] as? [[String: Any]] {
                for visit in visits {
                    let atRaw = visit["at"] as? String ?? ""
                    let at = parseRFC3339(atRaw) ?? zeroTime
                    doc.visits.append(RecencyVisit(
                        host: visit["host"] as? String ?? "",
                        sessionID: visit["session_id"] as? String ?? "",
                        at: at))
                }
            } else if dict["visits"] != nil {
                return (doc, data, RexError("invalid visits"))
            }
        }
        if doc.version != 1 {
            return (doc, data, RexError("unsupported session history version \(doc.version)"))
        }
        var seen = Set<String>()
        for visit in doc.visits {
            let (host, id, ok) = recencyTarget(visit.host, visit.sessionID)
            let key = recencyKey(host, id)
            if !ok || host != visit.host || id != visit.sessionID || !validRecencyTime(visit.at, now) || seen.contains(key) {
                return (doc, data, RexError("invalid session history visit"))
            }
            seen.insert(key)
        }
        sortRecency(&doc)
        return (doc, data, nil)
    }

    static func validRecencyTime(_ at: Date, _ now: Date) -> Bool {
        at > Date(timeIntervalSince1970: 0) && at <= now
    }

    static func sortRecency(_ doc: inout RecencyDocument) {
        doc.visits.sort { a, b in
            if a.at != b.at {
                return a.at > b.at
            }
            return recencyKey(a.host, a.sessionID) < recencyKey(b.host, b.sessionID)
        }
        if doc.visits.count > recencyLimit {
            doc.visits = Array(doc.visits.prefix(recencyLimit))
        }
    }

    static func recencyPath() -> String {
        RaptorPaths.cacheDir() + "/session-recency.json"
    }

    /// RecordSessionVisit merges a validated focus observation. Times must describe
    /// when focus was read, not when a queued observation was delivered. An initial
    /// read cannot replace same-host visits recorded during this process's lifetime.
    /// Older observations retain their chronological position; they cannot promote
    /// a session above a newer visit or replace its newer timestamp.
    /// Lock contention returns an error after a short wait; history is optional.
    static func recordSessionVisit(_ host: String, _ sessionID: String, _ observedAt: Date, _ initial: Bool) throws {
        try recordSessionVisit(host, sessionID, observedAt, initial, Date(), recencyStartedAt)
    }

    /// RecordSessionUse records an acknowledged selection, without additional Rex calls.
    static func recordSessionUse(_ host: String, _ sessionID: String) throws {
        let now = Date()
        try recordSessionVisit(host, sessionID, now, false, now, recencyStartedAt)
    }

    static func recordSessionVisit(_ host: String, _ sessionID: String, _ at: Date, _ initial: Bool, _ now: Date, _ startedAt: Date) throws {
        let (host, sessionID, ok) = recencyTarget(host, sessionID)
        // Short fixture IDs must never enter the user's real history.
        guard ok, validRecencyTime(at, now) else { return }
        let path = recencyPath()
        let fd = open(path + ".lock", O_CREAT | O_RDWR, mode_t(0o600))
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
        }
        defer { close(fd) }
        try lockRecency(fd)
        defer { flock(fd, LOCK_UN) }
        // Other writers may have committed after this call captured its timestamp.
        // Validate disk timestamps against the clock after acquiring the lock.
        var readNow = Date()
        if now > readNow {
            readNow = now
        }
        var (doc, damaged, error) = readRecency(path, readNow)
        if let error {
            guard let damaged else { throw error }
            // Preserve the exact original, including unsupported future documents.
            try saveRecencyFile(path + ".backup-", data: damaged, replace: false)
            doc = RecencyDocument(version: 1)
        }
        for visit in doc.visits where visit.host == host {
            if (visit.sessionID == sessionID && at <= visit.at) || (initial && visit.at >= startedAt) {
                return
            }
        }
        doc.visits = doc.visits.filter { $0.host != host || $0.sessionID != sessionID }
        doc.visits.append(RecencyVisit(host: host, sessionID: sessionID, at: at))
        sortRecency(&doc)
        let data = encodeRecency(doc)
        try saveRecencyFile(path, data: data, replace: true)
    }

    /// Keep the same lock inode across writers, including after a timeout. The lock
    /// covers the complete read/merge/rename so concurrent updates remain atomic.
    static func lockRecency(_ fd: Int32) throws {
        let deadline = Date().addingTimeInterval(recencyLockTimeout)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                return
            }
            let e = errno
            if e != EWOULDBLOCK && e != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EPERM)
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                // Go wraps the EWOULDBLOCK flock error into the timeout error.
                throw POSIXError(.EWOULDBLOCK)
            }
            usleep(useconds_t(min(recencyLockRetry, remaining) * 1_000_000))
        }
    }

    static func saveRecencyFile(_ path: String, data: Data, replace: Bool) throws {
        let dir = (path as NSString).deletingLastPathComponent
        var pattern = (path as NSString).lastPathComponent
        if replace {
            pattern += ".tmp-"
        }
        let name = (dir as NSString).appendingPathComponent(pattern + UUID().uuidString)
        let fd = open(name, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600))
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
        }
        var keep = false
        defer {
            close(fd)
            if !keep {
                remove(name)
            }
        }
        let bytes = [UInt8](data)
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBufferPointer { buffer -> Int in
                write(fd, buffer.baseAddress! + written, bytes.count - written)
            }
            if n <= 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            written += n
        }
        guard fsync(fd) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if replace {
            guard rename(name, path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return
        }
        keep = true
    }

    static func encodeRecency(_ doc: RecencyDocument) -> Data {
        var out = "{\"version\":\(doc.version),\"visits\":["
        let visits = doc.visits.map { visit -> String in
            "{\"host\":\(jsonQuote(visit.host)),\"session_id\":\(jsonQuote(visit.sessionID)),\"at\":\"\(formatRFC3339(visit.at))\"}"
        }
        out += visits.joined(separator: ",")
        out += "]}"
        return Data(out.utf8)
    }

    static func recordSelectedSession(_ host: String, _ action: String, _ kv: [String]) {
        guard action == "session.select" else { return }
        var id = ""
        for arg in kv where arg.hasPrefix("session_id=") {
            id = String(arg.dropFirst("session_id=".count))
        }
        if !id.isEmpty {
            _ = try? recordSessionUse(host, id)
        }
    }

    /// ValidateFocusClientPID accepts only a connected local Unix app peer with the
    /// exact PID. Call it from a background focus worker, never a ranking query.
    static func validateFocusClientPID(_ pid: Int) -> Bool {
        validateFocusClientPIDContext(parentTimeout: 0, pid: pid)
    }

    /// Go takes a cancellable parent context; the Swift port takes the parent's
    /// deadline instead (the only cancellation signal its callers need).
    static func validateFocusClientPIDContext(parentTimeout: TimeInterval, pid: Int) -> Bool {
        if pid <= 0 { return false }
        let timeout = parentTimeout > 0 ? min(parentTimeout, 2) : 2
        guard let out = runCapture(timeout: timeout, name: "rex",
            args: ["--autostart=false", "api", "call", "client.list", "{\"kinds\":[\"app\"]}"]) else {
            return false
        }
        guard let obj = try? JSONSerialization.jsonObject(with: out) as? [String: Any],
              let clients = obj["clients"] as? [[String: Any]] else {
            return false
        }
        for client in clients {
            let info = client["info"] as? [String: Any] ?? [:]
            let principal = client["principal"] as? [String: Any] ?? [:]
            if info["kind"] as? String == "app"
                && (client["connection_state"] as? String ?? "") != "lost"
                && principal["kind"] as? String == "peer"
                && principal["transport"] as? String == "unix"
                && (principal["pid"] as? Int ?? 0) == pid {
                return true
            }
        }
        return false
    }

    /// Output-only capture: Execx isolates stdin with /dev/null so CLI children
    /// cannot change the resident API input pipe's file-status flags.
    /// Process capture with a hard timeout: on expiry the child is terminated and
    /// nil is returned (Go's CommandContext + Output error path). Output is read
    /// on a side queue so the deadline is polled while blocked children keep the
    /// pipe open.
    static func runCapture(timeout: TimeInterval, name: String, args: [String]) -> Data? {
        guard let r = try? Execx.run(dir: "", timeout: timeout, name: name, args: args), r.code == 0 else {
            return nil
        }
        return Data(r.stdout.utf8)
    }
}
