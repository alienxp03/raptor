import Foundation
import RaptorCatalog
import RaptorConfig
import RaptorPaths
import RaptorPullrequest
import RaptorRex
import RaptorWorktree

/// Optional backend override for snapshot loads; set before serving.
typealias SnapshotLoader = (
    _ origin: Ctx, _ launcher: Bool
) -> (agents: [AgentEntry], items: [LauncherItem]?, hosts: [HostHeader]?, error: Error?)

extension Handler {
    func cacheGeneration() -> UInt64 {
        cacheMu.lock()
        defer { cacheMu.unlock() }
        return generation
    }

    /// Invalidation never removes usable rows. Only the event path schedules
    /// work; reading a warm snapshot cannot start a scan or a self-refresh loop.
    func invalidateActivity() {
        cacheMu.lock()
        generation += 1
        cacheMu.unlock()
    }

    func storeLauncher(_ generation: UInt64, _ items: [LauncherItem]?, _ hosts: [HostHeader]?) {
        cacheMu.lock()
        defer { cacheMu.unlock() }
        if generation != self.generation {
            return
        }
        commitLauncher(items, hosts)
    }

    /// cacheMu must be held. Published slices are never changed after this call.
    func commitLauncher(_ items: [LauncherItem]?, _ hosts: [HostHeader]?) {
        commitLauncherAt(items, hosts, launcher.scanStarted)
    }

    /// cacheMu must be held.
    func commitLauncherAt(_ items: [LauncherItem]?, _ hosts: [HostHeader]?, _ started: Date) {
        var items = items ?? []
        // A failed host must not erase its last usable rows. Host headers still
        // report the error; successful empty hosts do replace their old rows.
        var failed = Set<String>()
        for host in hosts ?? [] where !host.reachable {
            failed.insert(host.label)
        }
        if !failed.isEmpty && launcherLoaded {
            var kept: [LauncherItem] = []
            kept.reserveCapacity(items.count + (launcher.items ?? []).count)
            for item in items where !failed.contains(item.host) {
                kept.append(item)
            }
            for item in launcher.items ?? [] where failed.contains(item.host) {
                kept.append(item)
            }
            // Fresh and retained rows each have sessions before folders. Keep
            // that boundary after merging, without changing either kind's order.
            var merged: [LauncherItem] = []
            merged.reserveCapacity(kept.count)
            for item in kept where item.kind == "session" {
                merged.append(item)
            }
            for item in kept where item.kind != "session" {
                merged.append(item)
            }
            items = merged
        }
        launcher = LauncherCacheEntry(timestamp: Date(), scanStarted: started, items: items, hosts: hosts)
        launcherLoaded = true
        launcherGeneration = generation
        writeLauncherCache(items, hosts)
    }

    /// At most one snapshot worker exists, including across subscription changes.
    /// Events during a scan set one pending bit. Publish each completed snapshot
    /// before the trailing scan, so continuous activity cannot starve the UI.
    func requestRefresh() {
        cacheMu.lock()
        defer { cacheMu.unlock() }
        queueRefreshLocked()
    }

    func requestLiveRefresh() {
        cacheMu.lock()
        defer { cacheMu.unlock() }
        if notify != nil {
            queueRefreshLocked()
        }
    }

    /// cacheMu must be held.
    func queueRefreshLocked() {
        generation += 1
        refreshPending = true
        refreshLauncher = true
        startRefreshLocked()
    }

    /// cacheMu must be held.
    func startRefreshLocked() {
        if revalidating {
            return
        }
        revalidating = true
        let done = Broadcast()
        refreshDone = done
        let thread = Thread { [weak self] in
            self?.refresh(finished: done)
        }
        thread.name = "api-snapshot-worker"
        thread.start()
    }

    func refreshCold(launcher: Bool) -> Error? {
        refreshColdContext(CancelToken(), launcher)
    }

