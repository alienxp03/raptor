import XCTest
@testable import RaptorRex

final class AgentsTests: XCTestCase {
    func testAgentRecordsSameTabAndFallbacks() throws {
        setenvTemp("XDG_CACHE_HOME", testTempDir())
        let data = Data("{\"sessions\":[{\"session_id\":\"s\",\"label\":\"Project\",\"active_window_id\":\"w\",\"windows\":[{\"window_id\":\"w\",\"label\":\"Build\",\"focused_block_id\":\"b\",\"blocks\":[{\"block_id\":\"b\",\"title\":\"terminal\",\"records\":[{\"id\":\"z\",\"app\":\"Claude-Code\",\"state\":\"blocked\",\"msg\":\"Permission\"},{\"id\":\"a\",\"effective_app\":\"codex\",\"state\":\"working\",\"title\":\"Task\"},{\"app\":\"pi\",\"state\":\"idle\"},{\"id\":\"done\",\"app\":\"pi\",\"state\":\"done\"},{\"id\":\"error\",\"app\":\"pi\",\"state\":\"error\"},{\"id\":\"other\",\"app\":\"cargo\",\"state\":\"working\"}]},{\"block_id\":\"c\",\"records\":[{\"app\":\"@openai/codex\",\"state\":\"unknown\"}]}]}]}]}".utf8)
        let entries = try Rex.decodeAgentEntries(data, "s", Date())
        XCTAssertEqual(entries.count, 6)
        let want: [(String, String, String, String)] = [
            ("b#z", "claude", "terminal", "blocked"),
            ("b#a", "codex", "Task", "working"),
            ("b#", "pi", "terminal", "idle"),
            ("b#done", "pi", "terminal", "idle"),
            ("b#error", "pi", "terminal", "idle"),
            ("c#", "codex", "codex", "idle"),
        ]
        for (i, w) in want.enumerated() {
            let e = entries[i]
            XCTAssertEqual(e.path, w.0, "row \(i)")
            XCTAssertEqual(e.app, w.1, "row \(i)")
            XCTAssertEqual(e.label, w.2, "row \(i)")
            XCTAssertEqual(e.state, w.3, "row \(i)")
            XCTAssertEqual(e.kind, "agent", "row \(i)")
            XCTAssertEqual(e.active, i < 5, "row \(i)")
            XCTAssertEqual(e.windowLabel, "Build", "row \(i)")
            XCTAssertEqual(e.sessionLabel, "Project", "row \(i)")
        }
        for data in ["{}", "{\"sessions\":[]}", "{\"sessions\":[{\"windows\":[]}]}"] {
            let got = try Rex.decodeAgentEntries(Data(data.utf8), "", Date())
            XCTAssertEqual(got.count, 0, "empty=\(got)")
        }
        XCTAssertThrowsError(try Rex.decodeAgentEntries(Data("{".utf8), "", Date()))
    }

