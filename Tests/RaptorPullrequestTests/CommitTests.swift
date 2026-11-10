import XCTest
import RaptorRex
@testable import RaptorPullrequest

/// Ported from internal/pullrequest/commit_test.go.
final class CommitTests: XCTestCase {
    func testHeadMetadata() {
        for state in ["OPEN", "CLOSED", "MERGED"] {
            for deleted in [true, false] {
                subtest(state + "/" + (deleted ? "deleted" : "present")) {
                    let env = TestEnv()
                    defer { env.restore() }
                    let (repo, _, _, oid) = try commitFixture(env, state: state, deleted: deleted)
                    let (info, err) = resolveInfo(repo, "42")
                    XCTAssertNil(err, "\(info) \(String(describing: err))")
                    XCTAssertEqual(info.state, state)
                    XCTAssertEqual(info.headDeleted, deleted)
                    XCTAssertEqual(info.headOID, oid)
                    XCTAssertEqual(info.branch, "feat/fix")
                }
            }
        }
    }

    func testNormalPrepareWithHeadMetadata() {
        for state in ["OPEN", "CLOSED", "MERGED"] {
            subtest(state) {
                let env = TestEnv()
                defer { env.restore() }
                let (repo, path, _, _) = try commitFixture(env, state: state, deleted: false)
                let wtPath = dirOf(repo) + "/bin/wt"
                let data = try String(contentsOfFile: wtPath, encoding: .utf8)
                var text = data.replacingOccurrences(of: #"git worktree add -q "$PR_DEST" pr/42"#,
                                                     with: #"git worktree add -q -b feat/fix "$PR_DEST""#)
                text = text.replacingOccurrences(of: #""branch":"pr/42""#, with: #""branch":"feat/fix""#)
                try put(wtPath, text)
                let (info, err) = prepareInfo(repo, "42")
                XCTAssertNil(err, "\(info) \(String(describing: err))")
                XCTAssertFalse(info.headDeleted)
                XCTAssertEqual(info.branch, "feat/fix")
                XCTAssertTrue(Pullrequest.ready(path: path))
                let calls = try readLog(env)
                XCTAssertTrue(calls.contains("switch --no-hooks --no-cd --format=json https://github.com/acme/project/pull/42"), calls)
            }
        }
    }

    func testHeadMetadataFailureIsNotDeletion() {
        for mode in ["network", "missing", "errors"] {
            subtest(mode) {
                let env = TestEnv()
                defer { env.restore() }
                let (repo, _, _, _) = try commitFixture(env, state: "CLOSED", deleted: false)
                switch mode {
                case "network": env.set("PR_API_FAIL", "1")
                case "missing": env.set("PR_GRAPHQL", "{}")
                case "errors": env.set("PR_GRAPHQL", "{\"errors\":[{\"message\":\"denied\"}]}")
                default: break
                }
                let (info, err) = resolveInfo(repo, "42")
                XCTAssertNotNil(err, mode)
                XCTAssertFalse(info.headDeleted, mode)
            }
        }
    }

    func testDeletedHeadDefaultRefusal() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, path, _, _) = try commitFixture(env, state: "CLOSED", deleted: true)
        let before = try git(repo, ["show-ref"])
        let (info, err) = prepareInfo(repo, "42")
        XCTAssertNotNil(err)
        XCTAssertTrue(String(describing: err!).contains("Check out PR commit"), "\(err!)")
        XCTAssertTrue(info.headDeleted)
        XCTAssertEqual(try git(repo, ["show-ref"]), before, "refs changed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "created worktree")
        XCTAssertFalse(FileManager.default.fileExists(atPath: (env.get("XDG_STATE_HOME") ?? "") + "/raptor/pullrequest"),
                       "created state before refusal")
        let calls = try readLog(env)
        XCTAssertFalse(calls.contains("switch --"), calls)
        XCTAssertFalse(calls.contains("clone"), calls)
    }

    func testExplicitCommitCheckout() throws {
        let env = TestEnv()
        defer { env.restore() }
        let (repo, path, _, oid) = try commitFixture(env, state: "CLOSED", deleted: true)
        let preview = try Pullrequest.resolveWithOptions(repo: repo, input: "42", checkoutCommit: true)
        XCTAssertEqual(preview.branch, "pr/42")
        XCTAssertEqual(preview.path, path)
        // The original local branch, if present, is unrelated and must remain untouched.
        _ = try git(repo, ["-c", "user.name=Test", "-c", "user.email=test@example.com",
                           "commit", "--allow-empty", "-m", "unrelated"])
        let original = try git(repo, ["rev-parse", "HEAD"])
        _ = try git(repo, ["branch", "feat/fix"])
        for i in 0..<2 {
            let (info, err) = prepareInfoWithCommit(repo, "42", true)
            XCTAssertNil(err, "\(info) \(String(describing: err))")
            XCTAssertEqual(info.branch, "pr/42")
            XCTAssertEqual(info.path, path)
            XCTAssertEqual(info.existing, i == 1)
            XCTAssertTrue(Pullrequest.ready(path: path), "missing bound setup journal")
        }
        XCTAssertEqual(try git(path, ["rev-parse", "HEAD"]), oid)
        XCTAssertEqual(try git(repo, ["rev-parse", "feat/fix"]), original, "original branch changed")
        XCTAssertEqual(try git(repo, ["for-each-ref", "refs/raptor/"]), "", "temporary refs leaked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/.git/FETCH_HEAD"), "wrote FETCH_HEAD")
        let s = try RaptorPullrequest.load(path)
        XCTAssertTrue(s.new)
        XCTAssertEqual(s.branch, "pr/42")
        let (_, openErr) = openResult(path, "session", Ctx(client: "client"))
        XCTAssertNil(openErr, "\(String(describing: openErr))")
        try Pullrequest.setup(path: path, retry: false)
        let calls = try readLog(env)
        XCTAssertEqual(calls.components(separatedBy: "wt hook pre-start --").count - 1, 1, calls)
        XCTAssertEqual(calls.components(separatedBy: "wt hook post-start --").count - 1, 1, calls)
        XCTAssertTrue(calls.contains("switch --no-hooks --no-cd --format=json pr/42"), calls)
    }

