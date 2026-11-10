import Foundation
import RaptorCatalog
import RaptorRex
import XCTest
@testable import RaptorAPI

final class RefreshProgressTests: APITestCase {
    func testContinuousEventsPublishProgressAndUnblockColdSearch() throws {
        env.set("XDG_CACHE_HOME", makeTempDir())
        let h = Handler(ctx: Ctx(), cfg: .default())
        let started = SignalQueue()
        final class Release: @unchecked Sendable {
            private let semaphore = DispatchSemaphore(value: 0)
            func release() { semaphore.signal() }
            func wait() { semaphore.wait() }
        }
        let release = Release()
        let scans = Counter()
        let failure = DispatchSemaphore(value: 0)
        final class FailBox: @unchecked Sendable {
            var error: Error?
        }
        let failBox = FailBox()
        h.loadSnapshot = { _, _ in
            let n = scans.add()
            started.send(n)
            release.wait()
            return ([], [LauncherItem(id: "", label: String(n))], nil, nil)
        }
        addTeardown {
            release.release()
            waitSnapshot(h)
        }
        final class Rows: @unchecked Sendable {
            var result: MethodResult?
        }
        let rows = Rows()
        let callThread = Thread {
            let (result, error) = h.call("sessions", "{}")
            if let error {
                failBox.error = error
                failure.signal()
                return
            }
            rows.result = result
            failure.signal()
        }
        callThread.start()
        if started.waitOne(1) == nil {
            XCTFail("cold scan did not start")
            return
        }
        for _ in 0..<100 {
            h.requestRefresh()
        }
        release.release()
        if started.waitOne(1) == nil {
            XCTFail("follow-up scan did not start")
        }
        let waitResult = failure.wait(timeout: .now() + 1)
        if waitResult != .success {
            XCTFail("cold request waited for continuous events to stop")
            return
        }
        if failBox.error != nil {
            XCTFail("\(failBox.error!)")
        }
        // The dirty follow-up is still blocked; the cold request got the first
        // complete snapshot.
        guard case .sessions(_, let items, _, _, _) = rows.result else {
            XCTFail("unexpected sessions result")
            return
        }
        if items[0].label != "1" {
            XCTFail("cold request lost first complete snapshot: \(items[0].label)")
        }
        // More events must not suppress the next complete snapshot either.
        h.requestRefresh()
        release.release()
        if started.waitOne(1) == nil {
            XCTFail("second follow-up scan did not start")
        }
        let (cached, _) = h.readLauncherCache()
        if cached.items?[0].label != "2" {
            XCTFail("continuous activity starved publication: \(String(describing: cached.items))")
        }
        release.release()
        waitSnapshot(h)
        let (finalCache, _) = h.readLauncherCache()
        if scans.load() != 3 || finalCache.items?[0].label != "3" {
            XCTFail("final coalesced refresh was lost: scans=\(scans.load())")
        }
    }

    func testPinMutationPatchesWarmSnapshotBeforeBackgroundRefresh() throws {
        env.set("HOME", makeTempDir())
        env.set("XDG_CACHE_HOME", makeTempDir())
        let h = warmHandler()
        let a = makeTempDir() + "/a"
        let b = makeTempDir() + "/b"
        h.launcher.items = [
            LauncherItem(kind: "dir", id: a, path: a, local: true),
            LauncherItem(kind: "dir", id: b, path: b, local: true),
        ]
        let started = SignalQueue()
        final class Release: @unchecked Sendable {
            private let semaphore = DispatchSemaphore(value: 0)
            func release() { semaphore.signal() }
            func wait() { semaphore.wait() }
        }
        let release = Release()
        let scans = Counter()
        h.loadSnapshot = { _, _ in
            let n = scans.add()
            started.send(n)
            release.wait()
            return ([], [
                LauncherItem(kind: "dir", id: a, path: a, local: true),
                LauncherItem(kind: "dir", id: b, path: b, local: true, pinned: n == 1),
            ], nil, nil)
        }
        addTeardown {
            release.release()
            waitSnapshot(h)
        }
        let params = JS.object([("path", .string(b))])
        let (toggleResult, toggleError) = h.callJSON("pins.toggle", params)
        if let toggleError {
            XCTFail("\(toggleError)")
            return
        }
        _ = toggleResult
        if started.waitOne(1) == nil {
            XCTFail("pin refresh did not start")
            return
        }
        let (result, error) = h.call("sessions", "{}")
        if let error {
            XCTFail("\(error)")
            return
        }
        guard case .sessions(_, let rows, _, _, _) = result else {
            XCTFail("unexpected sessions result")
            return
        }
        if rows[0].path != b || !rows[0].pinned {
            XCTFail("pin waited for Rex instead of patching cached rows: \(rows)")
        }
        let (_, unpinError) = h.callJSON("pins.toggle", params)
        if let unpinError {
            XCTFail("\(unpinError)")
        }
        release.release()
        if started.waitOne(1) == nil {
            XCTFail("unpin follow-up did not start")
        }
        let (cached, _) = h.readLauncherCache()
        for row in cached.items ?? [] where row.pinned {
            XCTFail("an older scan undid the unpin mutation")
        }
        release.release()
        waitSnapshot(h)
    }
}
