import XCTest
import RaptorExecx
import RaptorConfig
import RaptorRex
@testable import RaptorWorktree
@testable import RaptorDispatch

/// Ported from dispatch_test.go.
final class DispatchTests: XCTestCase {
    func testShellCDTreatsPathAsData() throws {
        let env = TestEnv()
        defer { env.restore() }
        let root = try makeTempDir()
        let path = root + "/demo's $(touch SENTINEL); project"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        let command = try RaptorDispatch.shellCD("sh", path)
        let r = try Execx.run(dir: root, timeout: 10, name: "sh", args: ["-c", command + "pwd"])
        if r.code != 0 {
            XCTFail("cd failed: \(r.code): \(r.stdout)\(r.stderr)")
            return
        }
        let got = evalSymlinks(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        let want = evalSymlinks(path)
        XCTAssertEqual(got, want, "changed to \(String(describing: got)), want \(String(describing: want))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/SENTINEL"), "path executed as a shell command")
        for p in ["demo\ncommand", "demo\u{1b}command", "demo\u{03}command"] {
            XCTAssertThrowsError(try RaptorDispatch.shellCD("sh", p), "accepted terminal control input")
        }
        for shell in ["nu", "elvish"] {
            XCTAssertThrowsError(try RaptorDispatch.shellCD(shell, "demo's project"),
                                 "accepted an unescaped quote for " + shell)
        }
    }

    func testMissingClientDoesNotCreateSession() throws {
        let env = TestEnv()
        defer { env.restore() }
        // No Rex binary exists here: validation must fail before any Rex command.
        env.set("PATH", try makeTempDir())
        env.set("XDG_STATE_HOME", try makeTempDir())
        XCTAssertThrowsError(try RaptorDispatch.dispatch(target: "session", dir: "/demo/project",
                                                         ctx: Ctx(), cfg: RaptorConfig.default())) { error in
            XCTAssertEqual(String(describing: error), "no client context", "unexpected error: \(error)")
        }
    }

