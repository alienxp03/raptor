import Foundation
import XCTest
import RaptorPaths
import RaptorRex
@testable import RaptorCatalog

final class LauncherSearchTests: XCTestCase {
    func testLauncherExactFolderNamesLeadFullPathMatches() throws {
        let home = testTempDir()
        setenvTemp("HOME", home)
        var dirs: [Directory] = []
        for relative in [
            "workspace/projects/VoiceInk", "workspace/webmono/projects/frontier/ios/App",
            ".pi", ".dotfiles/pi", "workspace/piza", ".pi/agent",
            "workspace/performance-review", ".pi/agent/extensions",
        ] {
            let p = home + "/" + relative
            dirs.append(Directory(path: p, label: RaptorPaths.homeRelative(p)))
        }
        let hostDirs = [Rex.localHostLabel: dirs]
        func compose(_ query: String) -> [LauncherItem] {
            Catalog.launcherItems([], [Rex.localHostLabel], hostDirs, query, [], "Mac")
        }
        let base = compose("")
        for query in ["pi", "PI", ".pi"] {
            for result in [compose(query), Catalog.filterLauncherItems(base, query, "")] {
                XCTAssertTrue(result.count >= 2 && result[0].path == home + "/.pi", "query \"\(query)\": exact hidden folder must lead: \(result)")
                if query != ".pi" {
                    XCTAssertTrue(result[1].path == home + "/.dotfiles/pi", "query \"\(query)\": exact basename must precede partial/path matches: \(result)")
                }
            }
        }
        XCTAssertEqual(Catalog.filterLauncherItems(base, "", ""), base, "empty search changed the source order")
        for (i, item) in base.enumerated() {
            XCTAssertEqual(item.path, dirs[i].path, "search mutated the cached source order")
        }
    }

    func testMatchingOpenSessionsPrecedeExactFolders() {
        let items = [
            LauncherItem(kind: "dir", id: "/workspace/raptor", path: "/workspace/raptor", label: "raptor"),
            LauncherItem(kind: "dir", id: "/Applications/Raptor.app", path: "/Applications/Raptor.app", label: "Raptor.app"),
            LauncherItem(kind: "session", id: "partial", sessionID: "session:partial", label: "dotfiles-raptor"),
            LauncherItem(kind: "session", id: "exact", sessionID: "session:exact", label: "raptor", host: "remote"),
            LauncherItem(kind: "session", id: "unrelated", sessionID: "session:unrelated", label: "other")
        ]
        for query in ["raptor", "RAPTOR"] {
            let ranked = Catalog.rankLauncherItems(items, query).map { items[$0.index] }
            let filtered = Catalog.filterLauncherItems(items, query, "")
            for result in [ranked, filtered] {
                XCTAssertEqual(result.map(\.id), ["exact", "partial", "/workspace/raptor", "/Applications/Raptor.app"])
                XCTAssertEqual(Catalog.preferredLauncherID(result, query), "exact")
            }
        }
        XCTAssertEqual(Catalog.filterLauncherItems(items, "", ""), items, "Empty search must preserve source ordering")
    }

    func testLauncherMatchesEachFieldSeparately() {
        let items = [
            LauncherItem(kind: "session", id: "split", label: "aurora-pr-10990-fix-cancellation-page-back-navigation", host: "Mac-CT7QTWFHQF-azuan.zairein"),
            LauncherItem(kind: "session", id: "name", label: "dotfiles-raptor", host: "Mac"),
            LauncherItem(kind: "session", id: "host", label: "other", host: "raptor-server"),
            LauncherItem(kind: "dir", id: "path", path: "/workspace/raptor/project", label: "project", host: "Mac"),
            LauncherItem(kind: "dir", id: "split-path", path: "/workspace/rapto", label: "project", host: "remote")
        ]
        let matches = Catalog.filterLauncherItems(items, "raptor", "")
        XCTAssertEqual(Set(matches.map(\.id)), ["name", "host", "path"])
        XCTAssertEqual(matches.map(\.kind), ["session", "session", "dir"])
        XCTAssertTrue(Catalog.filterLauncherItems(items, "Mac", "").contains { $0.id == "split" },
                      "Hostname-only searches must still work")
        XCTAssertTrue(Catalog.filterLauncherItems(items, "dtfls", "").contains { $0.id == "name" },
                      "Fuzzy matches within a single field must still work")
    }

    func testLauncherDeduplicatesMatchingFieldsAndPreservesTies() {
        let items = [
            LauncherItem(kind: "session", id: "recent", label: "raptor", host: "raptor"),
            LauncherItem(kind: "session", id: "older", label: "raptor", host: "raptor"),
            LauncherItem(kind: "dir", id: "folder", path: "/raptor", label: "raptor", host: "raptor")
        ]
        XCTAssertEqual(Catalog.filterLauncherItems(items, "raptor", "").map(\.id), ["recent", "older", "folder"])
    }

    func testLauncherExactNamesPreserveTiesAndCurrentSession() throws {
        var items = [
            LauncherItem(kind: "session", sessionID: "session:recent", label: "pi"),
            LauncherItem(kind: "session", sessionID: "session:older", label: "pi"),
        ]
        var got = Catalog.filterLauncherItems(items, "pi", "")
        XCTAssertEqual(got, items, "equal exact matches lost their existing recency order")
        items.append(LauncherItem(kind: "session", sessionID: "session:origin", label: "p--i", active: true))
        got = Catalog.filterLauncherItems(items, "pi", "session:origin")
        XCTAssertTrue(got.count == 3 && got[0].sessionID == "session:recent" && got[2].sessionID == "session:origin", "current session must remain available without overriding query rank")
    }
}
