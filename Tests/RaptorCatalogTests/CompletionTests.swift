import Foundation
import RaptorRex
import XCTest
@testable import RaptorCatalog

final class CompletionTests: XCTestCase {
    func testMixedActivityKeepsIndependentUnreadAndExactCwdSources() throws {
        let source = CompletionSource(block: "b", state: "done", updatedAt: "2026-06-12T10:11:12Z")
        var done = AgentEntry(state: "idle", sessionID: "s", windowID: "w", cwd: "/repo/sub", completionSource: source)
        done.unreadDone = true
        let working = AgentEntry(state: "working", sessionID: "s", windowID: "w", cwd: "/repo/sub")
        let blocked = AgentEntry(state: "blocked", sessionID: "s", windowID: "w", cwd: "/repo/sub")
        var sessions = [SessionEntry(kind: "session", sessionID: "s"), SessionEntry(kind: "window", id: "other", sessionID: "s")]
        Rex.applySessionActivity(&sessions, [working, done])
        XCTAssertEqual(sessions[0].state, "working")
        XCTAssertTrue(sessions[0].working)
        XCTAssertTrue(sessions[0].unreadDone)
        XCTAssertEqual(sessions[0].completionSources, [source])
        XCTAssertFalse(sessions[1].unreadDone)
        var directories = [Directory(path: "/repo", label: "repo"), Directory(path: "/repo/sub", label: "sub")]
        Catalog.applyDirectoryActivityOn(host: "remote", items: &directories, agents: [working, done, blocked])
        XCTAssertFalse(directories[0].unreadDone)
        XCTAssertTrue(directories[1].unreadDone)
        XCTAssertTrue(directories[1].working)
        XCTAssertEqual(directories[1].state, "blocked")
        XCTAssertEqual(directories[1].completionSources, [source])
        Rex.applySessionActivity(&sessions, [blocked])
        XCTAssertEqual(sessions[0].state, "blocked")
        XCTAssertFalse(sessions[0].unreadDone)
        let rows = Catalog.launcherItems([HostGroup(label: "remote", reachable: true, entries: sessions)], ["remote"], ["remote": directories], "", [], "local")
        XCTAssertEqual(rows.first(where: { $0.kind == "dir" && $0.path == "/repo/sub" })?.completionSources, [source])
        let data = try JSONEncoder().encode(directories[1])
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"unread_done\":true"))
    }
}