    func testDispatchNavigation() throws {
        for target in ["tab", "pane_right", "pane_below", "session"] {
            for fail in [false, true] {
                let name = fail ? target + "-failure" : target
                subtest(name) {
                    let env = TestEnv()
                    defer { env.restore() }
                    let dir = try makeTempDir()
                    env.set("XDG_CACHE_HOME", try makeTempDir())
                    env.set("XDG_STATE_HOME", try makeTempDir())
                    env.set("PATH", dir + ":" + (env.get("PATH") ?? ""))
                    env.set("REX_TEST_FAIL", fail ? "1" : "")
                    let script = #"""
                    #!/bin/sh
                    case "$*" in
                      'ls --json') echo '{"sessions":[{"session_id":"target-session","label":"project"}]}' ;;
                      'window new '*) echo '{"window_id":"new-window"}' ;;
                      'split '*) echo '{"block_ids":["new-pane","origin-pane"]}' ;;
                      'api call '*session.describe_block*) echo '{"block":{"window_id":"new-window"}}' ;;
                      'focus '*)
                        if [ "$REX_TEST_FAIL" = 1 ]; then exit 1; fi
                        case "$*" in *' -b '*) echo 'invalid focus flag' >&2; exit 1;; esac ;;
                      *session.select*) if [ "$REX_TEST_FAIL" = 1 ]; then exit 1; fi ;;
                    esac
                    """#
                    try writeExecutable(dir + "/rex", script)
                    let ctx = Ctx(session: "origin-session", block: "origin-pane", client: "client")
                    var caught: Error?
                    do {
                        _ = try RaptorDispatch.dispatch(target: target, dir: "/tmp/project", ctx: ctx,
                                                        cfg: RaptorConfig.default())
                    } catch {
                        caught = error
                    }
                    XCTAssertEqual(caught != nil, fail,
                                   "error = \(String(describing: caught)), want failure \(fail)")
                }
            }
        }
    }

    func testTeachZoxideRecordsOnlySuccessfulOpens() throws {
        for target in ["session", "tab"] {
            for fail in [false, true] {
                subtest(target + "-zoxide-fail-\(fail)") {
                    let env = TestEnv()
                    defer { env.restore() }
                    let dir = try makeTempDir()
                    env.set("XDG_CACHE_HOME", try makeTempDir())
                    env.set("XDG_STATE_HOME", try makeTempDir())
                    env.set("PATH", dir + ":" + (env.get("PATH") ?? ""))
                    env.set("REX_TEST_FAIL", fail ? "1" : "")
                    let script = #"""
                    #!/bin/sh
                    case "$*" in
                      'ls --json') echo '{"sessions":[]}' ;;
                      'new '*) echo '{"session_id":"fresh-session"}' ;;
                      'window new '*) echo '{"window_id":"new-window"}' ;;
                      'api call '*session.describe_block*) echo '{"block":{"window_id":"new-window"}}' ;;
                      'focus '*) if [ "$REX_TEST_FAIL" = 1 ]; then exit 1; fi ;;
                      *session.select*) if [ "$REX_TEST_FAIL" = 1 ]; then exit 1; fi ;;
                    esac
                    """#
                    try writeExecutable(dir + "/rex", script)

                    let recorded = LockedRecord()
                    let original = RaptorDispatch.teachZoxide
                    RaptorDispatch.teachZoxide = { recorded.add($0) }
                    defer { RaptorDispatch.teachZoxide = original }

                    let ctx = Ctx(session: "origin-session", block: "origin-pane", client: "client")
                    var caught: Error?
                    do {
                        _ = try RaptorDispatch.dispatch(target: target, dir: "/tmp/zoxide-project", ctx: ctx,
                                                        cfg: RaptorConfig.default())
                    } catch {
                        caught = error
                    }
                    XCTAssertEqual(caught != nil, fail)
                    if fail {
                        XCTAssertEqual(recorded.paths, [], "failed opens must not teach zoxide")
                    } else {
                        XCTAssertEqual(recorded.paths, ["/tmp/zoxide-project"],
                                       "successful opens teach zoxide the directory")
                    }
                }
            }
        }
    }
}

/// Thread-safe recorder for the injectable zoxide hook. Dispatch runs on the
/// test thread, but the hook may fire from any dispatch path.
final class LockedRecord {
    private let lock = NSLock()
    private var all: [String] = []
    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return all
    }
    func add(_ path: String) {
        lock.lock()
        all.append(path)
        lock.unlock()
    }
}

extension DispatchTests {
    /// Agent launch rides the open command for tab and pane targets; the
    /// command list must reach rex as data arguments after `--`.
    func testDispatchLaunchesAgentInNewTabAndPane() throws {
        for (target, rexCallPrefix) in [("tab", "window new"), ("pane_right", "split")] {
            subtest(target + "-launch") {
                let env = TestEnv()
                defer { env.restore() }
                let dir = try makeTempDir()
                let log = dir + "/rex-calls"
                env.set("XDG_CACHE_HOME", try makeTempDir())
                env.set("XDG_STATE_HOME", try makeTempDir())
                env.set("PATH", dir + ":" + (env.get("PATH") ?? ""))
                env.set("REX_CALLS", log)
                let script = #"""
                #!/bin/sh
                printf '%s\n' "$*" >> "$REX_CALLS"
                case "$*" in
                  'ls --json') echo '{"sessions":[]}' ;;
                  'window new '*) echo '{"window_id":"new-window"}' ;;
                  'split '*) echo '{"block_ids":["new-pane"]}' ;;
                  'api call '*session.describe_block*) echo '{"block":{"window_id":"new-window"}}' ;;
                  *session.select*) ;;
                esac
                """#
                try writeExecutable(dir + "/rex", script)
                let ctx = Ctx(session: "origin-session", block: "origin-pane", client: "client")
                _ = try RaptorDispatch.dispatch(target: target, dir: "/tmp/project", ctx: ctx,
                                                cfg: RaptorConfig.default(),
                                                launch: ["pi", "--model", "glm-5.3", "--thinking", "max"])
                let calls = try String(contentsOfFile: log, encoding: .utf8)
                    .components(separatedBy: "\n").filter { !$0.isEmpty }
                let open = calls.first { $0.hasPrefix(rexCallPrefix) }
                XCTAssertTrue(open?.contains(" -- pi --model glm-5.3 --thinking max") == true, open ?? "no open call")
            }
        }
    }

    /// Session opens pass the agent command to `rex new`; "here" sends the
    /// quoted command as terminal input after the cd.
    func testDispatchLaunchesAgentInSessionAndHere() throws {
        for target in ["session", "here"] {
            subtest(target + "-launch") {
                let env = TestEnv()
                defer { env.restore() }
                let dir = try makeTempDir()
                let log = dir + "/rex-calls"
                let sends = dir + "/rex-sends"
                env.set("XDG_CACHE_HOME", try makeTempDir())
                env.set("XDG_STATE_HOME", try makeTempDir())
                env.set("PATH", dir + ":" + (env.get("PATH") ?? ""))
                env.set("REX_CALLS", log)
                env.set("REX_SENDS", sends)
                let script = #"""
                #!/bin/sh
                printf '%s\n' "$*" >> "$REX_CALLS"
                if [ "$1" = "send" ]; then
                  shift 3 # send -b BLOCK
                  printf '%s\n' "$*" >> "$REX_SENDS"
                  exit 0
                fi
                case "$*" in
                  'ls --json') echo '{"sessions":[]}' ;;
                  'new '*) echo '{"session_id":"fresh-session"}' ;;
                  *session.select*) ;;
                  'do -b origin-pane -e '*) echo 'zsh' ;;
                esac
                """#
                try writeExecutable(dir + "/rex", script)
                let ctx = Ctx(session: "origin-session", block: "origin-pane", client: "client")
                _ = try RaptorDispatch.dispatch(target: target, dir: "/tmp/project", ctx: ctx,
                                                cfg: RaptorConfig.default(),
                                                launch: ["pi", "--thinking", "max"])
                if target == "session" {
                    let calls = try String(contentsOfFile: log, encoding: .utf8)
                        .components(separatedBy: "\n").filter { !$0.isEmpty }
                    let new = calls.first { $0.hasPrefix("new --json") }
                    XCTAssertTrue(new?.contains(" -- pi --thinking max") == true, new ?? "no new call")
                } else {
                    let lines = try String(contentsOfFile: sends, encoding: .utf8)
                        .components(separatedBy: "\n").filter { !$0.isEmpty }
                    XCTAssertTrue(lines.contains("cd -- '/tmp/project'"), lines.joined(separator: "|"))
                    XCTAssertTrue(lines.last?.contains("'pi' '--thinking' 'max'") == true, lines.joined(separator: "|"))
                }
            }
        }
    }
}
