import Foundation

public extension Rex {
    /// AgentStateRank orders blocked, working, then idle (including unknown states).
    static func agentStateRank(_ state: String) -> Int {
        switch state {
        case "blocked": return 0
        case "working": return 1
        default: return 2
        }
    }

    /// SortGroups sorts in place by state, then newest UpdatedAt first. Missing times
    /// sort last within each group. Equal times retain source order (stable, like
    /// Go's sort.SliceStable).
    static func sortGroups(_ entries: inout [AgentEntry]) {
        let indexed = entries.enumerated().map { (index: $0.offset, entry: $0.element) }
        let sorted = indexed.sorted { a, b in
            let ar = agentStateRank(a.entry.state), br = agentStateRank(b.entry.state)
            if ar != br { return ar < br }
            if isUnknownTime(a.entry.updatedAt) { return false }
            return isUnknownTime(b.entry.updatedAt) || a.entry.updatedAt! > b.entry.updatedAt!
        }
        entries = sorted.map { $0.entry }
    }

    static func isUnknownTime(_ t: Date?) -> Bool {
        t == nil || t == zeroTime
    }

    /// Only native status time is used. Invalid/absent times stay unknown; valid
    /// future times are preserved, since producer clock skew is not proof of error.
    static func agentUpdatedAt(_ raw: String?) -> Date? {
        guard let raw, let parsed = parseRFC3339(raw) else { return nil }
        if parsed == zeroTime { return nil }
        return parsed
    }
}
