import XCTest
import RaptorConfig
@testable import RaptorWorktree

/// Ported from internal/worktree/worktree_test.go.
final class WorktreeTests: XCTestCase {
    func testRepoFolder() {
        for (input, want) in [(".dotfiles", "dotfiles"), ("raptor", "raptor"), ("...", "repository")] {
            XCTAssertEqual(WorktreeKit.repoFolder(input), want, "RepoFolder(\(input))")
        }
    }

    func testLocalWorktreeLifecycle() throws {
        let env = TestEnv()
        defer { env.restore() }
        let repo = try fixtureRepo(env)
        let root = try makeTempDir()
        let pairs = [("feat/login", "feature-login"), ("fix/crash", "fix-crash"),
                     ("chore/deps", "chore-deps"), ("refactor/auth/session", "refactor-auth-session")]
        for (input, want) in pairs {
            XCTAssertEqual(WorktreeKit.folder(input), want, "\(input) -> \(want)")
        }
        let path = WorktreeKit.path(repo: repo, branch: "feat/login", cfg: RaptorConfig(worktreeRoot: root))
        XCTAssertTrue(path.hasSuffix("repo/feat-login"), path)
        try WorktreeKit.createLocal(repo: repo, branch: "feat/login", base: "main", path: path)
        let trees = WorktreeKit.list(repo: repo)
        XCTAssertEqual(trees.count, 2)
        XCTAssertTrue(trees[0].isMain)
        XCTAssertEqual(trees[1].branch, "feat/login")
        XCTAssertThrowsError(try WorktreeKit.createLocal(repo: repo, branch: "feat/login", base: "main", path: path),
                             "duplicate accepted")
        XCTAssertThrowsError(try WorktreeKit.validate(repo: repo, branch: "../escape", base: "main", path: path + "new"),
                             "invalid name accepted")
        XCTAssertThrowsError(try WorktreeKit.validate(repo: repo, branch: "feat/new", base: "missing", path: path + "new"),
                             "invalid base accepted")
        try "keep me".write(toFile: path + "/unsaved", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try WorktreeKit.remove(repo: repo, tree: trees[1]), "dirty worktree removed")
        try FileManager.default.removeItem(atPath: path + "/unsaved")
        try WorktreeKit.remove(repo: repo, tree: trees[1])
        _ = try WorktreeKit.gitOut(dir: repo, args: ["show-ref", "--verify", "refs/heads/feat/login"])
        XCTAssertThrowsError(try WorktreeKit.remove(repo: repo, tree: trees[0]), "primary removable")
    }
}
