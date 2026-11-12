import Foundation
import RaptorExecx
import RaptorPaths

/// SessionEntry describes one selectable row in the Sessions view.
/// Kind "session" jumps to a session; kind "window" jumps to one of its tabs.
/// SessionID links each tab to its parent session row. Path mirrors ID so native
/// clients can reuse their item decode shape. Host carries the display label of
/// the server that owns the row ("This Mac" locally).
public struct SessionEntry: Equatable, Encodable {
    public var kind: String // "session" | "window"
    public var id: String
    public var path: String
    public var sessionID: String
    public var label: String
    public var sessionLabel: String
    public var active: Bool
    public var host: String
    public var state: String
    public var working: Bool
    public var unreadDone: Bool = false
    public var completionSources: [CompletionSource] = []

    public init(
        kind: String = "", id: String = "", path: String = "", sessionID: String = "",
        label: String = "", sessionLabel: String = "", active: Bool = false, host: String = "",
        state: String = "", working: Bool = false
    ) {
        self.kind = kind
        self.id = id
        self.path = path
        self.sessionID = sessionID
        self.label = label
        self.sessionLabel = sessionLabel
        self.active = active
        self.host = host
        self.state = state
        self.working = working
    }

    enum CodingKeys: String, CodingKey {
        case kind, id, path
        case sessionID = "session_id"
        case label
        case sessionLabel = "session_label"
        case active, host, state, working
        case unreadDone = "unread_done"
        case completionSources = "_completion_sources"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(id, forKey: .id)
        try c.encode(path, forKey: .path)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(label, forKey: .label)
        try c.encode(sessionLabel, forKey: .sessionLabel)
        try c.encode(active, forKey: .active)
        try c.encode(host, forKey: .host)
        if !state.isEmpty {
            try c.encode(state, forKey: .state)
        }
        if unreadDone { try c.encode(true, forKey: .unreadDone) }
        if !completionSources.isEmpty { try c.encode(completionSources, forKey: .completionSources) }
        if working {
            try c.encode(working, forKey: .working)
        }
    }
}

/// HostGroup is one host's slice of the Sessions view. Unreachable hosts keep
/// their header row and an error string so the group does not silently vanish.
public struct HostGroup: Equatable, Encodable {
    public var label: String
    public var local: Bool
    public var reachable: Bool
    public var error: String
    public var entries: [SessionEntry]

    public init(label: String = "", local: Bool = false, reachable: Bool = false, error: String = "", entries: [SessionEntry] = []) {
        self.label = label
        self.local = local
        self.reachable = reachable
        self.error = error
        self.entries = entries
    }

    enum CodingKeys: String, CodingKey {
        case label, local, reachable, error, entries
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        if local {
            try c.encode(local, forKey: .local)
        }
        try c.encode(reachable, forKey: .reachable)
        if !error.isEmpty {
            try c.encode(error, forKey: .error)
        }
        try c.encode(entries, forKey: .entries)
    }
}

struct APISession: Decodable {
    var sessionID: String
    var label: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = (try? c.decode(String.self, forKey: .sessionID)) ?? ""
        label = (try? c.decode(String.self, forKey: .label)) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case label
    }
}

struct APIWindow: Equatable {
    var windowID: String
    var label: String
    var focusedBlockID: String
    var active: Bool

    init(windowID: String = "", label: String = "", focusedBlockID: String = "", active: Bool = false) {
        self.windowID = windowID
        self.label = label
        self.focusedBlockID = focusedBlockID
        self.active = active
    }
}

/// Window list of one session, lenient like Go's zero values.
struct SessionViewResponse: Decodable {
    var activeWindowID: String
    var windows: [APIWindowDecoded]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activeWindowID = (try? c.decode(String.self, forKey: .activeWindowID)) ?? ""
        windows = (try? c.decodeIfPresent([APIWindowDecoded].self, forKey: .windows)) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case activeWindowID = "active_window_id"
        case windows
    }
}

