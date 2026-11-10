import Foundation
import RaptorCatalog
import RaptorRex
import XCTest
@testable import RaptorAPI

final class SnapshotLifecycleTests: APITestCase {
    func testServeContextCancellationUnblocksColdRequests() {
        for method in ["sessions", "agents"] {
            subtest(method, {
                env.set("XDG_CACHE_HOME", makeTempDir())
                let h = Handler(ctx: Ctx(), cfg: .default())
                final class Gates: @unchecked Sendable {
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
                let gates = Gates()
                let scans = Counter()
                h.loadSnapshot = { _, _ in
                    if scans.add() == 1 {
                        gates.markStarted()
                    }
                    gates.waitRelease(30)
                    return ([AgentEntry(label: "Late agent")], [LauncherItem(kind: "session", id: "", label: "Late session")], nil, nil)
                }
                let cancel = CancelToken()
                let output = DataOutput()
                final class Box: @unchecked Sendable {
                    var error: Error?
                    var done = false
                }
                let box = Box()
                let serveInput = DataInput("{\"id\":1,\"method\":\"\(method)\",\"params\":{}}")
                let serveThread = Thread {
                    do {
                        try h.serveContext(input: serveInput, output: output, cancel: cancel)
                    } catch {
                        box.error = error
                    }
                    box.done = true
                }
                serveThread.start()
                addTeardown {
                    cancel.cancel()
                    gates.release()
                    h.cacheMu.lock()
                    let started = h.refreshDone != nil
                    h.cacheMu.unlock()
                    if started {
                        waitSnapshot(h)
                    }
                }
                if !gates.waitStarted(1) {
                    XCTFail("cold request did not start discovery")
                    return
                }
                cancel.cancel()
                let deadline = Date().addingTimeInterval(1)
                while !box.done && Date() < deadline {
                    usleep(10_000)
                }
                if !box.done {
                    XCTFail("shutdown waited for first snapshot loader")
                    return
                }
                if let error = box.error {
                    XCTFail("\(error)")
                }
                if !output.text.isEmpty {
                    XCTFail("canceled request wrote a response: \(output.text)")
                }
                if scans.load() != 1 {
                    XCTFail("scans = \(scans.load()), want one bounded worker")
                }
            })
        }
    }

    func testFailedHostMergeKeepsSessionsBeforeStableFolders() throws {
        env.set("XDG_CACHE_HOME", makeTempDir())
        let h = Handler(ctx: Ctx(), cfg: .default())
        h.launcherLoaded = true
        h.launcher.items = [
            LauncherItem(kind: "session", id: "session:remote", sessionID: "session:remote", host: "remote"),
            LauncherItem(kind: "dir", id: "/remote", path: "/remote", host: "remote"),
        ]
        let fresh: [LauncherItem] = [
            LauncherItem(kind: "session", id: "session:local", sessionID: "session:local", host: Rex.localHostLabel, local: true),
            LauncherItem(kind: "dir", id: "/local-one", path: "/local-one", host: Rex.localHostLabel, local: true),
            LauncherItem(kind: "dir", id: "/local-two", path: "/local-two", host: Rex.localHostLabel, local: true),
        ]
        h.storeLauncher(h.cacheGeneration(), fresh, [
            HostHeader(label: Rex.localHostLabel, local: true, reachable: true),
            HostHeader(label: "remote", reachable: false),
        ])
        func ids(_ items: [LauncherItem]?) -> [String] {
            (items ?? []).map { $0.id }
        }
        let want = ["session:local", "session:remote", "/local-one", "/local-two", "/remote"]
        let (cached, _) = h.readLauncherCache()
        if ids(cached.items) != want {
            XCTFail("merged order = \(ids(cached.items)), want \(want)")
        }
        // MRU can reorder the merged sessions, but cannot move the folders.
        h.ranks = SessionRecency(["remote\u{0}session:remote": 0])
        let (result, error) = h.call("sessions", "{}")
        if let error {
            XCTFail("\(error)")
            return
        }
        guard case .sessions(_, let items, _, _, _) = result else {
            XCTFail("unexpected sessions result")
            return
        }
        var mruWant = want
        mruWant.swapAt(0, 1)
        if ids(items) != mruWant {
            XCTFail("MRU order = \(ids(items)), want \(mruWant)")
        }
        if ids(fresh) != ["session:local", "/local-one", "/local-two"] {
            XCTFail("merge changed fresh rows: \(ids(fresh))")
        }
    }
}
