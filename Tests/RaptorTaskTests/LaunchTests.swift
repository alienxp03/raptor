import XCTest
import RaptorPullrequest
import RaptorWorktree
@testable import RaptorTask

final class LaunchTests: XCTestCase {
    func testLaunchSelectsProgressSessionBeforeWorktreeAndHooks() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, cfg, ctx, log) = try fixture(env)
        // Even an invalid hook configuration belongs to visible terminal setup,
        // not the synchronous launch path.
        try "[pre-switch]\ncheck = \"false\"\n".write(toFile: env.get("WORKTRUNK_PROJECT_CONFIG_PATH")!, atomically: true, encoding: .utf8)
        let result = try RaptorTask.launch(ctx: ctx, cfg: cfg, explicitRepo: repo, resumePath: "",
                                           executable: "/raptor path/raptor")
        XCTAssertEqual(result.sessionID, "new-session")
        XCTAssertEqual(WorktreeKit.list(repo: repo).count, 1, "launch must select before creating a worktree")
        let calls = try readText(log)
        XCTAssertTrue(calls.contains("new\nStarting agent…\n-c\n" + canonical(repo)), calls)
        XCTAssertTrue(calls.contains("Creating worktree and starting Pi…"), calls)
        XCTAssertTrue(calls.contains("'/raptor path/raptor' '-client' 'iphone' 'task' '--finish-in-session' '--repo'"), calls)
        XCTAssertTrue(calls.contains("Agent setup failed"), calls)
        XCTAssertTrue(calls.contains("session_id=new-session"), calls)
        XCTAssertFalse(calls.contains("window\nnew\n"), calls)
    }

    func testFinishUsesProgressSessionInsteadOfCreatingAnotherSession() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, cfg, ctx, log) = try fixture(env)
        let result = try RaptorTask.start(ctx: ctx, cfg: cfg, explicitRepo: repo, resumePath: "", inSession: true)
        XCTAssertEqual(result.sessionID, ctx.session)
        XCTAssertEqual(result.blockID, "new-block")
        let calls = try readText(log)
        XCTAssertTrue(calls.contains("window\nnew\n-s\norigin-session"), calls)
        XCTAssertTrue(calls.contains("session\nrename\norigin-session\n" + result.branch), calls)
        XCTAssertFalse(calls.contains("CALL\nnew\n"), calls)
    }

    func testLaunchSelectionFailurePreservesProgressSessionIdentity() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, cfg, ctx, _) = try fixture(env)
        env.set("TASK_FAIL", "focus")
        XCTAssertThrowsError(try RaptorTask.launch(ctx: ctx, cfg: cfg, explicitRepo: repo, resumePath: "", executable: "/raptor")) { error in
            XCTAssertEqual((error as? StartError)?.result.sessionID, "new-session")
            XCTAssertTrue(String(describing: error).contains("select that session"))
        }
    }
}