    func testCommitCheckoutRefSafety() {
        for mode in ["missing", "mismatch", "collision", "symbolic", "dangling-symbolic", "same-oid", "pre-switch", "partial-switch"] {
            subtest(mode) {
                let env = TestEnv()
                defer { env.restore() }
                let (repo, path, remote, oid) = try commitFixture(env, state: "MERGED", deleted: true)
                _ = try git(repo, ["-c", "user.name=Test", "-c", "user.email=test@example.com",
                                   "commit", "--allow-empty", "-m", "other"])
                let other = try git(repo, ["rev-parse", "HEAD"])
                switch mode {
                case "missing":
                    _ = try git(remote, ["update-ref", "-d", "refs/pull/42/head"])
                case "mismatch":
                    _ = try git(repo, ["push", remote, "HEAD:refs/pull/42/head"]) // Local fixture only.
                case "collision":
                    _ = try git(repo, ["branch", "pr/42", other])
                case "symbolic":
                    _ = try git(repo, ["symbolic-ref", "refs/heads/pr/42", "refs/heads/main"])
                case "dangling-symbolic":
                    _ = try git(repo, ["symbolic-ref", "refs/heads/pr/42", "refs/heads/missing"])
                case "same-oid":
                    _ = try git(repo, ["branch", "pr/42", oid])
                case "pre-switch":
                    env.set("PR_PRE_SWITCH", "1")
                case "partial-switch":
                    env.set("PR_SWITCH_FAIL", "1")
                default:
                    break
                }
                let (info, err) = prepareInfoWithCommit(repo, "42", true)
                if mode == "same-oid" {
                    XCTAssertNil(err, "\(info) \(String(describing: err))")
                    XCTAssertTrue(Pullrequest.ready(path: path), mode)
                } else if mode == "partial-switch" {
                    XCTAssertNotNil(err, mode)
                    XCTAssertTrue(Pullrequest.ready(path: path), mode)
                } else {
                    XCTAssertNotNil(err, "\(mode) expected refusal")
                    XCTAssertFalse(FileManager.default.fileExists(atPath: path), "\(mode) worktree created")
                }
                if mode == "symbolic" {
                    XCTAssertEqual(try git(repo, ["symbolic-ref", "refs/heads/pr/42"]), "refs/heads/main", "symbolic ref changed")
                }
                if mode == "dangling-symbolic" {
                    XCTAssertEqual(try git(repo, ["symbolic-ref", "refs/heads/pr/42"]), "refs/heads/missing", "dangling symbolic ref changed")
                }
                if mode == "collision" {
                    XCTAssertEqual(try git(repo, ["rev-parse", "pr/42"]), other, "collision overwritten")
                }
                XCTAssertEqual(try git(repo, ["rev-parse", "HEAD"]), other, "source HEAD changed")
                XCTAssertEqual(try git(repo, ["for-each-ref", "refs/raptor/"]), "", "temporary ref leaked")
            }
        }
    }
}
