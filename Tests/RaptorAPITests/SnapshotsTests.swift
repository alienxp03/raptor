import Foundation
import RaptorCatalog
import RaptorRex
import RaptorWorktree
import XCTest
@testable import RaptorAPI

final class SnapshotsTests: APITestCase {
    // MARK: - shared load-hook plumbing

    final class BlockingHook: @unchecked Sendable {
        private let cond = NSCondition()
        private var startedFlag = false
        private var released = false

        func markStarted() {
            cond.lock()
            startedFlag = true
            cond.broadcast()
            cond.unlock()
        }

        var isStarted: Bool {
            cond.lock()
            defer { cond.unlock() }
            return startedFlag
        }

        func waitStarted(_ timeout: TimeInterval) -> Bool {
            cond.lock()
            let deadline = Date().addingTimeInterval(timeout)
            while !startedFlag {
                if !cond.wait(until: deadline) {
                    break
                }
            }
            cond.unlock()
            return startedFlag
        }

        /// Idempotent release (Go's sync.Once-unblocked close).
        func release() {
            cond.lock()
            released = true
            cond.broadcast()
            cond.unlock()
        }

        func waitRelease(_ timeout: TimeInterval) {
            cond.lock()
            let deadline = Date().addingTimeInterval(timeout)
            while !released {
                if !cond.wait(until: deadline) {
                    break
                }
            }
            cond.unlock()
        }
    }

    func testWarmQueriesDoNotWaitForLiveRefresh() {
        env.set("XDG_CACHE_HOME", makeTempDir())
        let h = warmHandler()
        let hook = BlockingHook()
        let scans = Counter()
        let notifications = NotificationBox()
        addTeardown {
            hook.release()
            waitSnapshot(h)
        }
        h.notify = {
            notifications.push(h.launcher.items?[0].label ?? "")
        }
        h.loadSnapshot = { _, _ in
            _ = scans.add()
            hook.markStarted()
            hook.waitRelease(30)
            return ([AgentEntry(label: "New agent")], [LauncherItem(id: "", label: "New")], nil, nil)
        }
        h.requestRefresh()
        if !hook.waitStarted(1) {
            XCTFail("refresh did not start")
            return
        }
        for _ in 0..<100 {
            for method in ["sessions", "agents"] {
                let (_, error) = h.call(method, "{\"query\":\"Old\"}")
                if let error {
                    XCTFail("warm filtering blocked behind native snapshot: \(error)")
                    return
                }
            }
        }
        if notifications.popIfAvailable() != nil {
            XCTFail("notification before cache commit")
        }
        if scans.load() != 1 {
            XCTFail("scans=\(scans.load())")
        }
        hook.release()
        waitSnapshot(h)
        if notifications.waitOne(2) != "New" {
            XCTFail("notified before publication: \(notifications.popIfAvailable() ?? "none")")
        }
        for _ in 0..<100 {
            let (_, error) = h.call("sessions", "{}")
            if let error {
                XCTFail("\(error)")
            }
        }
        if scans.load() != 1 || notifications.count != 0 {
            XCTFail("query triggered another scan/notification")
        }
    }

    func testRefreshCoalescesEventsAndDeliversFinalGeneration() {
        env.set("XDG_CACHE_HOME", makeTempDir())
        let h = warmHandler()
        let hook = BlockingHook()
        addTeardown {
            hook.release()
            waitSnapshot(h)
        }
        let scans = Counter()
        let notifications = Counter()
        h.notify = {
            _ = notifications.add()
        }
        h.loadSnapshot = { _, _ in
            let n = scans.add()
            if n == 1 {
                hook.markStarted()
                hook.waitRelease(30)
            }
            return ([], [LauncherItem(id: "", label: String(n))], nil, nil)
        }
        h.requestRefresh()
        if !hook.waitStarted(1) {
            XCTFail("refresh did not start")
            return
        }
        for _ in 0..<100 {
            h.requestRefresh()
        }
        hook.release()
        waitSnapshot(h)
        if scans.load() != 2 || notifications.load() != 2 {
            XCTFail("scans=\(scans.load()) notifications=\(notifications.load())")
        }
        let (cached, _) = h.readLauncherCache()
        if cached.items?[0].label != "2" {
            XCTFail("final event was lost")
        }
        if !h.activityLoaded || !h.activityAgents.isEmpty {
            XCTFail("empty success not cached")
        }
    }

