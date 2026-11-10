import Foundation
import XCTest
import RaptorRex
@testable import RaptorCatalog

final class SessionOrderTests: XCTestCase {
    func testSessionRecencyOrderingIsScopedStableAndPresentationBound() throws {
        setenvTemp("XDG_CACHE_HOME", testTempDir())
        let now = Date()
        let visits: [(host: String, id: String)] = [
            ("", testRecentSessionID(2)), ("", testRecentSessionID(5)), ("hades", testRecentSessionID(3)),
        ]
        for (i, visit) in visits.enumerated() {
            try Rex.recordSessionVisit(visit.host, visit.id, now.addingTimeInterval(Double(i - 5) * 60), false)
        }
        let ranks = Rex.loadSessionRecency()
        var base: [LauncherItem] = []
        for n in 1...6 {
            base.append(LauncherItem(kind: "session", sessionID: testRecentSessionID(n), label: "work", host: "Mac", local: true))
        }
        base.append(contentsOf: [
            LauncherItem(kind: "session", sessionID: testRecentSessionID(3), label: "remote", host: "hades"),
            LauncherItem(kind: "dir", path: "/folders/a", local: true),
            LauncherItem(kind: "dir", path: "/folders/b", host: "hades"),
        ])
        func ids(_ items: [LauncherItem]) -> [String] {
            items.compactMap { item in
                guard item.kind == "session" else { return nil }
                let host = item.local ? "local" : item.host
                return host + ":" + item.sessionID
            }
        }
        var items = base
        Catalog.orderLauncherSessionsByRecency(&items, ranks)
        let want = [
            "hades:" + testRecentSessionID(3), "local:" + testRecentSessionID(5), "local:" + testRecentSessionID(2),
            "local:" + testRecentSessionID(1), "local:" + testRecentSessionID(3), "local:" + testRecentSessionID(4),
            "local:" + testRecentSessionID(6),
        ]
        XCTAssertEqual(ids(items), want, "MRU order")
        XCTAssertEqual(Array(items[7...]), Array(base[7...]), "session recency changed folder order")
        try Rex.recordSessionVisit("", testRecentSessionID(6), now, false)
        items = base
        Catalog.orderLauncherSessionsByRecency(&items, ranks)
        XCTAssertEqual(ids(items), want, "a new visit changed the captured presentation order")
        Catalog.orderLauncherSessionsByRecency(&items, Rex.loadSessionRecency())
        XCTAssertTrue(items[0].sessionID == testRecentSessionID(6) && items[0].local, "next presentation did not use the latest visit")
        for i in items.indices {
            items[i].active = items[i].local && items[i].sessionID == testRecentSessionID(1)
        }
        items = Catalog.pinLauncherOrigin(items, "")
        XCTAssertEqual(items[0].sessionID, testRecentSessionID(1), "current session must still lead MRU order")
    }

    func testSessionRecencyIsFuzzySearchTieBreaker() throws {
        setenvTemp("XDG_CACHE_HOME", testTempDir())
        try Rex.recordSessionVisit("", testRecentSessionID(2), Date(), false)
        var items = [
            LauncherItem(kind: "session", sessionID: testRecentSessionID(1), label: "work", host: "Mac", local: true),
            LauncherItem(kind: "session", sessionID: testRecentSessionID(2), label: "work", host: "Mac", local: true),
        ]
        Catalog.orderLauncherSessionsByRecency(&items, Rex.loadSessionRecency())
        var filtered = Catalog.filterLauncherItems(items, "work", "")
        XCTAssertTrue(filtered.count == 2 && filtered[0].sessionID == testRecentSessionID(2), "equal fuzzy matches lost MRU order")
        items[0].label = "w--o--r--k"
        filtered = Catalog.filterLauncherItems(items, "work", "")
        XCTAssertEqual(filtered[0].sessionID, testRecentSessionID(1), "recency must not override a better fuzzy match")
    }
}