    func refreshColdContext(_ cancel: CancelToken, _ launcher: Bool) -> Error? {
        let canceledError = MessageError("context canceled")
        while true {
            if cancel.isCancelled {
                return canceledError
            }
            cacheMu.lock()
            var loaded = activityLoaded
            if launcher {
                loaded = self.launcherLoaded
            }
            if loaded {
                cacheMu.unlock()
                return nil
            }
            if launcher && !refreshLauncher {
                refreshLauncher = true
                if revalidating {
                    refreshPending = true
                    generation += 1
                }
            }
            startRefreshLocked()
            guard let done = refreshDone else {
                cacheMu.unlock()
                return MessageError("snapshot unavailable")
            }
            let changed = snapshotChanged
            cacheMu.unlock()
            // select { ctx.Done / done / changed }
            while true {
                if cancel.isCancelled {
                    return canceledError
                }
                if done.isFired || changed.isFired {
                    break
                }
                usleep(5_000)
            }
            cacheMu.lock()
            loaded = activityLoaded
            if launcher {
                loaded = self.launcherLoaded
            }
            let working = revalidating
            cacheMu.unlock()
            if loaded {
                return nil
            }
            if !working {
                return MessageError("snapshot unavailable")
            }
        }
    }

    func refresh(finished: Broadcast) {
        cacheMu.lock()
        defer {
            revalidating = false
            finished.fire()
            cacheMu.unlock()
        }
        while true {
            let generation = self.generation
            let presentation = self.presentation
            var origin = ctx
            let cfg = self.cfg
            let load = loadSnapshot
            let launcher = refreshLauncher
            let hadLauncher = launcherLoaded
            refreshPending = false
            cacheMu.unlock()

            // Base snapshots do not depend on the current presentation's origin.
            origin.session = ""
            origin.block = ""
            let loadFn = load ?? Self.defaultLoader(cfg: cfg, hadLauncher: hadLauncher)
            let started = Date()
            let (agents, items, hosts, error) = loadFn(origin, launcher)

            cacheMu.lock()
            if presentation == self.presentation && (error == nil || (launcher && !self.launcherLoaded && items != nil)) {
                if error == nil {
                    activityAgents = agents
                    activityLoaded = true
                    activityAt = Date()
                    activityGeneration = generation
                }
                if launcher {
                    commitLauncherAt(items, hosts, started)
                }
                snapshotChanged.fire()
                snapshotChanged = Broadcast()
                // Keep notification and presentation changes ordered. No worker
                // from an old subscription can notify after unsubscribe or a
                // context response.
                notify?()
            }
            if !refreshPending {
                return
            }
        }
    }

    /// The Go default loader: fresh worker Handler, one activity scan, and —
    /// when the launcher is wanted and not already on disk — a full fetch.
    static func defaultLoader(cfg: RaptorConfig, hadLauncher: Bool) -> SnapshotLoader {
        return { origin, launcher in
            let worker = Handler(ctx: origin, cfg: cfg)
            var agents: [AgentEntry]
            var loadError: Error?
            do {
                agents = try Rex.agentEntries("")
                loadError = nil
            } catch {
                agents = []
                loadError = error
            }
            var items: [LauncherItem]?
            var hosts: [HostHeader]?
            if launcher && (loadError == nil || !hadLauncher) {
                if loadError != nil {
                    // Status is optional. An explicit empty slice prevents a
                    // second status scan from holding cold discovery hostage.
                    agents = []
                }
                let fetched = worker.fetchLauncher(agents)
                items = fetched.items
                hosts = fetched.hosts
            }
            return (agents, items, hosts, loadError)
        }
    }

    // MARK: - launcher cache file

    func launcherCachePath() -> String {
        RaptorPaths.cacheDir() + "/launcher-cache.json"
    }

    func readLauncherCache() -> (LauncherCacheEntry, Bool) {
        cacheMu.lock()
        if launcherLoaded {
            let entry = overlayLauncher(launcher)
            cacheMu.unlock()
            return (entry, true)
        }
        cacheMu.unlock()
        guard let data = FileManager.default.contents(atPath: launcherCachePath()) else {
            return (LauncherCacheEntry(), false)
        }
        guard let entry = decodeLauncherCache(data), entry.items != nil else {
            return (LauncherCacheEntry(), false)
        }
        cacheMu.lock()
        launcher = entry
        launcherLoaded = true
        cacheMu.unlock()
        return (overlayLauncher(entry), true)
    }

