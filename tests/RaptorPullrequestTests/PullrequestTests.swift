import XCTest
import RaptorRex
@testable import RaptorPullrequest

/// Ported from internal/pullrequest/pullrequest_test.go.
final class PullrequestTests: XCTestCase {
    func testInputAndIdentity() throws {
        for input in ["42", "https://gitlab.com/acme/project/pull/42", "https://github.com/acme/project/issues/42",
                      "https://github.com/acme/project/pull/0", "https://github.com/acme/project/pull/42?x=1",
                      "https://github.com/../project/pull/42"] {
            XCTAssertThrowsError(try parse(input, ""), "accepted \(input)")
        }
        for origin in ["git@github.com:acme/project.git", "ssh://git@github.com/acme/project.git", "https://github.com/acme/project"] {
            let id = try identity(origin)
            XCTAssertEqual(id, "acme/project", "\(origin): \(id) \(String(describing: id))")
        }
    }

    func testResolveReadOnlyAndContext() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, path) = try fixture(env)
        let (info, err) = resolveInfo(repo, "42")
        XCTAssertNil(err, "\(String(describing: err))")
        XCTAssertEqual(info.repo, repo)
        XCTAssertEqual(info.path, path)
        XCTAssertEqual(info.number, 42)
        XCTAssertFalse(info.cloneRequired)
        XCTAssertFalse(info.existing)
        let calls = try readLog(env)
        XCTAssertFalse(calls.contains("switch"), calls)
        XCTAssertFalse(calls.contains("clone"), calls)
        _ = try git(repo, ["remote", "set-url", "origin", "https://github.com/wrong/project.git"])
        XCTAssertThrowsError(try Pullrequest.resolve(repo: repo, input: "https://github.com/acme/project/pull/42"),
                             "accepted context mismatch")
    }

    func testMissingCloneAndOccupiedDestination() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (source, _) = try fixture(env)
        env.set("PR_CLONE_SOURCE", source)
        let (info, err) = resolveInfo("", "https://github.com/acme/project/pull/42")
        XCTAssertNil(err, "\(String(describing: err))")
        XCTAssertTrue(info.cloneRequired)
        XCTAssertEqual(info.path, "")
        try put(info.repo + "/keep", "do not touch")
        XCTAssertThrowsError(try Pullrequest.prepare(repo: "", input: info.url), "accepted occupied clone path")
        let data = try String(contentsOfFile: info.repo + "/keep", encoding: .utf8)
        XCTAssertEqual(data, "do not touch", "changed occupied clone")
    }

    func testPrepareAndVisibleSetupRetry() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, path) = try fixture(env)
        let (info, prepErr) = prepareInfo(repo, "42")
        XCTAssertNil(prepErr, "\(String(describing: prepErr))")
        XCTAssertFalse(info.existing)
        XCTAssertEqual(info.path, path)
        var s = try RaptorPullrequest.load(path)
        XCTAssertTrue(s.new)
        try put(env.get("PR_FAIL") ?? "", "fail")
        let (first, firstErr) = openResult(path, "session", Ctx(client: "client"))
        XCTAssertNotNil(firstErr)
        XCTAssertEqual(first.sessionID ?? "", "s1")
        XCTAssertNotEqual(first.error ?? "", "")
        s = try RaptorPullrequest.load(path)
        XCTAssertFalse(s.released, "released before selection")
        try FileManager.default.removeItem(atPath: env.get("PR_FAIL") ?? "")
        let (second, secondErr) = openResult(path, "session", Ctx(client: "client"))
        XCTAssertNil(secondErr, "\(String(describing: secondErr))")
        XCTAssertEqual(second.blockID ?? "", "b1")
        var calls = try readLog(env)
        XCTAssertEqual(calls.components(separatedBy: "rex new ").count - 1, 1, calls)
        XCTAssertTrue(calls.contains("setup --path") && calls.contains("exec"), "missing usable-shell wrapper")
        try put(env.get("PR_FAIL") ?? "", "fail")
        do {
            try Pullrequest.setup(path: path, retry: false)
            XCTFail("setup succeeded")
        } catch {
            XCTAssertTrue(String(describing: error).contains("exit status 7"), "\(error)")
        }
        s = try RaptorPullrequest.load(path)
        XCTAssertEqual(s.stage, 0)
        XCTAssertNotEqual(s.failed ?? "", "")
        XCTAssertThrowsError(try Pullrequest.setup(path: path, retry: false), "implicitly retried failed setup")
        try? FileManager.default.removeItem(atPath: env.get("PR_FAIL") ?? "")
        try Pullrequest.setup(path: path, retry: true)
        try Pullrequest.setup(path: path, retry: true)
        calls = try readLog(env)
        XCTAssertEqual(calls.components(separatedBy: "wt hook post-start --").count - 1, 1, calls)
        XCTAssertEqual(calls.components(separatedBy: "wt hook post-switch --").count - 1, 1, calls)
        s = try RaptorPullrequest.load(path)
        XCTAssertTrue(s.complete, "\(s)")
    }

    func testExistingWorktreeNoCreationSetup() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, path) = try fixture(env)
        _ = try git(repo, ["worktree", "add", "-b", "feat/fix", path])
        let (info, err) = prepareInfo(repo, "42")
        XCTAssertNil(err, "\(String(describing: err))")
        XCTAssertTrue(info.existing)
        let (_, openErr) = openResult(path, "tab", Ctx(session: "s1", client: "client"))
        XCTAssertNil(openErr, "\(String(describing: openErr))")
        try Pullrequest.setup(path: path, retry: false)
        let calls = try readLog(env)
        XCTAssertFalse(calls.contains("wt hook pre-start --"), calls)
        XCTAssertFalse(calls.contains("wt hook post-start --"), calls)
    }

    func testPartialSwitchRetainsRecovery() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, path) = try fixture(env)
        env.set("PR_SWITCH_FAIL", "1")
        let (info, err) = prepareInfo(repo, "42")
        XCTAssertNotNil(err)
        XCTAssertEqual(info.path, path)
        var s = try RaptorPullrequest.load(path)
        XCTAssertTrue(s.new)
        env.set("PR_SWITCH_FAIL", "")
        let (_, retryErr) = prepareInfo(repo, "42")
        XCTAssertNil(retryErr, "\(String(describing: retryErr))")
        s = try RaptorPullrequest.load(path)
        XCTAssertTrue(s.new, "lost pending creation hooks")
    }

    func testPreSwitchFailsBeforeMutation() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, path) = try fixture(env)
        env.set("PR_PRE_SWITCH", "1")
        XCTAssertThrowsError(try Pullrequest.prepare(repo: repo, input: "42"), "accepted pre-switch hooks")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "created before pre-switch")
    }

    func testLockAndCanonicalIdentity() throws {
        let env = TestEnv()
        defer { env.restore() }
        let root = try makeTempDir()
        env.set("XDG_STATE_HOME", root + "/state")
        let alias = root + "/alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: root)
        let a = try stateFile(alias + "/future", ".json")
        try FileManager.default.createDirectory(atPath: root + "/future", withIntermediateDirectories: false)
        let b = try stateFile(root + "/future", ".json")
        XCTAssertEqual(a, b, "state identity changed: \(a) != \(b)")
        let unlock = try lock(root + "/future", false)
        defer { unlock() }
        if let second = try? lock(alias + "/future", false) {
            second()
            XCTFail("double lock")
        }
        let data = try JSONEncoder().encode(Info())
        let json = String(decoding: data, as: UTF8.self)
        for field in ["input", "url", "number", "title", "branch", "repo", "path", "clone_required", "existing"] {
            XCTAssertTrue(json.contains("\"\(field)\":"), json)
        }
    }

    func testApprovalAndConfigFailures() {
        for mode in ["approval", "config"] {
            subtest(mode) {
                let env = TestEnv()
                defer { env.restore() }
                let (repo, path) = try fixture(env)
                let (_, prepErr) = prepareInfo(repo, "42")
                XCTAssertNil(prepErr, "prepare: \(String(describing: prepErr))")
                let (_, openErr) = openResult(path, "session", Ctx(client: "client"))
                XCTAssertNil(openErr, "\(String(describing: openErr))")
                if mode == "approval" {
                    env.set("PR_DENY", "1")
                } else {
                    try put(path + "/.config/wt.toml", "pre-start = 'different'\n")
                }
                XCTAssertThrowsError(try Pullrequest.setup(path: path, retry: false),
                                     "marked unsafe/skipped setup successful")
                let s = try RaptorPullrequest.load(path)
                XCTAssertFalse(s.complete, "setup complete")
            }
        }
    }
}
