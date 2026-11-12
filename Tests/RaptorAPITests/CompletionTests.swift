import Foundation
import RaptorCatalog
import RaptorRex
import XCTest
@testable import RaptorAPI

final class CompletionTests: APITestCase {
    let source = CompletionSource(block: "b", record: "child", state: "done", updatedAt: "2026-06-12T10:11:12.923999Z")

    func testLateReceiptsOverlaySameCachedRowsAndNotificationDoesNotScan() throws {
        env.set("XDG_CACHE_HOME", makeTempDir())
        let h = Handler(ctx: Ctx(session: "s"), cfg: .default())
        var seen = false
        var loads = 0
        h.loadReceipts = {
            loads += 1
            let receipt: [String: Any] = ["block": "b", "record": "child", "date": Date(timeIntervalSince1970: 1781259072.923)]
            return ["Workspace.programActivitySeen": ["receipts": seen ? [receipt] : []]]
        }
        var scans = 0
        h.loadSnapshot = { _, _ in
            scans += 1
            XCTFail("warm receipt updates must not scan")
            return ([], [], [], nil)
        }
        h.activityAgents = [AgentEntry(state: "idle", agentID: "child", sessionID: "s", blockID: "b", completionSource: source)]
        h.activityLoaded = true
        h.launcher = LauncherCacheEntry(items: [LauncherItem(kind: "session", id: "s", sessionID: "s", host: "remote", state: "working", working: true, completionSources: [source])])
        h.launcherLoaded = true
        var notifications = 0
        h.notify = { notifications += 1 }
        func session() throws -> LauncherItem {
            let (result, error) = h.call("sessions", "{}")
            XCTAssertNil(error)
            guard case .sessions(_, let items, _, _, _) = result else { throw NSError(domain: "unexpected result", code: 1) }
            return try XCTUnwrap(items.first)
        }
        XCTAssertTrue(try session().unreadDone)
        XCTAssertTrue(try h.activitySnapshot(fresh: false)[0].unreadDone)
        let generation = h.cacheGeneration()
        let before = loads
        let (_, error) = h.call("activity.receiptsChanged", "{}")
        XCTAssertNil(error)
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(loads, before, "notification only")
        XCTAssertEqual(h.cacheGeneration(), generation)
        XCTAssertFalse(h.revalidating)
        seen = true
        let updated = try session()
        XCTAssertFalse(updated.unreadDone)
        XCTAssertEqual(updated.state, "working")
        XCTAssertTrue(updated.working)
        XCTAssertFalse(try h.activitySnapshot(fresh: false)[0].unreadDone)
        XCTAssertEqual(scans, 0)
        XCTAssertEqual(h.launcher.items?[0].completionSources, [source])
    }

    func testDiskMetadataRoundTripAndOldCacheFallback() throws {
        env.set("XDG_CACHE_HOME", makeTempDir())
        let item = LauncherItem(kind: "session", id: "s", sessionID: "s", completionSources: [source])
        let disk = encodeLauncherCache(LauncherCacheEntry(items: [item]))
        let decoded = try XCTUnwrap(decodeLauncherCache(disk))
        XCTAssertEqual(decoded.items?.first?.completionSources, [source])
        let h = Handler(ctx: Ctx(), cfg: .default())
        h.loadReceipts = { ["Workspace.programActivitySeen": [:]] }
        try FileManager.default.createDirectory(atPath: (h.launcherCachePath() as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try disk.write(to: URL(fileURLWithPath: h.launcherCachePath()), options: .atomic)
        XCTAssertTrue(h.readLauncherCache().0.items?.first?.unreadDone == true)
        let old = Data(#"{"items":[{"kind":"session","id":"old","state":"idle","unread_done":true}]}"#.utf8)
        h.launcher = try XCTUnwrap(decodeLauncherCache(old))
        XCTAssertFalse(h.readLauncherCache().0.items![0].unreadDone)
        h.loadReceipts = { nil }
        h.launcher = decoded
        XCTAssertFalse(h.readLauncherCache().0.items![0].unreadDone)
    }

    func testAgentWireHasOnlyDerivedUnreadFlag() {
        var agent = AgentEntry(state: "idle", completionSource: source)
        XCTAssertFalse(agentEntryJS(agent).encode().contains("unread_done"))
        agent.unreadDone = true
        let wire = agentEntryJS(agent).encode()
        XCTAssertTrue(wire.contains("\"unread_done\":true"))
        XCTAssertFalse(wire.contains("completion"))
    }
}
