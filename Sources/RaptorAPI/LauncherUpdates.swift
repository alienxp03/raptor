import Foundation
import RaptorCatalog
import RaptorLauncherupdate
import RaptorPullrequest
import RaptorRex

/// Overlay only snapshots that predate a creation. Successful later discovery
/// owns renames/removals; failed hosts retain their bounded creation hints.
func overlayLauncher(_ entry: LauncherCacheEntry) -> LauncherCacheEntry {
    var entry = entry
    entry.items = entry.items ?? []
    var failed = Set<String>()
    for host in entry.hosts ?? [] where !host.reachable {
        failed.insert(host.label)
    }
    for s in Launcherupdate.since(Rex.zeroTime) {
        // A scan that started before (or at the same instant as) the creation
        // cannot know about it; only a strictly later completed scan is
        // authoritative. Clocks tie, so equality merges — bounded by TTL.
        if !failed.contains(s.host) && s.created < entry.scanStarted {
            continue
        }
        var found = false
        for item in entry.items ?? []
        where item.kind == "session" && item.sessionID == s.id && item.local == s.local
            && (s.local || item.host == s.host) {
            found = true
            break
        }
        if !found {
            let item = LauncherItem(
                kind: "session", id: s.id, sessionID: s.id, label: s.label,
                sessionLabel: s.label, host: s.host, local: s.local)
            entry.items?.insert(item, at: 0)
        }
    }
    return entry
}

extension Handler {
    /// No scan on the mutation path: only return a complete snapshot when one is
    /// already available. The native client must omit replacement when absent.
    func launcherItems() -> [LauncherItem]? {
        let (cached, ok) = readLauncherCache()
        if !ok {
            return nil
        }
        cacheMu.lock()
        let origin = ctx.session
        let ranks = self.ranks
        cacheMu.unlock()
        var items = cached.items ?? []
        for i in items.indices {
            items[i].active = items[i].local && items[i].sessionID == origin
        }
        Catalog.orderLauncherSessionsByRecency(&items, ranks)
        return Catalog.pinLauncherOrigin(items, "")
    }

    func addLauncherItems(to result: inout [(String, JS)]) {
        if let items = launcherItems(), !items.isEmpty {
            result.append(("launcher_items", .array(items.map { .raw(encodedJSONString($0)) })))
        }
    }

    func openLauncherResult(_ result: OpenResult, _ error: Error?) -> MethodResult {
        var result = result
        if let error {
            result.error = String(describing: error)
        }
        return .open(result, launcherItems: launcherItems())
    }
}
