import XCTest
import RaptorConfig
import RaptorRex
import RaptorWorktree
@testable import RaptorDispatch

/// Ported from pane_focus_test.go.
final class PaneFocusTests: XCTestCase {
    func testPaneSelectsRequestingClientWindow() throws {
        for target in ["pane_right", "pane_below"] {
            for failure in ["", "describe", "missing-window", "select", "no-client"] {
                subtest(target + "/" + failure) {
                    let env = TestEnv()
                    defer { env.restore() }
                    let dir = try makeTempDir()
                    let logPath = dir + "/calls"
                    env.set("PATH", dir + ":" + (env.get("PATH") ?? ""))
                    env.set("REX_TEST_LOG", logPath)
                    env.set("REX_TEST_FAIL_AT", failure)
                    env.set("XDG_STATE_HOME", try makeTempDir())
                    let script = #"""
                    #!/bin/sh
                    printf '%s\n' "$*" >> "$REX_TEST_LOG"
                    case "$1" in
                      split) echo '{"block_ids":["new-pane","origin-pane"]}' ;;
                      focus) ;;
                      api)
                        if [ "$REX_TEST_FAIL_AT" = describe ]; then echo 'description failed' >&2; exit 1; fi
                        if [ "$REX_TEST_FAIL_AT" = missing-window ]; then echo '{"block":{}}'; else echo '{"block":{"window_id":"actual-window"}}'; fi ;;
                      -C) if [ "$REX_TEST_FAIL_AT" = select ]; then echo 'client selection failed' >&2; exit 1; fi ;;
                      *) echo 'unexpected command' >&2; exit 1 ;;
                    esac
                    """#
                    try writeExecutable(dir + "/rex", script)
                    var ctx = Ctx(session: "origin-session", block: "origin-pane", client: "requested-client")
                    if failure == "no-client" {
                        ctx.client = ""
                    }
                    var caught: Error?
                    do {
                        _ = try RaptorDispatch.dispatch(target: target, dir: "/demo/project", ctx: ctx,
                                                        cfg: RaptorConfig.default())
                    } catch {
                        caught = error
                    }
                    let wantFailure = !failure.isEmpty && failure != "no-client"
                    XCTAssertEqual(caught != nil, wantFailure,
                                   "error = \(String(describing: caught)), want failure \(wantFailure)")
                    let log = try readText(logPath)
                    let calls = log.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
                    var want = [
                        "split -s origin-session -b origin-pane --split=" + RaptorDispatch.splitDirection(target) + " -c /demo/project --json",
                        "focus -s origin-session new-pane",
                    ]
                    if !ctx.client.isEmpty {
                        want.append("api call -s origin-session session.describe_block {\"block_id\":\"new-pane\"}")
                        if failure != "describe" && failure != "missing-window" {
                            want.append("-C requested-client do session.select session_id=origin-session window_id=actual-window")
                        }
                    }
                    XCTAssertEqual(calls.joined(separator: "\n"), want.joined(separator: "\n"),
                                   "commands = \(calls), want \(want)")
                }
            }
        }
    }
}