    func testDiskSnapshotAnswersWhileFirstRefreshBlocked() throws {
        env.set("XDG_CACHE_HOME", makeTempDir())
        let h = Handler(ctx: Ctx(), cfg: .default())
        h.writeLauncherCache([LauncherItem(id: "", label: "Disk")], nil)
        let hook = BlockingHook()
        addTeardown {
            hook.release()
            waitSnapshot(h)
        }
        let scans = Counter()
        h.loadSnapshot = { _, _ in
            _ = scans.add()
            hook.markStarted()
            hook.waitRelease(30)
            return ([], nil, nil, MessageError("offline"))
        }
        var first = (result: MethodResult?.none, error: Error?.none)
        first = h.call("sessions", "{}")
        func diskLabel(_ value: (MethodResult?, Error?)) -> String? {
            if let failure = value.1 { XCTFail("\(failure)"); return nil }
            guard case .sessions(_, let items, _, _, _) = value.0 else { XCTFail("shape"); return nil }
            return items.first?.label
        }
        if diskLabel(first) != "Disk" {
            XCTFail("disk result=\(String(describing: first.0)) err=\(String(describing: first.1))")
        }
        if !hook.waitStarted(1) {
            XCTFail("background refresh did not start")
        }
        for _ in 0..<100 {
            let (_, error) = h.call("sessions", "{}")
            if let error {
                XCTFail("\(error)")
            }
        }
        hook.release()
        waitSnapshot(h)
        let again = h.call("sessions", "{}")
        if diskLabel(again) != "Disk" || scans.load() != 1 {
            XCTFail("failed refresh lost disk rows: \(String(describing: again.0)) \(scans.load())")
        }
    }

    func testContextRecomputesOriginWithoutMutatingSnapshot() throws {
        let h = warmHandler()
        let base = h.launcher.items ?? []
        for session in ["session:a", "session:b", "session:a"] {
            let (_, contextError) = h.call("context", "{\"session\":\"\(session)\",\"block\":\"block:a\"}")
            if let contextError {
                XCTFail("\(contextError)")
            }
            let (result, error) = h.call("sessions", "{}")
            if let error {
                XCTFail("\(error)")
            }
            guard case .sessions(_, let items, _, _, _) = result else {
                XCTFail("unexpected sessions result")
                return
            }
            if items[0].sessionID != session || !items[0].active || items[1].active {
                XCTFail("origin=\(session) rows=\(items.map { $0.sessionID })")
            }
            let (agentsResult, agentsError) = h.call("agents", "{}")
            if let agentsError {
                XCTFail("\(agentsError)")
            }
            guard case .agents(let agents, _) = agentsResult else {
                XCTFail("unexpected agents result")
                return
            }
            if agents[0].active != (session == "session:a") {
                XCTFail("agents=\(agents.map { $0.active })")
            }
        }
        for (i, item) in (h.launcher.items ?? []).enumerated() {
            if i < base.count && item != base[i] {
                XCTFail("filter mutated base snapshot")
            }
        }
        if h.activityAgents[0].active {
            XCTFail("agent filtering mutated base")
        }
    }

    func testServeCancellationDoesNotWaitForBackgroundSnapshot() {
        for eof in [false, true] {
            subtest(String(eof), {
                env.set("XDG_CACHE_HOME", makeTempDir())
                let h = warmHandler()
                let hook = BlockingHook()
                addTeardown {
                    hook.release()
                    waitSnapshot(h)
                }
                h.loadSnapshot = { _, _ in
                    hook.markStarted()
                    hook.waitRelease(30)
                    return ([], nil, nil, nil)
                }
                let notifications = Counter()
                h.notify = {
                    _ = notifications.add()
                }
                h.requestRefresh()
                if !hook.waitStarted(1) {
                    XCTFail("refresh did not start")
                    return
                }
                let input = Pipe()
                let cancel = CancelToken()
                final class Box: @unchecked Sendable {
                    var error: Error?
                    var done = false
                }
                let box = Box()
                let serveThread = Thread {
                    do {
                        try h.serveContext(input: PipeInput(input), output: DataOutput(), cancel: cancel)
                    } catch {
                        box.error = error
                    }
                    box.done = true
                }
                serveThread.start()
                if eof {
                    try? input.fileHandleForWriting.close()
                } else {
                    cancel.cancel()
                }
                let deadline = Date().addingTimeInterval(1)
                while !box.done && Date() < deadline {
                    usleep(10_000)
                }
                if !box.done {
                    XCTFail("shutdown waited for snapshot")
                }
                if let error = box.error {
                    XCTFail("\(error)")
                }
                hook.release()
                waitSnapshot(h)
                if notifications.load() != 0 {
                    XCTFail("old worker notified after shutdown")
                }
                if h.launcher.items?[0].label != "Other" {
                    XCTFail("old worker published after shutdown")
                }
            })
        }
    }

    func testColdSuccessfulEmptySnapshotOnlyScansOnce() {
        env.set("XDG_CACHE_HOME", makeTempDir())
        let h = Handler(ctx: Ctx(), cfg: .default())
        var scans = 0
        h.loadSnapshot = { _, _ in
            scans += 1
            return ([], nil, nil, nil)
        }
        for _ in 0..<100 {
            for method in ["sessions", "agents"] {
                let (_, error) = h.call(method, "{}")
                if let error {
                    XCTFail("\(error)")
                }
            }
        }
        if scans != 1 {
            XCTFail("empty snapshot scans=\(scans)")
        }
    }

