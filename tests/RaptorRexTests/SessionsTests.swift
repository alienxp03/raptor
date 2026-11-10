import XCTest
@testable import RaptorRex

final class SessionsTests: XCTestCase {
    @discardableResult
    func fakeSessionRex() -> String {
        let dir = testTempDir()
        let log = dir + "/calls"
        prependPATH(dir)
        setenvTemp("REX_TEST_LOG", log)
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$REX_TEST_LOG"
        case "$*" in
          'ls --json')
            if [ "$REX_TEST_FAIL" = list ]; then exit 1; fi
            if [ "$REX_TEST_FAIL" = json ]; then echo '{'; exit 0; fi
            if [ "$REX_TEST_FAIL" = empty ]; then echo '{"sessions":[]}'; exit 0; fi
            echo '{"sessions":[{"session_id":"a","label":"Project"},{"session_id":"dead","label":"Dead"},{"session_id":"b","label":"Tools"}]}' ;;
          'api call -s a session.view '*)
            echo '{"active_window_id":"a2","windows":[{"window_id":"a1","label":"shell"},{"window_id":"a2","label":"build"}]}' ;;
          'api call -s dead session.view '*) exit 1 ;;
          'api call -s b session.view '*) echo '{"windows":[]}' ;;
          *) if [ "$REX_TEST_FAIL" = jump ]; then exit 1; fi ;;
        esac
        """
        writeExecutable(dir + "/rex", contents: script)
        return log
    }

    func testSessionEntriesGroupedShape() throws {
        fakeSessionRex()
        let got = try Rex.sessionEntries("a")
        let want = [
            SessionEntry(kind: "session", id: "a", path: "a", sessionID: "a", label: "Project", sessionLabel: "Project", active: true),
            SessionEntry(kind: "window", id: "a1", path: "a1", sessionID: "a", label: "shell", sessionLabel: "Project"),
            SessionEntry(kind: "window", id: "a2", path: "a2", sessionID: "a", label: "build", sessionLabel: "Project", active: true),
            SessionEntry(kind: "session", id: "dead", path: "dead", sessionID: "dead", label: "Dead", sessionLabel: "Dead"),
            SessionEntry(kind: "session", id: "b", path: "b", sessionID: "b", label: "Tools", sessionLabel: "Tools"),
        ]
        XCTAssertEqual(got, want)
    }

    func testSessionEntriesTerminalTitleFallback() throws {
        let windowID = "window:01a1b042-8b2e-793f-92c1-bedeb0439b58"
        let blockID = "block:01a1b042-8b07-7a4c-9490-09c43f411fde"
        let generated = "Window b0439b58"
        struct TitleCase {
            let name: String
            let label: String
            let focused: String
            let response: String
            let want: String
            let fail: Bool
            let call: Bool
        }
        let cases: [TitleCase] = [
            TitleCase(name: "generated", label: generated, focused: blockID, response: "{\"title\":\"castty\",\"owner\":\"process\"}", want: "castty", fail: false, call: true),
            TitleCase(name: "blank", label: "", focused: blockID, response: "{\"title\":\"castty\"}", want: "castty", fail: false, call: true),
            TitleCase(name: "custom", label: "Build", focused: blockID, response: "", want: "Build", fail: false, call: false),
            TitleCase(name: "different suffix", label: "Window 12345678", focused: blockID, response: "", want: "Window 12345678", fail: false, call: false),
            TitleCase(name: "no focus", label: generated, focused: "", response: "", want: generated, fail: false, call: false),
            TitleCase(name: "nonterminal or error", label: generated, focused: blockID, response: "", want: generated, fail: true, call: true),
            TitleCase(name: "empty title", label: generated, focused: blockID, response: "{\"title\":\"\"}", want: generated, fail: false, call: true),
            TitleCase(name: "whitespace title", label: generated, focused: blockID, response: "{\"title\":\"  \"}", want: generated, fail: false, call: true),
            TitleCase(name: "missing title", label: generated, focused: blockID, response: "{}", want: generated, fail: false, call: true),
            TitleCase(name: "invalid response", label: generated, focused: blockID, response: "{", want: generated, fail: false, call: true),
            TitleCase(name: "blank fallback", label: "", focused: blockID, response: "", want: "", fail: true, call: true),
        ]
        for c in cases {
            let dir = testTempDir()
            let log = dir + "/calls"
            prependPATH(dir)
            setenvTemp("REX_TEST_LOG", log)
            let view: [String: Any] = [
                "active_window_id": windowID,
                "windows": [["window_id": windowID, "label": c.label, "focused_block_id": c.focused]],
            ]
            let viewData = try JSONSerialization.data(withJSONObject: view)
            setenvTemp("REX_TEST_VIEW", String(data: viewData, encoding: .utf8)!)
            setenvTemp("REX_TEST_TITLE", c.response)
            setenvTemp("REX_TEST_TITLE_FAIL", c.fail ? "true" : "false")
            let script = """
            #!/bin/sh
            printf '%s\\n' "$*" >> "$REX_TEST_LOG"
            case "$*" in
              'ls --json') echo '{"sessions":[{"session_id":"s","label":"Project"}]}' ;;
              'api call -s s session.view '* ) printf '%s' "$REX_TEST_VIEW" ;;
              'block call -s s -b \(blockID) title')
                if [ "$REX_TEST_TITLE_FAIL" = true ]; then exit 1; fi
                printf '%s' "$REX_TEST_TITLE" ;;
              *) exit 1 ;;
            esac
            """
            writeExecutable(dir + "/rex", contents: script)
            let entries = try Rex.sessionEntries("s")
            XCTAssertEqual(entries.count, 2, "\(c.name)")
            let want = SessionEntry(kind: "window", id: windowID, path: windowID, sessionID: "s", label: c.want, sessionLabel: "Project", active: true)
            XCTAssertEqual(entries[1], want, "\(c.name)")
            let calls = readTextFile(log)
            var wantCalls = "ls --json\napi call -s s session.view {\"session_id\":\"s\"}\n"
            if c.call {
                wantCalls += "block call -s s -b \(blockID) title\n"
            }
            XCTAssertEqual(calls, wantCalls, "\(c.name)")
        }
    }

    func testSessionEntriesListErrors() throws {
        fakeSessionRex()
        for failure in ["list", "json"] {
            setenvTemp("REX_TEST_FAIL", failure)
            XCTAssertThrowsError(try Rex.sessionEntries("a"), failure)
        }
    }

    func testSessionEntriesEmpty() throws {
        fakeSessionRex()
        setenvTemp("REX_TEST_FAIL", "empty")
        let entries = try Rex.sessionEntries("missing")
        XCTAssertEqual(entries.count, 0)
    }

    func testSessionEntriesBoundedParallelOrderAndFailures() throws {
        let dir = testTempDir()
        prependPATH(dir)
        setenvTemp("REX_TEST_STATE", dir)
        var sessions: [[String: String]] = []
        var want: [SessionEntry] = []
        for i in 0..<(Rex.sessionWindowWorkers * 3) {
            let id = "s\(i)"
            sessions.append(["session_id": id, "label": id])
            want.append(SessionEntry(
                kind: "session", id: id, path: id, sessionID: id,
                label: id, sessionLabel: id, active: i == 1))
            // Both a dead session and an invalid response must keep their rows.
            if i == 2 || i == 3 {
                continue
            }
            for suffix in ["b", "a"] {
                let windowID = id + suffix
                want.append(SessionEntry(
                    kind: "window", id: windowID, path: windowID, sessionID: id,
                    label: "title-" + windowID, sessionLabel: id, active: suffix == "a"))
            }
        }
        let payload = try JSONSerialization.data(withJSONObject: ["sessions": sessions])
        try Data(payload).write(to: URL(fileURLWithPath: dir + "/sessions"))
        // Atomic directories count active calls. No call can finish before the
        // test releases the gate, so reaching the worker limit proves overlap.
        let script = """
        #!/bin/sh
        state="$REX_TEST_STATE"
        if [ "$1" = ls ]; then cat "$state/sessions"; exit; fi
        id="$4"
        slot=1
        while ! mkdir "$state/slot-$slot" 2>/dev/null; do
          slot=$((slot + 1))
          if [ "$slot" -gt \(Rex.sessionWindowWorkers) ]; then
            touch "$state/overflow"
            exit 1
          fi
        done
        trap 'rmdir "$state/slot-$slot"' EXIT
        touch "$state/started-$id"
        if [ "$1" = block ]; then
          touch "$state/title-$6"
          printf '{"title":"title-%s"}' "$6"
          exit
        fi
        while [ ! -f "$state/release" ]; do sleep 0.01; done
        # Force a later sidebar session to finish before the first session.
        if [ "$id" = s0 ]; then
          while [ ! -f "$state/finished-s1" ]; do sleep 0.01; done
        fi
        touch "$state/finished-$id"
        case "$id" in
          s2) exit 1 ;;
          s3) echo '{'; exit 0 ;;
        esac
        printf '{"active_window_id":"%sa","windows":[{"window_id":"%sb","label":"","focused_block_id":"%sb"},{"window_id":"%sa","label":"","focused_block_id":"%sa"}]}' "$id" "$id" "$id" "$id" "$id"
        """
        writeExecutable(dir + "/rex", contents: script)
        addTeardownBlock {
            if !FileManager.default.fileExists(atPath: dir + "/release") {
                FileManager.default.createFile(atPath: dir + "/release", contents: nil)
            }
        }
        let release: () -> Void = {
            FileManager.default.createFile(atPath: dir + "/release", contents: nil)
        }
        let resultBox = ValueBox<Result<[SessionEntry], Error>>()
        DispatchQueue.global().async {
            do {
                let entries = try Rex.sessionEntries("s1")
                resultBox.set(.success(entries))
            } catch {
                resultBox.set(.failure(error))
            }
        }
        let deadline = Date().addingTimeInterval(5)
        var startedCount = 0
        while true {
            let started = (try? FileManager.default.contentsOfDirectory(atPath: dir))?.filter { $0.hasPrefix("started-") } ?? []
            startedCount = started.count
            if startedCount == Rex.sessionWindowWorkers {
                break
            }
            if Date() > deadline {
                XCTFail("only \(startedCount) window calls started before release; want \(Rex.sessionWindowWorkers)")
                release()
                return
            }
            usleep(10_000)
        }
        release()
        let result = resultBox.get()
        switch result {
        case .success(let entries):
            XCTAssertEqual(entries, want)
        case .failure(let error):
            XCTFail("error = \(error); want \(want)")
        }
        let titles = (try? FileManager.default.contentsOfDirectory(atPath: dir))?.filter { $0.hasPrefix("title-") } ?? []
        XCTAssertEqual(titles.count, (Rex.sessionWindowWorkers * 3 - 2) * 2, "title calls")
        let overflow = FileManager.default.fileExists(atPath: dir + "/overflow")
        XCTAssertFalse(overflow, "window concurrency exceeded \(Rex.sessionWindowWorkers)")
    }

    func testJumpSessionAndTab() throws {
        struct JumpCase {
            let name: String
            let entry: SessionEntry
            let client: String
            let want: String
        }
        let cases: [JumpCase] = [
            JumpCase(name: "client session", entry: SessionEntry(kind: "session", id: "a", sessionID: "a"), client: "client", want: "-C client do session.select session_id=a\n"),
            JumpCase(name: "client tab", entry: SessionEntry(kind: "window", id: "a1", sessionID: "a"), client: "client", want: "-C client do session.select session_id=a window_id=a1\n"),
            JumpCase(name: "fallback session uses active tab", entry: SessionEntry(kind: "session", id: "a", sessionID: "a"), client: "", want: "api call -s a session.view {\"session_id\":\"a\"}\napi call session.focus_window {\"session_id\":\"a\",\"window_id\":\"a2\"}\n"),
            JumpCase(name: "fallback tab", entry: SessionEntry(kind: "window", id: "a1", sessionID: "a"), client: "", want: "api call session.focus_window {\"session_id\":\"a\",\"window_id\":\"a1\"}\n"),
        ]
        for c in cases {
            let log = fakeSessionRex()
            try Rex.jump(c.entry, c.client)
            let got = readTextFile(log)
            XCTAssertEqual(got, c.want, "\(c.name)")
        }
    }

    func testJumpFailure() throws {
        fakeSessionRex()
        setenvTemp("REX_TEST_FAIL", "jump")
        XCTAssertThrowsError(try Rex.jump(SessionEntry(kind: "session", sessionID: "a"), "client"))
        XCTAssertThrowsError(try Rex.jump(SessionEntry(kind: "session", id: "", sessionID: "b", sessionLabel: "Tools"), "")) { error in
            XCTAssertTrue(String(describing: error).contains("no windows"), "expected empty-session error, got \(error)")
        }
    }
}
