import Foundation
import XCTest
import RaptorConfig
import RaptorPaths
import RaptorRex
import RaptorWorktree
@testable import RaptorCatalog

final class CatalogTests: XCTestCase {
    func testDirectoryOrderAndMatching() throws {
        let dirs = ["/workspace/beta", "/workspace/alpha", "/workspace/beta", "/other/alphabet"]
        let items = Catalog.directoryItems(dirs, false)
        XCTAssertEqual(items.count, dirs.count, "directory entries were removed")
        for (i, item) in items.enumerated() {
            XCTAssertTrue(item.path == dirs[i] && item.label == RaptorPaths.basename(dirs[i]), "order or label changed: \(items)")
        }
        XCTAssertEqual(Catalog.filterDirectories(items, ""), [0, 1, 2, 3])
        XCTAssertEqual(Catalog.filterDirectories(items, "beta"), [2, 0, 3])
        XCTAssertEqual(Catalog.filterDirectories(items, "not-a-match").count, 0)
        let entries = items.map { $0.label + " " + RaptorPaths.homeRelative($0.path) }
        for query in ["alp", "wrkbet", "oth", "aa"] {
            let want = Fuzzy.find(query, entries).map { $0.index }
            XCTAssertEqual(Catalog.filterDirectories(items, query), want, "query \"\(query)\"")
        }
    }

    func testWorktreeMatching() throws {
        let items = [
            Worktree(path: "/repos/project", branch: "main", isMain: true),
            Worktree(path: "/trees/project/feature-login", branch: "feat/login"),
            Worktree(path: "/trees/project/fix-api", branch: "fix/api"),
        ]
        XCTAssertEqual(Catalog.filterWorktrees(items, ""), [0, 1, 2])
        XCTAssertEqual(Catalog.filterWorktrees(items, "flgn"), [1])
        XCTAssertEqual(Catalog.filterWorktrees(items, "fapi"), [2, 1])
        XCTAssertEqual(Catalog.filterWorktrees(items, "no-such-tree").count, 0)
        let entries = items.map { $0.branch + " " + RaptorPaths.homeRelative($0.path) }
        for query in ["prj", "ft", "main", "trees"] {
            let want = Fuzzy.find(query, entries).map { $0.index }
            XCTAssertEqual(Catalog.filterWorktrees(items, query), want, "query \"\(query)\"")
        }
    }

    func testRepositoryDiscoveryAndMetadata() throws {
        isolateWorktrunk()
        var repo = testTempDir() + "/.project"
        try makeDirectory(repo)
        for args in [
            ["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.com"],
            ["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "initial"],
        ] {
            _ = try WorktreeKit.gitOut(dir: repo, args: args)
        }
        repo = WorktreeKit.repoRoot(dir: repo)
        let sub = repo + "/sub"
        try makeDirectory(sub)
        let items = Catalog.directoryItems([testTempDir(), sub, repo, sub], true)
        XCTAssertEqual(items, [Directory(path: repo, label: ".project")], "roots not unique")
        var cfg = RaptorConfig.default()
        cfg.worktreeRoot = testTempDir()
        let info = Catalog.listWorktrees(repo, cfg)
        XCTAssertTrue(info.items.count == 1 && info.items[0].isMain && info.baseBranch == "main" && info.branches == ["main"], "metadata: \(info)")
        XCTAssertNotEqual(info.suggestedBranch, "", "missing default branch suggestion")
        XCTAssertNoThrow(
            try WorktreeKit.validate(repo: repo, branch: info.suggestedBranch, base: info.baseBranch, path: WorktreeKit.path(repo: repo, branch: info.suggestedBranch, cfg: cfg)),
            "unavailable suggestion"
        )
        let entries = try FileManager.default.contentsOfDirectory(atPath: cfg.worktreeRoot)
        XCTAssertEqual(entries.count, 0, "metadata created destinations: \(entries)")
        XCTAssertTrue(WorktreeKit.localBranches(repo: repo).count == 1 && WorktreeKit.list(repo: repo).count == 1, "metadata created a branch or worktree")
        XCTAssertEqual(pathJoin([info.root, "feat-shared"]), WorktreeKit.path(repo: repo, branch: "feat/shared", cfg: cfg), "destination differs")
        // Invoking from a secondary worktree must retain the primary repo's folder.
        let secondary = WorktreeKit.path(repo: repo, branch: "feat/shared", cfg: cfg)
        try WorktreeKit.createLocal(repo: repo, branch: "feat/shared", base: "main", path: secondary)
        let linked = Catalog.listWorktrees(secondary, cfg)
        XCTAssertTrue(linked.root == info.root && linked.baseBranch == "feat/shared" && linked.items.count == 2, "linked metadata: \(linked)")
        _ = try WorktreeKit.gitOut(dir: repo, args: ["checkout", "--detach"])
        let detached = Catalog.listWorktrees(repo, cfg)
        XCTAssertTrue(!detached.branches.isEmpty && detached.baseBranch == detached.branches[0], "detached fallback: \(detached)")
    }

    func testWorktreeSuggestionUnavailableKeepsMetadata() throws {
        // Subtests: unborn, destination-error.
        for (committed, name) in [(false, "unborn"), (true, "destination-error")] {
            isolateWorktrunk()
            let repo = testTempDir()
            _ = try WorktreeKit.gitOut(dir: repo, args: ["init", "-b", "main"])
            let root = testTempDir()
            var cfg = RaptorConfig(worktreeRoot: root)
            if committed {
                _ = try WorktreeKit.gitOut(dir: repo, args: [
                    "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
                    "commit", "--allow-empty", "-m", "initial",
                ])
                cfg.worktreeRoot = root + "/loop"
                setenvTemp("WORKTRUNK_WORKTREE_PATH", cfg.worktreeRoot + "/{{ branch | sanitize }}")
                try FileManager.default.createSymbolicLink(atPath: cfg.worktreeRoot, withDestinationPath: cfg.worktreeRoot)
            }
            let info = Catalog.listWorktrees(repo, cfg)
            XCTAssertTrue(info.suggestedBranch.isEmpty && info.items.count == 1 && info.items[0].isMain && info.baseBranch == "main", "[\(name)] suggestion failure changed metadata: \(info)")
            if committed {
                XCTAssertEqual(info.branches, ["main"], "[\(name)] branches lost")
            }
        }
    }

    func testResolveRepoWithoutOrigin() throws {
        // RepoRoot("") normally uses cwd. The backend must not infer its own repo.
        XCTAssertEqual(try Catalog.resolveRepo(Ctx(), ""), "", "unexpected fallback")
        XCTAssertThrowsError(try Catalog.resolveRepo(Ctx(), testTempDir()), "invalid explicit repo accepted")
    }
}
