import Foundation
import RaptorCatalog
import RaptorPaths

extension Handler {
    /// Pinning is Raptor state, not a Rex event. Patch its visible snapshot now;
    /// refresh once in the background to restore frecency order after unpinning.
    func patchLauncherPin(_ path: String, _ pinned: Bool) {
        _ = readLauncherCache()
        let canonical = RaptorPaths.canonical(path)
        cacheMu.lock()
        defer { cacheMu.unlock() }
        // An older scan must not undo this local mutation when it completes.
        presentation += 1
        if launcherLoaded {
            var items = launcher.items ?? []
            var localDirs: [LauncherItem] = []
            for i in items.indices {
                if items[i].kind != "dir" || !items[i].local {
                    continue
                }
                if RaptorPaths.canonical(items[i].path) == canonical {
                    items[i].pinned = pinned
                }
                localDirs.append(items[i])
            }
            localDirs = stableSort(localDirs) { $0.pinned && !$1.pinned }
            var n = 0
            for i in items.indices where items[i].kind == "dir" && items[i].local {
                items[i] = localDirs[n]
                n += 1
            }
            commitLauncher(items, launcher.hosts)
        }
        queueRefreshLocked()
    }
}