    func testAgentWindowContextUsesFocusedTitleForGeneratedLabels() throws {
        setenvTemp("XDG_CACHE_HOME", testTempDir())
        let cases: [(String, String, String)] = [
            ("Window b0439b58", "b", "castty"),
            ("", "b", "castty"),
            ("My work", "b", "My work"),
            ("Window custom", "b", "Window custom"),
            ("Window b0439b58", "other", "Window b0439b58"),
        ]
        for (label, focused, want) in cases {
            let snapshot: [String: Any] = ["sessions": [["session_id": "s", "windows": [[
                "window_id": "window:b0439b58", "label": label, "focused_block_id": focused,
                "blocks": [["block_id": "b", "title": "castty", "records": [["app": "pi", "state": "idle"]]]],
            ]]]]]
            let data = try JSONSerialization.data(withJSONObject: snapshot)
            let entries = try Rex.decodeAgentEntries(data, "s", Date())
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries.first?.windowLabel, want, "label=\(label) focused=\(focused)")
        }
    }

    func testPiAgentNameValidation() throws {
        setenvTemp("XDG_CACHE_HOME", testTempDir())
        let dir = testCacheDir() + "/agents"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = dir + "/pi-42.json"
        let now = Date()
        struct PiCase {
            let name: String
            let change: (inout [String: Any]) -> Void
            let valid: Bool
        }
        let cases: [PiCase] = [
            PiCase(name: "valid", change: { _ in }, valid: true),
            PiCase(name: "pid", change: { $0["pid"] = 43 }, valid: false),
            PiCase(name: "block", change: { $0["block_id"] = "other" }, valid: false),
            PiCase(name: "session", change: { $0["session_id"] = "other" }, valid: false),
            PiCase(name: "app", change: { $0["app"] = "codex" }, valid: false),
            PiCase(name: "stale", change: { $0["updated_at"] = Rex.formatRFC3339(now.addingTimeInterval(-16)) }, valid: false),
            PiCase(name: "future", change: { $0["updated_at"] = Rex.formatRFC3339(now.addingTimeInterval(60)) }, valid: false),
            PiCase(name: "missing timestamp", change: { $0.removeValue(forKey: "updated_at") }, valid: false),
            PiCase(name: "invalid timestamp", change: { $0["updated_at"] = "bad" }, valid: false),
            PiCase(name: "empty name", change: { $0["name"] = " " }, valid: false),
        ]
        for c in cases {
            var m: [String: Any] = ["pid": 42, "app": "pi", "name": " Named task ", "block_id": "b", "session_id": "s", "updated_at": Rex.formatRFC3339(now)]
            c.change(&m)
            let data = try JSONSerialization.data(withJSONObject: m)
            try Data(data).write(to: URL(fileURLWithPath: file))
            let got = Rex.piAgentName(42, "b", "s", now)
            XCTAssertEqual((got == "Named task"), c.valid, "\(c.name): name=\(got)")
            if !c.valid {
                XCTAssertEqual(got, "", "\(c.name)")
            }
        }
        try Data("{".utf8).write(to: URL(fileURLWithPath: file))
        XCTAssertEqual(Rex.piAgentName(42, "b", "s", now), "", "malformed")
        // Metadata changes only the matching Pi record's name, not Codex or a
        // different process. It does not create any entries itself.
        let m = "{\"pid\":42,\"app\":\"pi\",\"name\":\"Named task\",\"block_id\":\"b\",\"session_id\":\"s\",\"updated_at\":\"\(Rex.formatRFC3339(now))\"}"
        try Data(m.utf8).write(to: URL(fileURLWithPath: file))
        let snapshot = "{\"sessions\":[{\"session_id\":\"s\",\"windows\":[{\"window_id\":\"w\",\"blocks\":[{\"block_id\":\"b\",\"title\":\"terminal\",\"records\":[{\"app\":\"pi\",\"owner\":{\"pid\":42},\"state\":\"idle\"},{\"id\":\"other\",\"app\":\"pi\",\"owner\":{\"pid\":43},\"state\":\"idle\"},{\"id\":\"codex\",\"app\":\"codex\",\"owner\":{\"pid\":42},\"state\":\"idle\"}]}]}]}]}"
        let entries = try Rex.decodeAgentEntries(Data(snapshot.utf8), "s", now)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].label, "Named task")
        XCTAssertEqual(entries[1].label, "terminal")
        XCTAssertEqual(entries[2].label, "terminal")
        let remote = try Rex.decodeAgentEntriesWithNames(Data(snapshot.utf8), "", now, false)
        XCTAssertEqual(remote.count, 3)
        XCTAssertEqual(remote[0].label, "terminal", "remote PID used local metadata: \(remote)")
    }

    func testNativeAgentTitleOverridesPiNameBridge() throws {
        let now = Date()
        setenvTemp("XDG_CACHE_HOME", testTempDir())
        let dir = testCacheDir() + "/agents"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let metadata = "{\"pid\":42,\"app\":\"pi\",\"name\":\"Bridge name\",\"block_id\":\"b\",\"session_id\":\"s\",\"updated_at\":\"\(Rex.formatRFC3339(now))\"}"
        try Data(metadata.utf8).write(to: URL(fileURLWithPath: dir + "/pi-42.json"))
        let snapshot = "{\"sessions\":[{\"session_id\":\"s\",\"windows\":[{\"window_id\":\"w\",\"blocks\":[{\"block_id\":\"b\",\"records\":[{\"app\":\"pi\",\"title\":\"Native title\",\"owner\":{\"pid\":42},\"state\":\"idle\"}]}]}]}]}"
        let entries = try Rex.decodeAgentEntries(Data(snapshot.utf8), "s", now)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].label, "Native title", "native title was replaced: \(entries)")
    }

    func testNativeAgentLifetimeIsAuthoritative() throws {
        // Process and status snapshots can race. Keep the records returned by Rex;
        // only a native removal or an absent record ends their lifetime.
        for process in ["null", "{\"last_exit\":{\"exit_code\":0}}", "{\"foreground\":{\"pid\":7,\"name\":\"zsh\"}}"] {
            let snapshot = "{\"sessions\":[{\"session_id\":\"s\",\"windows\":[{\"window_id\":\"w\",\"blocks\":[{\"block_id\":\"b\",\"process\":\(process),\"records\":[{\"app\":\"pi\",\"owner\":{\"pid\":42,\"name\":\"node\"},\"state\":\"working\"}]}]}]}]}"
            let entries = try Rex.decodeAgentEntries(Data(snapshot.utf8), "s", Date())
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries.first?.state, "working", "native status was suppressed: \(entries)")
        }
        let entries = try Rex.decodeAgentEntries(Data("{\"sessions\":[]}".utf8), "s", Date())
        XCTAssertEqual(entries.count, 0, "removed native record survived: \(entries)")
    }

    func testJumpAgentExactPane() throws {
        let dir = testTempDir()
        let log = dir + "/calls"
        prependPATH(dir)
        setenvTemp("REX_TEST_LOG", log)
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$REX_TEST_LOG"
        case "$*" in
         'api call -s s session.list_blocks '*) echo '{"blocks":[{"block_id":"b","window_id":"w","creator_name":"com.superlogical.terminal"},{"block_id":"other","window_id":"w","creator_name":"com.superlogical.onboarding"}]}' ;;
        esac
        """
        writeExecutable(dir + "/rex", contents: script)
        for client in ["client-a", ""] {
            try Rex.jumpAgent(AgentEntry(sessionID: "s", windowID: "w", blockID: "b"), client)
        }
        let badEntries = [
            AgentEntry(),
            AgentEntry(sessionID: "s", windowID: "wrong", blockID: "b"),
            AgentEntry(sessionID: "s", windowID: "w", blockID: "gone"),
            AgentEntry(sessionID: "s", windowID: "w", blockID: "other"),
        ]
        for e in badEntries {
            XCTAssertThrowsError(try Rex.jumpAgent(e, "client-a"), "accepted \(e)")
        }
        let calls = readTextFile(log)
        XCTAssertEqual(countOccurrences(calls, "session.focus_block"), 2)
        XCTAssertEqual(countOccurrences(calls, "-C client-a do session.select session_id=s window_id=w"), 1)
        XCTAssertTrue(calls.contains("session.focus_block {\"block_id\":\"b\",\"session_id\":\"s\"}"), "calls=\(calls)")
    }

    func testAgentApps() {
        let cases: [(String, String)] = [
            (" Pi ", "pi"), ("pi-coding-agent", "pi"), ("@earendil-works/pi-coding-agent", "pi"),
            ("Codex", "codex"), ("codex-cli", "codex"), ("@openai/codex", "codex"),
            ("Claude", "claude"), ("claude-code", "claude"), ("@anthropic-ai/claude-code", "claude"),
            ("cargo", ""), ("", ""),
        ]
        for (app, want) in cases {
            XCTAssertEqual(Rex.normalizeAgentApp(app), want, "app=\(app)")
        }
    }

    func testAgentEntriesUsesOneBatch() throws {
        let dir = testTempDir()
        prependPATH(dir)
        writeExecutable(dir + "/rex", contents: "#!/bin/sh\n[ \"$1\" = do ] && [ \"$2\" = -e ] && [ \"$4\" = --json ] || exit 1\nprintf '%s' '{}'\n")
        let entries = try Rex.agentEntries("s")
        XCTAssertEqual(entries.count, 0, "entries=\(entries)")
    }
}