struct APIWindowDecoded: Decodable {
    var windowID: String
    var label: String
    var focusedBlockID: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windowID = (try? c.decode(String.self, forKey: .windowID)) ?? ""
        label = (try? c.decode(String.self, forKey: .label)) ?? ""
        focusedBlockID = (try? c.decode(String.self, forKey: .focusedBlockID)) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case windowID = "window_id"
        case label
        case focusedBlockID = "focused_block_id"
    }
}

final class ValueBox<T> {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: T?

    func set(_ v: T) {
        lock.lock()
        value = v
        lock.unlock()
        semaphore.signal()
    }

    /// Blocks until set.
    func get() -> T {
        semaphore.wait()
        lock.lock()
        defer { lock.unlock() }
        return value!
    }
}

public extension Rex {
    /// Session listing budgets: remote hosts answer over SSH and may be down;
    /// sessions and activity fetch in parallel so the slower one hides inside the
    /// faster one. A host that misses its budget keeps its header with a short
    /// error instead of stalling the whole view.
    static let remoteListTimeout = 3
    static let remoteAgentTimeout = 4
    static let localAgentTimeout = 3

    /// sessionWindowWorkers limits concurrent Rex processes per session listing.
    static let sessionWindowWorkers = 4

    /// ApplySessionActivity replaces activity in place. Session rows match SessionID;
    /// window rows also match the agent's WindowID against the row ID.
    static func applySessionActivity(_ entries: inout [SessionEntry], _ agents: [AgentEntry]) {
        for i in entries.indices {
            entries[i].unreadDone = false
            entries[i].completionSources = []
            entries[i].state = ""
            entries[i].working = false
            for agent in agents {
                if entries[i].sessionID.isEmpty || entries[i].sessionID != agent.sessionID ||
                    (entries[i].kind != "session" && (entries[i].kind != "window" || entries[i].id != agent.windowID)) {
                    continue
                }
                entries[i].unreadDone = entries[i].unreadDone || agent.unreadDone
                if let source = agent.completionSource { entries[i].completionSources.append(source) }
                var state = agent.state
                if state != "blocked" && state != "working" {
                    state = "idle"
                }
                if entries[i].state.isEmpty || agentStateRank(state) < agentStateRank(entries[i].state) {
                    entries[i].state = state
                }
                entries[i].working = entries[i].working || state == "working"
            }
        }
    }

    /// SessionEntries lists sessions and their windows in sidebar order: each
    /// session is followed by its tabs. A window is active when it is the
    /// session's active window; a session is active when it is the origin session.
    static func sessionEntries(_ originSession: String) throws -> [SessionEntry] {
        let out = try run("ls", "--json")
        guard let data = decodeJSON(SessionsResponse.self, from: Data(out.utf8)), let sessions = data.sessions else {
            throw RexError("could not parse the session list: invalid JSON")
        }
        // Fetch into separate slots, then assemble rows in sidebar order. Failed
        // sessions keep their session row but have no window rows.
        final class Slot {
            var windows: [APIWindow] = []
        }
        let slots = (0..<sessions.count).map { _ in Slot() }
        let semaphore = DispatchSemaphore(value: min(sessionWindowWorkers, sessions.count))
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "rex.sessionWindows", attributes: .concurrent)
        for i in 0..<sessions.count {
            semaphore.wait()
            group.enter()
            queue.async {
                defer {
                    semaphore.signal()
                    group.leave()
                }
                guard let windows = try? sessionWindows(sessions[i].sessionID) else { return }
                var resolved = windows
                // Resolve titles serially inside each worker: at most four Rex
                // calls at once, even for sessions with many unnamed tabs.
                for j in resolved.indices {
                    resolved[j].label = sessionWindowLabel(sessions[i].sessionID, resolved[j])
                }
                slots[i].windows = resolved
            }
        }
        group.wait()

