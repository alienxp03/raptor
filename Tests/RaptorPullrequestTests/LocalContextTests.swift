import XCTest
import RaptorRex
@testable import RaptorPullrequest

/// Ported from internal/pullrequest/local_context_test.go.
final class LocalContextTests: XCTestCase {
    func testLocalCreationUsesSelectedBaseWorktreeContext() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, source) = try localFixture(env)
        env.set("LOCAL_PHASE", "pre-start")
        env.set("PR_HOOK_JSON", #"[{"name":"check","template":"echo {{ base_worktree_path }} {{ args }}"}]"#)
        _ = try git(repo, ["worktree", "add", "-b", "source", source])
        let plan = try Pullrequest.preflightLocal(source: source)
        let target = dirOf(source) + "/local-target"
        _ = try git(repo, ["worktree", "add", "-b", "local", target, "main"])
        try plan.register(path: target, branch: "local", base: "main")
        var s = try RaptorPullrequest.load(target)
        XCTAssertEqual(s.source, source)
        XCTAssertEqual(s.basePath ?? "", repo)
        XCTAssertEqual(s.base, "main", "wrong base context: \(s)")
        s.released = true
        try RaptorPullrequest.save(target, s)
        try Pullrequest.setup(path: target, retry: false)
        let log = try readLog(env)
        XCTAssertTrue(log.contains("--base_worktree_path=" + repo), log)
        XCTAssertFalse(log.contains("--var"), log)
        XCTAssertFalse(log.contains("--pr_url="), log)
        XCTAssertFalse(log.contains("--pr_number="), log)
        XCTAssertFalse(log.contains("--branch="), "Unused variables must not become hook arguments: \(log)")
    }

    func testHookVariableShorthandOnlyIncludesTemplateReferences() {
        let hooks: [Any] = [["template": "echo branch {{ args }} {{ target_worktree_path }} {% if base %}{{ base }}{% endif %}"]]
        XCTAssertEqual(hookVariableArguments(["branch=feature", "target_worktree_path=/worktree", "base=main", "target=feature"], hooks: hooks),
                       ["--target_worktree_path=/worktree", "--base=main"])
        XCTAssertEqual(hookVariableArguments(["branch=feature"], hooks: []), [])
    }

    func testFinishedLocalSetupDoesNotBlockOrdinaryNavigation() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, path) = try localFixture(env)
        env.set("LOCAL_PHASE", "pre-start")
        let plan = try Pullrequest.preflightLocal(source: repo)
        _ = try git(repo, ["worktree", "add", "-b", "local", path])
        try plan.register(path: path, branch: "local", base: "main")
        var s = try RaptorPullrequest.load(path)
        s.instance = "old-registration"
        s.complete = true
        try RaptorPullrequest.save(path, s)
        var pendingErr: Error?
        var pending = false
        do {
            pending = try Pullrequest.localPending(path)
        } catch {
            pendingErr = error
        }
        if let pendingErr {
            XCTFail("completed setup blocked navigation: \(pendingErr)")
        }
        XCTAssertFalse(pending)
        s.complete = false
        try RaptorPullrequest.save(path, s)
        XCTAssertThrowsError(try Pullrequest.localPending(path), "stale pending setup silently skipped")
    }

    func testLocalTaskUsesCommittedHEADBase() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, path) = try localFixture(env)
        env.set("LOCAL_PHASE", "pre-start")
        let head = try git(repo, ["rev-parse", "HEAD"])
        let plan = try Pullrequest.preflightLocal(source: repo)
        _ = try git(repo, ["worktree", "add", "-b", "task", path, head])
        try plan.register(path: path, branch: "task", base: "")
        let s = try RaptorPullrequest.load(path)
        XCTAssertEqual(s.base, head, "wrong committed HEAD context: \(s)")
        XCTAssertEqual(s.basePath ?? "", "")
    }
}
