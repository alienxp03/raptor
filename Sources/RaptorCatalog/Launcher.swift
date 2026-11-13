import Foundation
import RaptorConfig
import RaptorPaths
import RaptorRex
import RaptorWorktree

/// LauncherItem is one row of the unified Sessions launcher: a live session on
/// any host, or a frecency directory that would start one. Every field is
/// explicit — embedding the session entry would emit duplicate JSON keys.
public struct LauncherItem: Equatable, Encodable {
    public var kind: String // "session" | "dir"
    public var id: String
    public var path: String
    public var sessionID: String
    public var label: String
    public var sessionLabel: String
    public var host: String
    public var active: Bool
    public var local: Bool
    public var pinned: Bool
    public var pinSlot: Int?
    public var state: String
    public var working: Bool
    public var unreadDone: Bool
    public var completionSources: [CompletionSource]

    public init(
        kind: String = "", id: String = "", path: String = "", sessionID: String = "",
        label: String = "", sessionLabel: String = "", host: String = "", active: Bool = false,
        local: Bool = false, pinned: Bool = false, pinSlot: Int? = nil, state: String = "", working: Bool = false,
        unreadDone: Bool = false, completionSources: [CompletionSource] = []
    ) {
        self.kind = kind
        self.id = id
        self.path = path
        self.sessionID = sessionID
        self.label = label
        self.sessionLabel = sessionLabel
        self.host = host
        self.active = active
        self.local = local
        self.pinned = pinned
        self.pinSlot = pinSlot
        self.state = state
        self.working = working
        self.unreadDone = unreadDone
        self.completionSources = completionSources
    }

    enum CodingKeys: String, CodingKey {
        case kind, id, path
        case sessionID = "session_id"
        case label
        case sessionLabel = "session_label"
        case host, active
        case local = "is_local"
        case pinned = "is_pinned"
        case pinSlot = "pin_slot"
        case state, working
        case unreadDone = "unread_done"
        case completionSources = "_completion_sources"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(id, forKey: .id)
        if !path.isEmpty {
            try c.encode(path, forKey: .path)
        }
        if !sessionID.isEmpty {
            try c.encode(sessionID, forKey: .sessionID)
        }
        try c.encode(label, forKey: .label)
        if !sessionLabel.isEmpty {
            try c.encode(sessionLabel, forKey: .sessionLabel)
        }
        try c.encode(host, forKey: .host)
        if active {
            try c.encode(active, forKey: .active)
        }
        try c.encode(local, forKey: .local)
        if pinned {
            try c.encode(pinned, forKey: .pinned)
        }
        if let pinSlot, (1...9).contains(pinSlot) {
            try c.encode(pinSlot, forKey: .pinSlot)
        }
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

public extension Catalog {
    /// LauncherItems composes the flat launcher: pinned rows, the origin session,
    /// then other sessions and each host's directories in their existing order. Directories whose label already
    /// has a live session on the same host are skipped: selecting the session is
    /// the same action. A query fuzzy-ranks the composed rows over label, path,
    /// and host, with matching sessions before directories.
    static func launcherItems(
        _ groups: [HostGroup], _ hostOrder: [String], _ hostDirs: [String: [Directory]],
        _ query: String, _ agents: [AgentEntry], _ localDisplay: String,
        prioritizePins: Bool = true
    ) -> [LauncherItem] {
        var rows: [LauncherItem] = []
        rows.reserveCapacity(16)
        // Local rows carry the machine's real hostname so every badge answers
        // "where is this" without a generic "This Mac".
        var localDisplay = localDisplay
        if localDisplay.isEmpty {
            localDisplay = Rex.localHostLabel
        }
        let sessionPins = Set(RaptorConfig.loadSessionPins())
        func session(_ entry: SessionEntry, _ local: Bool) -> LauncherItem {
            var host = entry.host
            if host.isEmpty || host == Rex.localHostLabel {
                host = localDisplay
            }
            let pin = sessionPins.first { $0 == SessionPin(sessionID: entry.sessionID, host: host) }
            return LauncherItem(
                kind: "session", id: entry.id, path: entry.id,
                sessionID: entry.sessionID, label: entry.label, sessionLabel: entry.sessionLabel,
                host: host, active: entry.active, local: local,
                pinned: pin != nil, pinSlot: pin?.slot,
                state: entry.state, working: entry.working,
                unreadDone: entry.unreadDone, completionSources: entry.completionSources
            )
        }
        func dir(_ host: String, _ identityLocal: Bool, _ item: Directory, _ pinned: Bool) -> LauncherItem {
            var host = host
            if host.isEmpty || host == Rex.localHostLabel {
                host = localDisplay
            }
            return LauncherItem(
                kind: "dir", id: item.path, path: item.path, label: item.label,
                host: host, local: identityLocal, pinned: pinned, state: item.state, working: item.working,
                unreadDone: item.unreadDone, completionSources: item.completionSources
            )
        }
        var origin = -1
        for group in groups {
            if !group.reachable {
                continue
            }
            for entry in group.entries {
                if entry.active {
                    origin = rows.count
                }
                rows.append(session(entry, group.local))
            }
        }
        if origin > 0 {
            let active = rows[origin]
            var i = origin
            while i >= 1 {
                rows[i] = rows[i - 1]
                i -= 1
            }
            rows[0] = active
        }
        var taken = Set<String>()
        for group in groups {
            if group.reachable {
                for entry in group.entries {
                    taken.insert(group.label + "\u{0}" + entry.label)
                }
            }
        }
        for host in hostOrder {
            guard let items = hostDirs[host] else {
                continue
            }
            let local = host == Rex.localHostLabel
            for item in items {
                if taken.contains(host + "\u{0}" + item.label) {
                    continue
                }
                rows.append(dir(host, local, item, local && item.pinned))
            }
        }

        if query.isEmpty {
            return prioritizePins ? pinnedLauncherFirst(rows) : rows
        }
        let scored = rankLauncherItems(rows, query)
        return scored.map { rows[$0.index] }
    }