    /// writeLauncherCache replaces the cache atomically so a crashed write never
    /// leaves a truncated file behind.
    func writeLauncherCache(_ items: [LauncherItem], _ hosts: [HostHeader]?) {
        // Called with cacheMu held (Go mirrors this lock-free scan-started read).
        let started = launcher.scanStarted
        let entry = LauncherCacheEntry(timestamp: Date(), scanStarted: started, items: items, hosts: hosts)
        let data = encodeLauncherCache(entry)
        let path = launcherCachePath()
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        let tmp = dir + "/.launcher-" + UUID().uuidString
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: nil) else {
            return
        }
        var renamed = false
        if rename(tmp, path) == 0 {
            renamed = true
        }
        if !renamed {
            remove(tmp)
        }
    }

    /// fetchLauncher composes the full unfiltered launcher payload: sessions and
    /// directories per host in parallel, with activity folded in. This is the slow
    /// path — remote hosts answer over SSH within their own bounds.
    func fetchLauncher(_ localAgents: [AgentEntry]) -> (items: [LauncherItem], hosts: [HostHeader]) {
        let origin = ctxSnapshot()
        let groups = Rex.sessionGroups(origin.session, localAgents)
        var hostOrder = [Rex.localHostLabel]
        for group in groups where !group.local {
            hostOrder.append(group.label)
        }
        var pins = Set<String>()
        for pin in RaptorConfig.loadPins() {
            pins.insert(RaptorPaths.canonical(pin))
        }
        var hostDirs: [String: [Directory]] = [:]
        let dirsLock = NSLock()
        let workers = min(Handler.launcherDirWorkers, hostOrder.count)
        let semaphore = DispatchSemaphore(value: max(workers, 1))
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "api.launcherDirs", attributes: .concurrent)
        for host in hostOrder {
            semaphore.wait()
            group.enter()
            queue.async {
                defer {
                    semaphore.signal()
                    group.leave()
                }
                var items = Catalog.directoriesOn(host: host, reposOnly: false)
                var agents = localAgents
                if host != Rex.localHostLabel {
                    agents = (try? Rex.agentEntriesOn(host, "")) ?? []
                }
                Catalog.applyDirectoryActivityOn(host: host, items: &items, agents: agents)
                if host == Rex.localHostLabel {
                    for i in items.indices {
                        items[i].pinned = pins.contains(RaptorPaths.canonical(items[i].path))
                    }
                }
                dirsLock.lock()
                hostDirs[host] = items
                dirsLock.unlock()
            }
        }
        group.wait()

        let localDisplay = Rex.apiLocalHostname()
        let items = Catalog.launcherItems(groups, hostOrder, hostDirs, "", localAgents, localDisplay)
        var hosts: [HostHeader] = []
        hosts.reserveCapacity(groups.count)
        for group in groups {
            var label = group.label
            if group.local {
                label = localDisplay
            }
            hosts.append(HostHeader(label: label, local: group.local, reachable: group.reachable, error: group.error))
        }
        return (items, hosts)
    }

    /// revalidateLauncher refreshes the launcher cache in the background after a
    /// stale response went out.
    func revalidateLauncher() {
        requestRefresh()
    }

    // MARK: - activity snapshots

    func activitySnapshot(fresh: Bool) throws -> [AgentEntry] {
        try activitySnapshotContext(CancelToken(), fresh)
    }

    /// Keep successful, unfiltered activity across view and context changes.
    /// Events refresh it in the background; warm requests only copy and filter.
    func activitySnapshotContext(_ cancel: CancelToken, _ fresh: Bool) throws -> [AgentEntry] {
        cacheMu.lock()
        if activityLoaded {
            let entries = activityAgents
            cacheMu.unlock()
            return entries
        }
        cacheMu.unlock()
        if let error = refreshColdContext(cancel, false) {
            throw error
        }
        cacheMu.lock()
        defer { cacheMu.unlock() }
        return activityAgents
    }
}