        var entries: [SessionEntry] = []
        entries.reserveCapacity(sessions.count * 2)
        for (i, session) in sessions.enumerated() {
            entries.append(SessionEntry(
                kind: "session", id: session.sessionID, path: session.sessionID, sessionID: session.sessionID,
                label: session.label, sessionLabel: session.label,
                active: sameSession(session.sessionID, originSession)))
            for window in slots[i].windows {
                entries.append(SessionEntry(
                    kind: "window", id: window.windowID, path: window.windowID, sessionID: session.sessionID,
                    label: window.label, sessionLabel: session.label, active: window.active))
            }
        }
        return entries
    }

    /// Jump activates a session or window for the requesting client, falling back
    /// to server-side focus when no client context exists.
    static func jump(_ entry: SessionEntry, _ client: String) throws {
        if !client.isEmpty {
            var kv = ["session_id=" + entry.sessionID]
            if entry.kind == "window" {
                kv.append("window_id=" + entry.id)
            }
            return try doAction(client: client, action: "session.select", kv: kv)
        }
        return try focusLocalSession(entry)
    }

    static func focusLocalSession(_ entry: SessionEntry) throws {
        if entry.kind == "window" {
            return try focusWindow("", entry.sessionID, entry.id)
        }
        let windows = try? sessionWindows(entry.sessionID)
        if windows == nil || windows!.isEmpty {
            throw RexError("session \(entry.sessionLabel) has no windows")
        }
        return try focusWindowOf(windows!, entry)
    }

    /// JumpOnHost activates a row that lives on another host. The app keeps one
    /// client per server; the remote client shares the origin client's label, so the
    /// row is selected through that host's copy of the app. Server-side focus is
    /// the fallback when no matching client answers.
    static func jumpOnHost(_ host: String, _ entry: SessionEntry, _ clientID: String) throws {
        if host.isEmpty || host == localHostLabel {
            return try jump(entry, clientID)
        }
        let client = appClientOn(host, clientLabel(clientID))
        if !client.isEmpty {
            var kv = ["session_id=" + entry.sessionID]
            if entry.kind == "window" {
                kv.append("window_id=" + entry.id)
            }
            do {
                return try doOn(host, client, "session.select", kv: kv)
            } catch {
                // Fall through to server-side focus, like Go's err == nil check.
            }
        }
        let windows = try? hostWindows(host, entry.sessionID)
        if windows == nil || windows!.isEmpty {
            throw RexError("session \(entry.sessionLabel) has no windows on \(host)")
        }
        if entry.kind == "window" {
            return try focusWindow(host, entry.sessionID, entry.id)
        }
        return try focusRemoteWindow(host, windows!, entry)
    }

    static func focusWindow(_ host: String, _ sessionID: String, _ windowID: String) throws {
        _ = try apiCallOn(host, "", "session.focus_window", ["session_id": sessionID, "window_id": windowID])
    }

    /// CloseWindow closes one window; CloseSession destroys the whole session.
    static func closeWindow(_ host: String, _ sessionID: String, _ windowID: String) throws {
        _ = try apiCallOn(host, "", "session.close_window", ["session_id": sessionID, "window_id": windowID])
    }

    static func closeSession(_ host: String, _ sessionID: String) throws {
        _ = try apiCallOn(host, "", "session.destroy", ["session_id": sessionID])
    }

    static func setWindowLabel(_ host: String, _ sessionID: String, _ windowID: String, _ label: String) throws {
        _ = try apiCallOn(host, "", "session.set_window_label",
            ["session_id": sessionID, "window_id": windowID, "label": label])
    }

    static func setSessionLabel(_ host: String, _ sessionID: String, _ label: String) throws {
        _ = try apiCallOn(host, "", "session.set_label", ["session_id": sessionID, "label": label])
    }

    /// SessionGroups lists every host's sessions, local first. Each host answers in
    /// parallel: one ls for the sessions and one agent snapshot for activity. A
    /// host that fails keeps its header with the error; the view must not hide
    /// configured hosts just because SSH or the server is down. localAgents feeds
    /// the local group's activity so callers with a fresh cached snapshot avoid a
    /// second scan; nil just means plain local rows.
    static func sessionGroups(_ originSession: String, _ localAgents: [AgentEntry]?) -> [HostGroup] {
        let hosts = self.hosts()
        var of = [HostGroup?](repeating: nil, count: hosts.count)
        let lock = NSLock()
        mapHosts(hosts) { host in
            let group = hostGroup(host, originSession, localAgents)
            lock.lock()
            of[indexOfHost(hosts, host)] = group
            lock.unlock()
        }
        return of.map { $0 ?? HostGroup(label: "") }
    }

    static func indexOfHost(_ hosts: [Host], _ target: Host) -> Int {
        for (i, host) in hosts.enumerated() where host.label == target.label {
            return i
        }
        return 0
    }

    static func hostGroup(_ host: Host, _ originSession: String, _ localAgents: [AgentEntry]?) -> HostGroup {
        let name = host.local ? "" : host.label
        var group = HostGroup(label: host.label, local: host.local, reachable: true, error: "", entries: [])
        let lsBox = ValueBox<Result<String, Error>>()
        DispatchQueue.global().async {
            do {
                let out = try runOnBounded(name, remoteListTimeout, "ls", "--json")
                lsBox.set(.success(out))
            } catch {
                lsBox.set(.failure(error))
            }
        }
        let agentsBox = ValueBox<Result<[AgentEntry], Error>>()
        DispatchQueue.global().async {
            if host.local && localAgents != nil {
                agentsBox.set(.success(localAgents!))
                return
            }
            let budget = host.local ? localAgentTimeout : remoteAgentTimeout
            do {
                let out = try runOnBounded(name, budget, "do", "-e", agentsScript, "--json")
                let decoded = try decodeAgentEntriesWithNames(Data(out.utf8), "", Date(), host.local)
                agentsBox.set(.success(decoded))
            } catch {
                agentsBox.set(.failure(error))
            }
        }
        // Activity is optional: a slow or absent snapshot keeps plain rows.
        let listed = lsBox.get()
        if case .failure(let error) = listed {
            group.reachable = false
            group.error = shortHostError(error)
            if group.error.isEmpty {
                group.error = "unreachable"
            }
            return group
        }
        guard case .success(let out) = listed,
              let data = decodeJSON(SessionsResponse.self, from: Data(out.utf8)) else {
            group.reachable = false
            group.error = "could not parse the session list"
            return group
        }
        var entries: [SessionEntry] = []
        entries.reserveCapacity((data.sessions ?? []).count)
        for session in data.sessions ?? [] {
            entries.append(SessionEntry(
                kind: "session", id: session.sessionID, path: session.sessionID, sessionID: session.sessionID,
                label: session.label, sessionLabel: session.label,
                active: host.local && sameSession(session.sessionID, originSession),
                host: host.label))
        }
        if case .success(let agents) = agentsBox.get() {
            applySessionActivity(&entries, agents)
        }
        group.entries = entries
        return group
    }

    /// shortHostError strips the rex command line and transport detail: the view
    /// should explain "the host is down", not dump an argv.
    static func shortHostError(_ error: Error) -> String {
        var message = String(describing: error)
        if let range = message.range(of: ": "), message.hasPrefix("rex ") {
            message = String(message[range.upperBound...])
        }
        if let newline = message.firstIndex(of: "\n") {
            message = String(message[..<newline])
        }
        if message.count > 120 {
            message = String(message.prefix(120))
        }
        return message
    }

    /// CreateSessionOn reuses a host session by label or creates one at dir, then
    /// returns the session id. The bool reports whether an existing session matched.
    static func createSessionOn(_ host: String, _ dir: String) throws -> (id: String, existing: Bool) {
        let name = RaptorPaths.basename(dir)
        if let out = try? runOn(host, "ls", "--json"),
           let data = decodeJSON(SessionsResponse.self, from: Data(out.utf8)) {
            for session in data.sessions ?? [] where session.label == name {
                return (session.sessionID, true)
            }
        }
        let out = try runOn(host, "new", "--json", "-c", dir, name)
        struct CreateResult: Decodable {
            var sessionID: String?
            enum CodingKeys: String, CodingKey {
                case sessionID = "session_id"
            }
        }
        guard let res = decodeJSON(CreateResult.self, from: Data(out.utf8)),
              let sid = res.sessionID, !sid.isEmpty else {
            throw RexError("could not create session for \(dir) on \(host)")
        }
        recordLauncherCreation(host, sid, name, dir)
        return (sid, false)
    }

    /// SelectOnHost switches the host's app client to a session, falling back to
    /// server-side focus on that host.
    static func selectOnHost(_ host: String, _ sessionID: String, _ clientID: String) throws {
        let entry = SessionEntry(kind: "session", id: sessionID, path: sessionID, sessionID: sessionID)
        return try jumpOnHost(host, entry, clientID)
    }

    /// apiTimeout documents the shared rex call budget for session mutations.
    static let apiTimeout: TimeInterval = 15
}

