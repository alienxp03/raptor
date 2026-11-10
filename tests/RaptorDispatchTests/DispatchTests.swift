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
}
