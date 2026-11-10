import Foundation
import RaptorRex

public extension Catalog {
    /// OrderLauncherSessionsByRecency changes session order only. Callers supply a
    /// presentation's immutable ranks, then pin the origin and apply fuzzy search.
    /// Unknown sessions keep the native source order; folder order never changes.
    static func orderLauncherSessionsByRecency(_ items: inout [LauncherItem], _ ranks: SessionRecency) {
        func rank(_ item: LauncherItem) -> Int {
            var host = item.host
            if item.local {
                host = ""
            }
            return ranks.rank(host, item.sessionID)
        }
        var sessions: [(item: LauncherItem, key: Int)] = []
        for item in items where item.kind == "session" {
            sessions.append((item, rank(item)))
        }
        sessions = stableSortGo(sessions) { $0.key < $1.key }
        var n = 0
        for i in items.indices where items[i].kind == "session" {
            items[i] = sessions[n].item
            n += 1
        }
    }
}
