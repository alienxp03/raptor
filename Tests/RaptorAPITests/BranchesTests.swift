import Foundation
import RaptorCatalog
import RaptorRex
import RaptorWorktree
import XCTest
@testable import RaptorAPI

final class BranchesTests: APITestCase {
    func testLocalBranchSearch() throws {
        let repo = try fixtureRepo(env)
        for args in [
            ["branch", "feat/long-login"], ["branch", "fix/login"], ["branch", "login"],
            ["update-ref", "refs/remotes/origin/remote-only", "HEAD"],
            ["tag", "tag-only"],
            // An unusable remote must not affect local branch search.
            ["remote", "add", "origin", makeTempDir() + "/missing.git"],
        ] {
            _ = try WorktreeKitGit.gitOut(repo, args)
        }
        let sub = repo + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: false)
        let call = makeClient(self, Handler(ctx: Ctx(), cfg: .default()))
        let branches = ["feat/long-login", "fix/login", "login", "main"]
        for query in ["", "login", "flgn", "MAIN", "remote-only", "tag-only", "no-such-branch"] {
            try subtest("query=\(query)", {
                var got: [String] = []
                let err = call("worktrees.branches", .object(["repo": .string(sub), "query": .string(query)])) { result in
                    let dict = try jsonDict(result)
                    got = dict["branches"] as? [String] ?? []
                }
                if !err.isEmpty {
                    throw MessageError(err)
                }
                let want = Catalog.filterBranches(branches, query)
                if got != want {
                    XCTFail("got \(got), want \(want)")
                }
                if query == "login" && got[0] != "login" {
                    XCTFail("exact match not first: \(got)")
                }
            })
        }
        // Search reads current local refs, not a cached worktree listing.
        _ = try WorktreeKitGit.gitOut(repo, ["branch", "new-local"])
        var got: [String] = []
        let err = call("worktrees.branches", .object(["repo": .string(repo), "query": .string("new-local")])) { result in
            let dict = try jsonDict(result)
            got = dict["branches"] as? [String] ?? []
        }
        if !err.isEmpty || got != ["new-local"] {
            XCTFail("fresh branches: \(got), \(err)")
        }
    }

    func testLocalBranchSearchEmptyRepo() throws {
        let repo = makeTempDir()
        _ = try WorktreeKitGit.gitOut(repo, ["init", "-b", "main"])
        let call = makeClient(self, Handler(ctx: Ctx(), cfg: .default()))
        for query in ["", "main"] {
            var missing = false
            var got: [String] = []
            let err = call("worktrees.branches", .object(["repo": .string(repo), "query": .string(query)])) { result in
                let dict = try jsonDict(result)
                // nil marks a missing key; [] is an explicit empty list.
                if dict["branches"] == nil {
                    missing = true
                } else {
                    got = dict["branches"] as? [String] ?? []
                }
            }
            if !err.isEmpty || missing || !got.isEmpty {
                XCTFail("empty repo: missing=\(missing) got=\(got), \(err)")
            }
        }
    }

    func testLocalBranchSearchRepoResolutionAndErrors() throws {
        let repo = try fixtureRepo(env)
        env.set("RAPTOR_TEST_CWD", repo)
        try fakeTool(env, "rex", "printf '%s\\n' \"$RAPTOR_TEST_CWD\"\n")
        let origin = makeClient(self, Handler(ctx: Ctx(block: "origin"), cfg: .default()))
        var got: [String] = []
        var err = origin("worktrees.branches", .object(["query": .string("main")])) { result in
            let dict = try jsonDict(result)
            got = dict["branches"] as? [String] ?? []
        }
        if !err.isEmpty || got != ["main"] {
            XCTFail("origin resolution: \(got), \(err)")
        }
        let call = makeClient(self, Handler(ctx: Ctx(), cfg: .default()))
        let table: [(params: [String: JS], want: String)] = [
            ([:], "choose a repository"),
            (["repo": .string("")], "choose a repository"),
            (["repo": .string(makeTempDir())], "not a git repository"),
            (["repo": .string(makeTempDir() + "/missing")], "not a git repository"),
            (["repo": .int(42)], "cannot unmarshal"),
            (["repo": .string(repo), "query": .int(42)], "cannot unmarshal"),
        ]
        for tc in table {
            let failErr = call("worktrees.branches", .object(tc.params), nil)
            if !failErr.contains(tc.want) {
                XCTFail("params \(tc.params): got \(failErr), want \(tc.want)")
            }
        }
        // Invalid origin also must not fall back to the backend working directory.
        env.set("RAPTOR_TEST_CWD", makeTempDir())
        err = origin("worktrees.branches", .object([:]), nil)
        if err != "choose a repository" {
            XCTFail("invalid origin: \(err)")
        }
    }
}

/// WorktreeKit.gitOut wrapper with Go's GitOut argument order.
enum WorktreeKitGit {
    static func gitOut(_ dir: String, _ args: [String]) throws -> String {
        try WorktreeKit.gitOut(dir: dir, args: args)
    }
}
