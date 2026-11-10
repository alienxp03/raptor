import XCTest
@testable import RaptorRex

final class AgentOrderTests: XCTestCase {
    func testAgentGroupTimeOrder() {
        let now = Date()
        let old = now.addingTimeInterval(-3600)
        let zero = Rex.zeroTime
        var entries = [
            AgentEntry(label: "idle", state: "idle", updatedAt: now),
            AgentEntry(label: "missing", state: "blocked"),
            AgentEntry(label: "old", state: "blocked", updatedAt: old),
            AgentEntry(label: "work", state: "working", updatedAt: now),
            AgentEntry(label: "z-tie", state: "blocked", updatedAt: now),
            AgentEntry(label: "a-tie", state: "blocked", updatedAt: now),
            AgentEntry(label: "zero", state: "blocked", updatedAt: zero),
        ]
        Rex.sortGroups(&entries)
        let labels = entries.map { $0.label }
        XCTAssertEqual(labels, ["z-tie", "a-tie", "old", "missing", "zero", "work", "idle"])
    }

    func testAgentNativeTimeAndCwd() throws {
        // Go feeds raw JSON values ("null", 42, {}, \"bad\", zero time, \"\", empty);
        // the Swift port only receives the decoded string form, so the numeric and
        // object shapes surface as nil before parsing.
        for raw in [nil, "bad", "", "0001-01-01T00:00:00Z"] as [String?] {
            if let got = Rex.agentUpdatedAt(raw) {
                XCTFail("raw=\(raw ?? "nil") got=\(got)")
            }
        }
        setenvTemp("XDG_CACHE_HOME", testTempDir())
        let now = Date()
        let dir = testCacheDir() + "/agents"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = "{\"pid\":42,\"app\":\"pi\",\"name\":\"Named\",\"block_id\":\"b\",\"session_id\":\"s\",\"updated_at\":\"\(Rex.formatRFC3339(now))\"}"
        try Data(data.utf8).write(to: URL(fileURLWithPath: dir + "/pi-42.json"))
        let snapshot = "{\"sessions\":[{\"session_id\":\"s\",\"windows\":[{\"window_id\":\"w\",\"blocks\":[{\"block_id\":\"b\",\"process\":{\"foreground\":{\"pid\":42,\"name\":\"node\",\"cwd\":\"/repo/sub\"}},\"records\":[{\"id\":\"z\",\"app\":\"pi\",\"owner\":{\"pid\":42,\"name\":\"node\"},\"state\":\"working\",\"updated_at\":\"bad\"},{\"id\":\"a\",\"app\":\"codex\",\"state\":\"working\",\"updated_at\":\"2025-01-01T00:00:00Z\"},{\"id\":\"b\",\"app\":\"pi\",\"state\":\"working\"}]}]}]}]}"
        let entries = try Rex.decodeAgentEntries(Data(snapshot.utf8), "s", now)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].agentID, "a")
        XCTAssertEqual(entries[1].agentID, "z")
        XCTAssertEqual(entries[2].agentID, "b")
        XCTAssertEqual(entries[1].label, "Named")
        XCTAssertNil(entries[1].updatedAt)
        XCTAssertNil(entries[2].updatedAt)
        for e in entries {
            XCTAssertEqual(e.cwd, "/repo/sub")
        }
    }

    func testApplySessionActivity() {
        var entries = [
            SessionEntry(kind: "session", sessionID: "s"),
            SessionEntry(kind: "window", id: "w", sessionID: "s"),
            SessionEntry(kind: "window", id: "idle", sessionID: "s"),
            SessionEntry(kind: "window", id: "w", sessionID: "other"),
            SessionEntry(kind: "session", id: "", sessionID: "empty", state: "blocked", working: true),
        ]
        let agents = [
            AgentEntry(state: "blocked", sessionID: "s", windowID: "w"),
            AgentEntry(state: "working", sessionID: "s", windowID: "w"),
            AgentEntry(state: "idle", sessionID: "s", windowID: "idle"),
        ]
        Rex.applySessionActivity(&entries, agents)
        let want: [(String, Bool)] = [("blocked", true), ("blocked", true), ("idle", false), ("", false), ("", false)]
        for (i, w) in want.enumerated() {
            XCTAssertEqual(entries[i].state, w.0, "row \(i)")
            XCTAssertEqual(entries[i].working, w.1, "row \(i)")
        }
        Rex.applySessionActivity(&entries, [])
        for e in entries {
            XCTAssertEqual(e.state, "")
            XCTAssertFalse(e.working)
        }
    }
}