    func testWarmQueriesMakeNoNativeCalls() throws {
        let dir = makeTempDir()
        let log = dir + "/calls"
        env.set("PATH", dir + ":" + (env.get("PATH") ?? ""))
        env.set("SNAPSHOT_CALLS", log)
        for name in ["rex", "ssh", "zoxide"] {
            try put(dir + "/" + name, "#!/bin/sh\necho called >> \"$SNAPSHOT_CALLS\"\nexit 1\n")
        }
        let h = warmHandler()
        // Short, unresolved origin must not cause per-row target.resolve calls.
        h.ctx.session = "a"
        h.launcher.items?[0].active = true // stale origin flags must be ignored
        for _ in 0..<100 {
            for method in ["sessions", "agents"] {
                let (_, error) = h.call(method, "{\"query\":\"O\"}")
                if let error {
                    XCTFail("\(error)")
                }
            }
        }
        if fileExists(log) {
            XCTFail("warm query invoked native helper: \(String(describing: try? readFile(log)))")
        }
    }

    func testContextChangeDuringRefreshRejectsOldPublication() {
        env.set("XDG_CACHE_HOME", makeTempDir())
        let h = warmHandler()
        let hook = BlockingHook()
        addTeardown {
            hook.release()
            waitSnapshot(h)
        }
        let scans = Counter()
        let notifications = NotificationBox()
        h.notify = {
            notifications.push(h.launcher.items?[0].label ?? "")
        }
        h.loadSnapshot = { origin, _ in
            let n = scans.add()
            if !origin.session.isEmpty {
                XCTFail("origin leaked into base snapshot")
                return ([], nil, nil, MessageError("origin leaked"))
            }
            if n == 1 {
                hook.markStarted()
                hook.waitRelease(30)
            }
            return (
                [AgentEntry(sessionID: "session:b", blockID: "block:b")],
                [LauncherItem(kind: "session", id: "session:b", sessionID: "session:b", label: String(n), local: true)],
                nil, nil
            )
        }
        h.requestRefresh()
        if !hook.waitStarted(1) {
            XCTFail("refresh did not start")
            return
        }
        let (_, contextError) = h.call("context", "{\"session\":\"session:b\",\"block\":\"block:b\"}")
        if let contextError {
            XCTFail("\(contextError)")
        }
        hook.release()
        waitSnapshot(h)
        if scans.load() != 2 || notifications.count != 1 || notifications.popIfAvailable() != "2" {
            XCTFail("old presentation published or final update lost: scans=\(scans.load()) notifications=\(notifications.count)")
        }
        let (result, error) = h.call("agents", "{}")
        if let error {
            XCTFail("\(error)")
            return
        }
        guard case .agents(let agents, _) = result else {
            XCTFail("unexpected agents result")
            return
        }
        if !agents[0].active {
            XCTFail("new origin=\(agents.map { $0.active })")
        }
    }

    func testFailedHostRetainsRowsButSuccessfulEmptyHostClearsRows() {
        env.set("XDG_CACHE_HOME", makeTempDir())
        let h = warmHandler()
        h.launcher.items?[0].host = "remote"
        h.launcher.items?[1].host = "local"
        h.storeLauncher(h.cacheGeneration(), nil, [
            HostHeader(label: "remote", reachable: false),
            HostHeader(label: "local", local: true, reachable: true),
        ])
        let (first, _) = h.readLauncherCache()
        if (first.items ?? []).count != 1 || first.items?[0].host != "remote" {
            XCTFail("rows=\(String(describing: first.items))")
        }
        h.storeLauncher(h.cacheGeneration(), nil, [HostHeader(label: "remote", reachable: true)])
        let (second, _) = h.readLauncherCache()
        if (second.items ?? []).count != 0 || !h.launcherLoaded {
            XCTFail("successful empty snapshot=\(String(describing: second.items))")
        }
    }

    /// Port of BenchmarkWarmSnapshotQueries: warm queries never hit the backend.
    func testBenchmarkWarmSnapshotQueries() {
        let h = warmHandler()
        for i in 0..<100 {
            h.launcher.items?.append(LauncherItem(
                kind: "session", id: "session:\(i)", sessionID: "session:\(i)",
                label: "Project \(i)", local: true))
            h.activityAgents.append(AgentEntry(label: "Project \(i)", sessionID: "session:\(i)"))
        }
        h.loadSnapshot = { _, _ in
            fatalError("warm query called backend")
        }
        for method in ["sessions", "agents"] {
            subtest(method, {
                for _ in 0..<100 {
                    let (_, error) = h.call(method, "{\"query\":\"Pro\"}")
                    if let error {
                        XCTFail("\(error)")
                    }
                }
            })
        }
    }
}
