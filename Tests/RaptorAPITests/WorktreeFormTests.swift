import Foundation
import RaptorCatalog
import RaptorConfig
import RaptorRex
import RaptorWorktree
import XCTest
@testable import RaptorAPI

final class WorktreeFormTests: APITestCase {
    func testMetadataOnlyCommandsAndWireShape() throws {
        let repo = try fixtureRepo(env)
        _ = try WorktreeKit.gitOut(dir: repo, args: ["branch", "alpha"])
        _ = try WorktreeKit.gitOut(dir: repo, args: ["tag", "main"])
        let sub = repo + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: false)
        let log = makeTempDir() + "/commands"
        env.set("RAPTOR_FORM_COMMANDS", log)
        try fakeTool(env, "git", """
        printf 'git %s\\n' "$*" >> "$RAPTOR_FORM_COMMANDS"
        case "$*" in
          'rev-parse --show-toplevel'|'for-each-ref --format=%(refname:strip=2)%00%(HEAD) refs/heads/')
            exec /usr/bin/git "$@" ;;
          *) exit 97 ;;
        esac
        """)
        try fakeTool(env, "wt", "printf 'wt %s\\n' \"$*\" >> \"$RAPTOR_FORM_COMMANDS\"; exit 98\n")
        let cfg = RaptorConfig.default()
        let call = makeClient(self, Handler(ctx: Ctx(block: "origin"), cfg: cfg))
        let err = call("worktrees.form", .object(["repo": .string(sub)])) { result in
            let dict = try jsonDict(result)
            XCTAssertEqual(Set(dict.keys), Set([
                "destination_root", "repo", "needs_repo", "items", "branches",
                "base_branch", "suggested_branch", "targets", "target",
                "agent", "agent_model", "agent_reasoning", "agents",
            ]))
            XCTAssertEqual(dict["agent"] as? String, "pi")
            XCTAssertEqual(dict["agent_model"] as? String, "")
            XCTAssertEqual(dict["agent_reasoning"] as? String, "")
            XCTAssertEqual(dict["agents"] as? [String], ["pi", "codex"])
            let tree = try decodeTreeRows(result)
            XCTAssertEqual(tree.repo, repo)
            XCTAssertFalse(tree.needsRepo)
            XCTAssertTrue(tree.items.isEmpty)
            XCTAssertEqual(tree.destinationRoot, "")
            XCTAssertEqual(tree.branches, ["alpha", "main"])
            XCTAssertEqual(tree.baseBranch, "main")
            XCTAssertEqual(tree.suggestedBranch.split(separator: "-").count, 2)
            XCTAssertFalse(tree.branches.contains(tree.suggestedBranch))
            XCTAssertEqual(dict["targets"] as? [String], cfg.availableTargets(hasBlock: true))
            XCTAssertEqual(dict["target"] as? String, cfg.enter)
        }
        XCTAssertEqual(err, "")
        XCTAssertEqual(try readFile(log).components(separatedBy: "\n").filter { !$0.isEmpty }, [
            "git rev-parse --show-toplevel",
            "git for-each-ref --format=%(refname:strip=2)%00%(HEAD) refs/heads/",
        ])
    }

    /// Opt-in diagnostic benchmark; no timing threshold on shared CI hosts.
    func testBenchmarkFormAgainstList() throws {
        guard env.get("RAPTOR_BENCH_WORKTREE_FORM") == "1" else {
            throw XCTSkip("set RAPTOR_BENCH_WORKTREE_FORM=1 to benchmark")
        }
        let repo = try fixtureRepo(env)
        let handler = Handler(ctx: Ctx(), cfg: .default())
        let params = JS.object(["repo": .string(repo)])
        for method in ["worktrees.form", "worktrees.list"] {
            var samples: [Double] = []
            for _ in 0..<5 {
                let start = Date()
                let (result, error) = handler.callJSON(method, params)
                samples.append(Date().timeIntervalSince(start) * 1000)
                XCTAssertNil(error)
                XCTAssertNotNil(result)
            }
            print("\(method) fixture ms: median=\(samples.sorted()[2]), samples=\(samples)")
        }
    }

    func testFreshRefsAndDetachedOrUnbornBase() throws {
        let repo = try fixtureRepo(env)
        let call = makeClient(self, Handler(ctx: Ctx(), cfg: .default()))
        func check(_ branches: [String], _ base: String) {
            XCTAssertEqual(call("worktrees.form", .object(["repo": .string(repo)])) { result in
                let tree = try decodeTreeRows(result)
                XCTAssertEqual(tree.branches, branches)
                XCTAssertEqual(tree.baseBranch, base)
            }, "")
        }
        check(["main"], "main")
        _ = try WorktreeKit.gitOut(dir: repo, args: ["branch", "alpha"])
        _ = try WorktreeKit.gitOut(dir: repo, args: ["checkout", "--detach"])
        check(["alpha", "main"], "alpha")
        _ = try WorktreeKit.gitOut(dir: repo, args: ["checkout", "alpha"])
        check(["alpha", "main"], "alpha")
        let empty = makeTempDir()
        _ = try WorktreeKit.gitOut(dir: empty, args: ["init", "-b", "main"])
        XCTAssertEqual(call("worktrees.form", .object(["repo": .string(empty)])) { result in
            let tree = try decodeTreeRows(result)
            XCTAssertTrue(tree.branches.isEmpty)
            XCTAssertEqual(tree.baseBranch, "")
            XCTAssertFalse(tree.suggestedBranch.isEmpty)
        }, "")
    }

    func testRepoResolutionIsFreshAndContextSensitive() throws {
        let repo = try fixtureRepo(env)
        env.set("RAPTOR_TEST_CWD", repo)
        try fakeTool(env, "rex", "printf '%s\\n' \"$RAPTOR_TEST_CWD\"\n")
        let call = makeClient(self, Handler(ctx: Ctx(block: "origin"), cfg: .default()))
        XCTAssertEqual(call("worktrees.form", .object([:])) { result in
            XCTAssertEqual(try decodeTreeRows(result).repo, repo)
        }, "")
        env.set("RAPTOR_TEST_CWD", makeTempDir())
        XCTAssertEqual(call("worktrees.form", .object([:])) { result in
            let tree = try decodeTreeRows(result)
            XCTAssertEqual(tree.repo, "")
            XCTAssertTrue(tree.needsRepo)
            XCTAssertTrue(tree.items.isEmpty)
            XCTAssertTrue(tree.branches.isEmpty)
            XCTAssertEqual(tree.baseBranch, "")
            XCTAssertEqual(tree.destinationRoot, "")
            XCTAssertFalse(tree.suggestedBranchPresent)
        }, "")
        XCTAssertTrue(call("worktrees.form", .object(["repo": .int(42)]), nil).contains("cannot unmarshal"))
        XCTAssertTrue(call("worktrees.form", .object(["repo": .string(makeTempDir())]), nil)
            .contains("not a git repository"))
        XCTAssertEqual(call("worktrees.form", .object(["repo": .string(repo)])) { result in
            XCTAssertEqual(try decodeTreeRows(result).repo, repo)
        }, "")
    }
}
