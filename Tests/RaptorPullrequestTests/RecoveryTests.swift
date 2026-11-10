import XCTest
import RaptorRex
@testable import RaptorPullrequest

/// Ported from internal/pullrequest/recovery_test.go.
final class RecoveryTests: XCTestCase {
    func testCloneBaseLocally() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (source, path) = try fixture(env)
        env.set("PR_CLONE_SOURCE", source)
        let (info, err) = prepareInfo("", "https://github.com/acme/project/pull/42")
        XCTAssertNil(err, "\(String(describing: err))")
        let expected = pathJoin([(env.get("HOME") ?? ""), "workspace", "acme", "project"])
        XCTAssertEqual(info.repo, expected)
        XCTAssertEqual(info.path, path)
        XCTAssertFalse(info.cloneRequired)
        XCTAssertEqual(try git(expected, ["remote", "get-url", "origin"]), "https://github.com/acme/project.git")
    }

    func testSourceWorktreeContext() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, path) = try fixture(env)
        let source = dirOf(repo) + "/source"
        _ = try git(repo, ["worktree", "add", "-b", "source-branch", source])
        let (info, err) = prepareInfo(source, "42")
        XCTAssertNil(err, "\(info) \(String(describing: err))")
        XCTAssertEqual(info.repo, repo)
        let s = try RaptorPullrequest.load(path)
        XCTAssertEqual(s.source, source)
        XCTAssertEqual(s.base, "source-branch")
    }

    func testZoxideOriginDiscovery() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, _) = try fixture(env)
        let bin = firstPathDir(env)
        try put(bin + "/zoxide", "#!/bin/sh\nprintf '%s\\n' " + quote(repo) + "\n")
        let (info, err) = resolveInfo("", "https://github.com/acme/project/pull/42")
        XCTAssertNil(err, "\(String(describing: err))")
        XCTAssertEqual(info.repo, repo)
        XCTAssertFalse(info.cloneRequired)
    }

    func testUncertainOpenReconcilesByCanonicalPath() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, path) = try fixture(env)
        XCTAssertNotNil(try? Pullrequest.prepare(repo: repo, input: "42"))
        var s = try RaptorPullrequest.load(path)
        s.opening = true
        s.target = "session"
        try RaptorPullrequest.save(path, s)
        let (result, err) = openResult(path, "session", Ctx(client: "client"))
        XCTAssertNil(err, "\(String(describing: err))")
        XCTAssertEqual(result.sessionID ?? "", "s1")
        XCTAssertEqual(result.blockID ?? "", "b1")
        let calls = try readLog(env)
        XCTAssertFalse(calls.contains("rex new "), "duplicated uncertain session")
    }

    func testOpenBusyReturnsRecoveryIDs() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, path) = try fixture(env)
        XCTAssertNotNil(try? Pullrequest.prepare(repo: repo, input: "42"))
        let ctx = Ctx(client: "client")
        let (_, openErr) = openResult(path, "session", ctx)
        XCTAssertNil(openErr, "\(String(describing: openErr))")
        let unlock = try lock(path, false)
        defer { unlock() }
        let (result, err) = openResult(path, "session", ctx)
        XCTAssertNotNil(err)
        XCTAssertEqual(result.sessionID ?? "", "s1")
        XCTAssertNotEqual(result.error ?? "", "")
    }

    func testInterruptedBackgroundNotReplayed() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, path) = try fixture(env)
        XCTAssertNotNil(try? Pullrequest.prepare(repo: repo, input: "42"))
        var s = try RaptorPullrequest.load(path)
        s.released = true
        s.stage = 1
        s.failed = "post-start interrupted"
        try RaptorPullrequest.save(path, s)
        XCTAssertThrowsError(try Pullrequest.setup(path: path, retry: true)) { error in
            XCTAssertTrue(String(describing: error).contains("not replayed"), "\(error)")
        }
        let calls = try readLog(env)
        XCTAssertFalse(calls.contains("wt hook post-start --"), "replayed uncertain background hook")
    }
}
