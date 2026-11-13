import XCTest
import RaptorConfig
import RaptorRex
import RaptorWorktree
@testable import RaptorTask

/// Ported from task_test.go.
final class TaskTests: XCTestCase {
    func testTaskCreatesSessionWithFreshEmptyPi() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, cfg, ctx, log) = try fixture(env)
        let (result, error) = startResult(ctx, cfg, repo, "")
        if let error { throw error }
        XCTAssertEqual(result.windowID, "new-window", "\(result)")
        XCTAssertEqual(result.blockID, "new-block", "\(result)")
        XCTAssertEqual(result.sessionID, "new-session", "\(result)")
        XCTAssertFalse(result.path.isEmpty, "\(result)")
        let branch = result.branch
        XCTAssertFalse(branch.rangeOfCharacter(from: CharacterSet(charactersIn: "/0123456789")) != nil, branch)
        XCTAssertEqual(branch.components(separatedBy: "-").count, 2, branch)
        let calls = try readText(log)
        let want = "new\n" + result.branch + "\n-c\n" + result.path + "\n--json\n--\n"
        XCTAssertTrue(calls.contains(want), "wrong session command:\n\(calls)")
        XCTAssertFalse(calls.contains("--keep-open\n"), "Pi terminal must close after Pi exits")
        let parts = calls.components(separatedBy: "--\n")
        XCTAssertGreaterThanOrEqual(parts.count, 2)
        let after = parts[1]
        let piCall = after.components(separatedBy: "CALL\n")[0]
        let trimmedPi = piCall.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(trimmedPi.components(separatedBy: "\n").count, 1,
                       "Pi must receive no prompt/resume arguments: \(piCall)")
        XCTAssertTrue(trimmedPi.hasSuffix("/pi"), "Pi must receive no prompt/resume arguments: \(piCall)")
        XCTAssertTrue(calls.contains("-C\niphone\ndo\nsession.select\nsession_id=new-session\nwindow_id=new-window"),
                      "requesting app not selected")
    }

    func testTaskMissingContextOrPiDoesNotCreate() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, cfg, ctx, _) = try fixture(env)
        for bad in [Ctx(session: ctx.session), Ctx(client: ctx.client)] {
            let (_, error) = startResult(bad, cfg, repo, "")
            XCTAssertNotNil(error, "missing context accepted")
        }
        env.set("PATH", try makeTempDir())
        let (_, error) = startResult(ctx, cfg, repo, "")
        guard let error else {
            XCTFail("pi-less start accepted")
            return
        }
        XCTAssertTrue(String(describing: error).contains("pi executable not found"), "\(error)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cfg.worktreeRoot),
                       "created directories before preflight")
    }

    func testTaskOpenFailurePreservesAndResumeReusesWorktree() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, cfg, ctx, _) = try fixture(env)
        env.set("TASK_FAIL", "open")
        let (first, error) = startResult(ctx, cfg, repo, "")
        guard let error else {
            XCTFail("\(first)")
            return
        }
        XCTAssertFalse(first.path.isEmpty, "\(first)")
        XCTAssertTrue(String(describing: error).contains("preserved"), "\(error)")
        XCTAssertEqual(WorktreeKit.list(repo: repo).count, 2, "created worktree lost")
        env.set("TASK_FAIL", "")
        let (resumed, resumeErr) = startResult(ctx, cfg, repo, first.path)
        if let resumeErr { throw resumeErr }
        XCTAssertEqual(canonical(resumed.path), canonical(first.path), "\(resumed) \(first)")
        XCTAssertEqual(resumed.branch, first.branch)
        XCTAssertEqual(WorktreeKit.list(repo: repo).count, 2, "retry created a second worktree")
        let (_, unregistered) = startResult(ctx, cfg, repo, try makeTempDir())
        XCTAssertNotNil(unregistered, "unregistered retry path accepted")
    }

    func testTaskFocusFailureIdentifiesExistingSession() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, cfg, ctx, _) = try fixture(env)
        env.set("TASK_FAIL", "focus")
        let (result, error) = startResult(ctx, cfg, repo, "")
        guard let error else {
            XCTFail("\(result)")
            return
        }
        XCTAssertEqual(result.windowID, "new-window", "\(result)")
        XCTAssertTrue(String(describing: error).contains("select that session"), "\(error)")
        XCTAssertEqual(WorktreeKit.list(repo: repo).count, 2, "worktree removed after focus error")
    }

    func testTaskNoRepositoryDoesNotFallBackToBackendCWD() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (_, cfg, ctx, _) = try fixture(env)
        // The fake rex emits no cwd: backend CWD must never become the origin repo.
        let (_, error) = startResult(ctx, cfg, "", "")
        guard let error else {
            XCTFail("empty repository accepted")
            return
        }
        XCTAssertTrue(String(describing: error).contains("current pane"), "\(error)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cfg.worktreeRoot),
                       "created task without origin repository")
    }
}
