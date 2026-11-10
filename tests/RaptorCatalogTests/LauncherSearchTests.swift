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