    /// FilterLauncherItems applies the query to a cached (unfiltered) launcher
    /// composition: everything when the query is empty, exact names then fuzzy
    /// quality within sessions-first groups otherwise. A path-like query that resolves to an unlisted local
    /// directory appends one typed-path row after the ranked matches.
    static func filterLauncherItems(_ items: [LauncherItem], _ query: String, _ originSession: String) -> [LauncherItem] {
        if query.isEmpty {
            return items
        }
        var scored = rankLauncherItems(items, query).map { items[$0.index] }
        if let typed = typedPathLauncherItem(query, items) {
            scored.append(typed)
        }
        return scored
    }

    /// TypedPathLauncherItem mirrors typedPathDirectory for the launcher row
    /// shape. The host badge shows the local machine because only local paths
    /// resolve here; remote typed paths stay a follow-up.
    static func typedPathLauncherItem(_ query: String, _ items: [LauncherItem]) -> LauncherItem? {
        guard let directory = typedPathDirectory(query, []) else { return nil }
        let canonical = canonicalPath(directory.path)
        for item in items where item.kind == "dir" && canonicalPath(item.path) == canonical {
            return nil
        }
        return LauncherItem(
            kind: "dir", id: directory.path, path: directory.path,
            label: directory.label, host: Rex.localHostname(), local: true,
            state: "", working: false
        )
    }

    /// Select the current session on open, independent of pin position.
    /// A search or a list without the current session uses its first ranked row.
    static func preferredLauncherID(_ items: [LauncherItem], _ query: String) -> String {
        if query.isEmpty, let current = items.first(where: { $0.kind == "session" && $0.active }) {
            return current.id
        }
        return items.first?.id ?? ""
    }

    /// PinLauncherOrigin moves the origin session to the front of already-composed
    /// items (used by callers that compose without a query).
    static func pinLauncherOrigin(_ items: [LauncherItem], _ originSession: String) -> [LauncherItem] {
        pinnedLauncherFirst(pinOriginFirst(items, originSession))
    }