extension Rex {
    static func sessionWindows(_ sessionID: String) throws -> [APIWindow] {
        let out = try apiCall(sessionID, "session.view", ["session_id": sessionID])
        guard let view = decodeJSON(SessionViewResponse.self, from: Data(out.utf8)) else {
            throw RexError("could not parse the window list for \(sessionID)")
        }
        return view.windows.map { w in
            APIWindow(windowID: w.windowID, label: w.label, focusedBlockID: w.focusedBlockID,
                active: w.windowID == view.activeWindowID)
        }
    }

    /// sessionWindowLabel mirrors Rex's terminal title fallback without changing
    /// stored labels. Explicit tab names never need an additional Rex call.
    static func sessionWindowLabel(_ sessionID: String, _ window: APIWindow) -> String {
        let autogenerated = window.windowID.count >= 8 && window.label == "Window " + String(window.windowID.suffix(8))
        if window.focusedBlockID.isEmpty || (!window.label.isEmpty && !autogenerated) {
            return window.label
        }
        guard let out = try? run("block", "call", "-s", sessionID, "-b", window.focusedBlockID, "title") else {
            return window.label
        }
        struct TitleResult: Decodable {
            var title: String?
        }
        guard let result = decodeJSON(TitleResult.self, from: Data(out.utf8)),
              !(result.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty else {
            return window.label
        }
        return result.title ?? ""
    }

    static func apiCall(_ sessionID: String, _ method: String, _ params: [String: String]) throws -> String {
        try apiCallOn("", sessionID, method, params)
    }

    static func apiCallOn(_ host: String, _ sessionID: String, _ method: String, _ params: [String: String]) throws -> String {
        var args = ["api", "call"]
        if !sessionID.isEmpty {
            args.append(contentsOf: ["-s", sessionID])
        }
        let payload = marshalSorted(params)
        args.append(contentsOf: [method, payload])
        return try runOn(host, args)
    }

    static func focusWindowOf(_ windows: [APIWindow], _ entry: SessionEntry) throws {
        var active = windows[0].windowID
        for window in windows where window.active {
            active = window.windowID
            break
        }
        return try focusWindow("", entry.sessionID, active)
    }

    static func focusRemoteWindow(_ host: String, _ windows: [APIWindow], _ entry: SessionEntry) throws {
        var active = windows[0].windowID
        for window in windows where window.active {
            active = window.windowID
            break
        }
        return try focusWindow(host, entry.sessionID, active)
    }

    static func hostWindows(_ host: String, _ sessionID: String) throws -> [APIWindow] {
        let out = try apiCallOn(host, sessionID, "session.view", ["session_id": sessionID])
        guard let view = decodeJSON(SessionViewResponse.self, from: Data(out.utf8)) else {
            throw RexError("could not parse the window list for \(sessionID)")
        }
        return view.windows.map {
            APIWindow(windowID: $0.windowID, label: $0.label, focusedBlockID: $0.focusedBlockID)
        }
    }
}
