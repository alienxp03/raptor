import XCTest
import RaptorRex
@testable import RaptorPullrequest

/// Ported from internal/pullrequest/setup_test.go.
final class SetupTests: XCTestCase {
    func testSetupEmptyPhasesSilentAndDurable() {
        for existing in [false, true] {
            subtest(existing ? "existing" : "new") {
                let env = TestEnv()
                defer { env.restore() }
                let path = try releasedSetupFixture(env, existing: existing)
                env.set("PR_HOOK_PHASES", "")
                // Empty phases do not even consult approval state.
                env.set("PR_DENY", "1")
                for _ in 0..<2 {
                    let (out, errText, err) = try captureSetup(path, false)
                    XCTAssertNil(err, "stdout=\(out) stderr=\(errText) err=\(String(describing: err))")
                    XCTAssertEqual(out, "")
                    XCTAssertEqual(errText, "")
                }
                let s = try RaptorPullrequest.load(path)
                let wantStage = existing ? 1 : 3
                XCTAssertTrue(s.complete, "\(s)")
                XCTAssertEqual(s.stage, wantStage)
                XCTAssertEqual(s.failed ?? "", "")
                let calls = try setupCalls()
                assertNoHookExecution(calls)
                for phase in ["pre-start", "post-start", "post-switch"] {
                    var want = 1
                    if existing && phase != "post-switch" {
                        want = 0
                    }
                    XCTAssertEqual(calls.components(separatedBy: "wt hook show \(phase) --format=json").count - 1, want, calls)
                }
            }
        }
    }

    func testSetupConfiguredHooksVisibleOnce() throws {
        let env = TestEnv()
        defer { env.restore() }
        let path = try releasedSetupFixture(env, existing: false)
        env.set("PR_VISIBLE", "1")
        let (out, errText, err) = try captureSetup(path, false)
        XCTAssertNil(err, "\(String(describing: err))")
        XCTAssertEqual(out, "pre-start stdout\npost-start stdout\npost-switch stdout\n", "stdout=\(out)")
        XCTAssertEqual(errText, "pre-start stderr\npost-start stderr\npost-switch stderr\n", "stderr=\(errText)")
        let (out2, errText2, err2) = try captureSetup(path, false)
        XCTAssertNil(err2, "\(String(describing: err2))")
        XCTAssertEqual(out2, "")
        XCTAssertEqual(errText2, "")
        let calls = try setupCalls()
        for phase in ["pre-start", "post-start", "post-switch"] {
            XCTAssertEqual(calls.components(separatedBy: "wt hook \(phase) --").count - 1, 1, calls)
        }
        XCTAssertEqual(calls.components(separatedBy: "wt config approvals list --format=json").count - 1, 3, calls)
    }

    func testSetupInvalidHookInspectionDoesNotMutate() {
        for raw in ["{", "null", "{}", "false", "42", "\"hooks\""] {
            subtest(raw) {
                let env = TestEnv()
                defer { env.restore() }
                let path = try releasedSetupFixture(env, existing: false)
                env.set("PR_HOOK_JSON", raw)
                let before = try RaptorPullrequest.load(path)
                try put(path + "/keep", "user data")
                for retry in [false, true] {
                    let (out, errText, err) = try captureSetup(path, retry)
                    XCTAssertNotNil(err, "stdout=\(out) stderr=\(errText)")
                    XCTAssertTrue(String(describing: err!).contains("valid JSON array"),
                                  "stdout=\(out) stderr=\(errText) err=\(String(describing: err))")
                    XCTAssertEqual(out, "")
                    XCTAssertTrue(errText.contains("Worktree setup failed:"), errText)
                    XCTAssertTrue(errText.contains("--retry"), errText)
                    let after = try RaptorPullrequest.load(path)
                    XCTAssertEqual(after, before, "state changed: before=\(before) after=\(after)")
                }
                assertNoHookExecution(try setupCalls())
                let data = try String(contentsOfFile: path + "/keep", encoding: .utf8)
                XCTAssertEqual(data, "user data", "partial resources changed")
                env.set("PR_HOOK_JSON", "[]")
                let (_, _, finalErr) = try captureSetup(path, true)
                XCTAssertNil(finalErr, "\(String(describing: finalErr))")
            }
        }
    }

    func testSetupEmptyPhasesAdvanceBeforeFailure() throws {
        let env = TestEnv()
        defer { env.restore() }
        let path = try releasedSetupFixture(env, existing: false)
        env.set("PR_HOOK_PHASES", "post-switch")
        env.set("PR_HOOK_JSON", "")
        // Reuse the declined-approval fixture for the only configured phase.
        let wt = firstPathDir(env) + "/wt"
        let data = try String(contentsOfFile: wt, encoding: .utf8)
        try put(wt, data.replacingOccurrences(of: "\"phase\":\"pre-start\",\"approved\":false",
                                              with: "\"phase\":\"post-switch\",\"approved\":false"))
        env.set("PR_DENY", "1")
        let (_, errText, err) = try captureSetup(path, false)
        XCTAssertNotNil(err, "\(String(describing: err))")
        XCTAssertTrue(errText.contains("approval declined"), "\(String(describing: err)): \(errText)")
        let s = try RaptorPullrequest.load(path)
        XCTAssertEqual(s.stage, 2)
        XCTAssertTrue((s.failed ?? "").hasPrefix("post-switch:"), "\(s)")
        var calls = try setupCalls()
        XCTAssertFalse(calls.contains("wt hook pre-start --"), calls)
        XCTAssertFalse(calls.contains("wt hook post-start --"), calls)
        XCTAssertEqual(calls.components(separatedBy: "wt config approvals").count - 1, 1, calls)
        env.set("PR_DENY", "")
        let (_, _, retryErr) = try captureSetup(path, true)
        XCTAssertNil(retryErr, "\(String(describing: retryErr))")
        calls = try setupCalls()
        XCTAssertEqual(calls.components(separatedBy: "wt hook show pre-start --").count - 1, 1, "reinspected completed empty phases: \(calls)")
        XCTAssertEqual(calls.components(separatedBy: "wt hook show post-start --").count - 1, 1, "reinspected completed empty phases: \(calls)")
    }

    func testSetupEmptyInspectionCannotReplayInterruptedBackground() {
        for phase in ["post-start", "post-switch", "existing post-switch"] {
            subtest(phase) {
                let env = TestEnv()
                defer { env.restore() }
                let path = try releasedSetupFixture(env, existing: phase.hasPrefix("existing"))
                env.set("PR_HOOK_PHASES", "")
                var s = try RaptorPullrequest.load(path)
                s.stage = 1
                s.failed = "post-start interrupted"
                if phase == "post-switch" {
                    s.stage = 2
                    s.failed = "post-switch interrupted"
                }
                if !s.new {
                    s.stage = 0
                    s.failed = "post-switch interrupted"
                }
                try RaptorPullrequest.save(path, s)
                let (_, errText, err) = try captureSetup(path, true)
                XCTAssertNotNil(err, "\(String(describing: err))")
                XCTAssertTrue(errText.contains("not replayed"), "\(String(describing: err)): \(errText)")
                let after = try RaptorPullrequest.load(path)
                XCTAssertEqual(after, s, "\(after): \(String(describing: err))")
                let calls = try setupCalls()
                assertNoHookExecution(calls)
                XCTAssertFalse(calls.contains("wt hook show"), "inspection bypassed interrupted launch guard: \(calls)")
            }
        }
    }
}
