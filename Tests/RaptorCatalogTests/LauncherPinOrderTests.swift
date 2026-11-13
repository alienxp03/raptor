import Foundation
import XCTest
import RaptorConfig
import RaptorRex
@testable import RaptorCatalog

final class LauncherPinOrderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        let home = testTempDir()
        setenvTemp("HOME", home)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: home) }
    }

    private func pin(_ id: String, _ host: String = "Mac") throws {
        try RaptorConfig.toggleSessionPin(sessionID: id, host: host)
    }

    private func session(_ id: String, _ host: String = "Mac", active: Bool = false) -> LauncherItem {
        LauncherItem(kind: "session", id: host + "-" + id, sessionID: id,
                     label: id, host: host, active: active, local: host == "Mac")
    }

    private func present(_ source: [LauncherItem]) -> [LauncherItem] {
        var rows = source
        Catalog.applyLauncherPins(&rows)
        return Catalog.pinLauncherOrigin(rows, "")
    }

    func testSavedPinOrderSurvivesRecencyOriginAndCachedRowChanges() throws {
        try pin("a")
        try pin("b")
        try pin("c")
        let a = session("a"), b = session("b"), c = session("c")
        let origin = session("origin", active: true), other = session("other")
        for source in [[c, other, b, origin, a], [origin, b, a, c, other]] {
            let rows = present(source)
            XCTAssertEqual(rows.map(\.sessionID), ["a", "b", "c", "origin", "other"])
            XCTAssertEqual(Catalog.preferredLauncherID(rows, ""), origin.id)
            XCTAssertEqual(Catalog.filterLauncherItems(rows, "", ""), rows)
        }
    }

    func testRepinMovesToEndWithoutSortingByReusedShortcutSlot() throws {
        try pin("a")
        try pin("b")
        try pin("c")
        try pin("b") // Unpin, preserving slots 1 and 3.
        let source = [session("b"), session("c"), session("a")]
        XCTAssertEqual(present(source).map(\.sessionID), ["a", "c", "b"])
        try pin("b") // Append to saved order, reusing slot 2.
        let rows = present(source)
        XCTAssertEqual(rows.map(\.sessionID), ["a", "c", "b"])
        XCTAssertEqual(rows.map(\.pinSlot), [1, 3, 2])
        XCTAssertEqual(RaptorConfig.loadSessionPins().map(\.sessionID), ["a", "c", "b"])
    }

    func testCompositionUsesHostIdentityAndKeepsSearchRelevance() throws {
        try pin("shared", "two")
        try pin("shared", "one")
        let groups = [HostGroup(label: "one", reachable: true, entries: [
            SessionEntry(kind: "session", id: "one", sessionID: "shared", label: "exact", host: "one"),
            SessionEntry(kind: "session", id: "two", sessionID: "shared", label: "e--x--a--c--t", host: "two"),
        ])]
        XCTAssertEqual(Catalog.launcherItems(groups, [], [:], "", [], "Mac").map(\.id), ["two", "one"])
        XCTAssertEqual(Catalog.launcherItems(groups, [], [:], "exact", [], "Mac").map(\.id), ["one", "two"])
        XCTAssertEqual(Catalog.launcherItems(groups, [], [:], "", [], "Mac", prioritizePins: false).map(\.id), ["one", "two"])
    }

    func testDirectoryPinsUseSavedOrderAndUnknownPinsRemainStable() throws {
        try pin("a")
        try RaptorConfig.savePins(["/first", "/second"])
        let source = [
            LauncherItem(kind: "dir", id: "/second", path: "/second", local: true),
            session("a"),
            LauncherItem(kind: "dir", id: "/first", path: "/first", local: true),
            session("other"),
        ]
        XCTAssertEqual(present(source).map(\.id), ["Mac-a", "/first", "/second", "Mac-other"])
        let unknown = [LauncherItem(id: "x", pinned: true), LauncherItem(id: "y", pinned: true)]
        XCTAssertEqual(Catalog.pinnedLauncherFirst(unknown).map(\.id), ["x", "y"])
    }
}
