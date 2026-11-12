import Foundation
import XCTest
@testable import RaptorCatalog

final class PreferredLauncherTests: XCTestCase {
    func testPreferredLauncherID() throws {
        let current = LauncherItem(kind: "session", id: "current", active: true)
        let recent = LauncherItem(kind: "session", id: "recent")
        let older = LauncherItem(kind: "session", id: "older")
        let dir = LauncherItem(kind: "dir", id: "/repo")
        // Subtests mirroring the Go table.
        let cases: [(name: String, items: [LauncherItem], query: String, want: String)] = [
            ("current first", [current, recent, older, dir], "", "current"),
            ("no history keeps incoming order", [older, recent], "", "older"),
            ("current and directory", [current, dir], "", "current"),
            ("directories only", [dir], "", "/repo"),
            ("only current", [current], "", "current"),
            ("empty", [], "", ""),
            ("search prefers rank even current", [current, recent], "cur", "current"),
            ("search prefers directory rank", [dir, recent], "repo", "/repo"),
            ("no query matches", [], "missing", ""),
        ]
        for tc in cases {
            let got = Catalog.preferredLauncherID(tc.items, tc.query)
            XCTAssertEqual(got, tc.want, "[\(tc.name)] got \"\(got)\" want \"\(tc.want)\"")
        }
    }

    func testPreferredLauncherFilteredResults() throws {
        let items = [
            LauncherItem(kind: "session", id: "current", label: "r--e--p--o", active: true),
            LauncherItem(kind: "dir", id: "/repo", path: "/repo", label: "repo"),
        ]
        let filtered = Catalog.filterLauncherItems(items, "repo", "current")
        XCTAssertEqual(Catalog.preferredLauncherID(filtered, "repo"), "current", "matching open sessions must precede folders")
        XCTAssertTrue(filtered.count == 2 && filtered[0].active, "current session must stay available")
    }
}
