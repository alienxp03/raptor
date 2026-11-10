import Foundation
import XCTest
import RaptorRex
@testable import RaptorCatalog

final class ActivityTests: XCTestCase {
    func testDirectoryActivityExactCanonicalMatch() throws {
        let root = testTempDir()
        let repo = root + "/repo"
        let sub = repo + "/sub"
        try makeDirectory(sub)
        let alias = root + "/alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: repo)
        var items = [
            Directory(path: repo), Directory(path: alias), Directory(path: sub), Directory(path: repo + "-other"),
            Directory(path: "", state: "blocked", working: true), Directory(path: root), Directory(path: root + "/idle"),
        ]
        let agents = [
            AgentEntry(state: "working", cwd: alias + "/sub"),
            AgentEntry(state: "blocked", cwd: repo),
            AgentEntry(state: "idle", cwd: root + "/idle"),
            AgentEntry(state: "blocked", cwd: ""),
        ]
        Catalog.applyDirectoryActivity(&items, agents)
        let want: [(String, Bool)] = [
            ("blocked", false), ("blocked", false), ("working", true), ("", false), ("", false), ("", false), ("idle", false),
        ]
        for (i, w) in want.enumerated() {
            XCTAssertTrue(items[i].state == w.0 && items[i].working == w.1, "row \(i)=\(items[i])")
        }
        Catalog.applyDirectoryActivity(&items, [])
        for item in items {
            XCTAssertTrue(item.state.isEmpty && !item.working, "stale=\(item)")
        }
    }

    func testRemoteActivityDoesNotResolveLocalSymlinks() throws {
        let root = testTempDir()
        let repo = root + "/repo"
        let alias = root + "/alias"
        try makeDirectory(repo + "/sub")
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: repo)
        let agents = [AgentEntry(state: "working", cwd: repo)]
        var items = [Directory(path: alias), Directory(path: repo)]
        Catalog.applyDirectoryActivityOn(host: "remote", items: &items, agents: agents)
        XCTAssertTrue(!items[0].working && items[1].working, "remote paths used local symlinks: \(items)")
        Catalog.applyDirectoryActivityOn(host: Rex.localHostLabel, items: &items, agents: agents)
        XCTAssertTrue(items[0].working && items[1].working, "local symlink projection lost: \(items)")
    }

    func testFilterAgentsKeepsGroupAndTimeOrder() throws {
        let entries = [
            AgentEntry(label: "a long review task", state: "blocked"),
            AgentEntry(label: "review", state: "working"),
            AgentEntry(label: "review", state: "idle"),
        ]
        XCTAssertEqual(Catalog.filterAgents(entries, "review"), [0, 1, 2], "indices")
    }
}
