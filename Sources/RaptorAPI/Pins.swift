import RaptorCatalog

extension Handler {
    /// Pins change presentation only. Keep source order for unpinning; no CLI scan.
    /// Read-time overlays also protect against an older in-flight scan or disk cache.
    func patchLauncherPins() {
        _ = readLauncherCache()
        cacheMu.lock()
        defer { cacheMu.unlock() }
        if launcherLoaded {
            var items = launcher.items ?? []
            Catalog.applyLauncherPins(&items)
            commitLauncher(items, launcher.hosts)
        }
        notify?()
    }
}