    /// Update flags without changing source order. Cached flags are not authoritative.
    static func applyLauncherPins(_ items: inout [LauncherItem]) {
        let sessions = Set(RaptorConfig.loadSessionPins())
        let paths = Set(RaptorConfig.loadPins().map { canonicalPath($0) })
        for i in items.indices {
            let item = items[i]
            let pin = item.kind == "session"
                ? sessions.first { $0 == SessionPin(sessionID: item.sessionID, host: item.host) }
                : nil
            items[i].pinned = item.kind == "session"
                ? pin != nil
                : item.kind == "dir" && item.local && paths.contains(canonicalPath(item.path))
            items[i].pinSlot = pin?.slot
        }
    }

    /// Saved pin order for empty-query presentation only; search retains relevance.
    /// Session pins precede directory pins, whose order is stored separately.
    static func pinnedLauncherFirst(_ items: [LauncherItem]) -> [LauncherItem] {
        let sessions = RaptorConfig.loadSessionPins()
        let sessionOrder = Dictionary(sessions.enumerated().map { ($0.element, $0.offset) },
                                      uniquingKeysWith: { first, _ in first })
        let directoryOrder = Dictionary(RaptorConfig.loadPins().enumerated().map {
            (canonicalPath($0.element), sessions.count + $0.offset)
        }, uniquingKeysWith: { first, _ in first })
        func rank(_ item: LauncherItem) -> Int {
            if item.kind == "session" {
                return sessionOrder[SessionPin(sessionID: item.sessionID, host: item.host)] ?? Int.max
            }
            if item.kind == "dir", item.local {
                return directoryOrder[canonicalPath(item.path)] ?? Int.max
            }
            return Int.max
        }
        let pinned = items.enumerated().filter { $0.element.pinned }.sorted {
            let left = rank($0.element), right = rank($1.element)
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
        return pinned + items.filter { !$0.pinned }
    }

    /// Local port of Catalog.sameSession (internal in RaptorRex): compares a local
    /// session ID with an origin reference. Non-exact references must resolve
    /// uniquely on the local server, never by suffix alone.
    static func sameSession(_ full: String, _ origin: String) -> Bool {
        if origin.trimmingCharacters(in: .whitespaces).isEmpty || full.isEmpty {
            return false
        }
        if full == origin {
            return true
        }
        if origin.hasPrefix("session:") {
            return false
        }
        return full == resolveHostTarget("", "session", origin)
    }

    /// resolveHostTarget uses the local server's ambiguity rules, without inherited
    /// local session/client context. Unknown statuses and malformed replies fail shut.
    static func resolveHostTarget(_ host: String, _ kind: String, _ query: String) -> String {
        let payload = Rex.marshalSorted(["kinds": [kind], "queries": [query]])
        guard let out = try? Rex.runOn(host, ["api", "call", "target.resolve", payload]),
              let obj = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any],
              let results = obj["results"] as? [[String: Any]], results.count == 1 else {
            return ""
        }
        let result = results[0]
        let target = result["target"] as? [String: Any] ?? [:]
        if result["query"] as? String != query || result["status"] as? String != "resolved" || target["kind"] as? String != kind {
            return ""
        }
        if kind == "session", let id = target["session_id"] as? String, id.hasPrefix("session:") {
            return id
        }
        return ""
    }

    /// pinOriginFirst moves the origin session to the front of ranked results:
    /// the session you're in is always the first suggestion, whatever the match
    /// score says. Origin matches by the active flag or by the origin session id —
    /// cached payloads may predate active flags.
    static func pinOriginFirst(_ ranked: [LauncherItem], _ originSession: String) -> [LauncherItem] {
        func isOrigin(_ item: LauncherItem) -> Bool {
            item.kind == "session" &&
                (item.active || Catalog.sameSession(item.sessionID, originSession))
        }
        if ranked.count > 1 && isOrigin(ranked[0]) {
            return ranked
        }
        for (i, item) in ranked.enumerated() where isOrigin(item) {
            var rest = ranked
            rest.remove(at: i)
            return [item] + rest
        }
        return ranked
    }
}

/// fuzzy.Source over prebuilt launcher texts.
struct LauncherTexts: FuzzySource {
    let texts: [String]
    func string(_ i: Int) -> String { texts[i] }
    var count: Int { texts.count }
}
