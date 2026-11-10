import XCTest
@testable import RaptorWorktree

/// Ported from internal/worktree/preview_test.go.
final class PreviewTests: XCTestCase {
    func testPreviewConfigPrecedence() throws {
        let env = TestEnv()
        defer { env.restore() }
        let repo = try fixtureRepo(env)
        env.unset("WORKTRUNK_WORKTREE_PATH")
        let root = dirOf(repo)
        let system = try XCTUnwrap(env.get("WORKTRUNK_SYSTEM_CONFIG_PATH"))
        let user = root + "/user.toml"
        env.set("WORKTRUNK_CONFIG_PATH", user)
        // Use a remote identifier to exercise wildcard matching across slashes.
        _ = try WorktreeKit.gitOut(dir: repo, args: ["remote", "add", "origin", "git@github.com:team/subgroup/project.git"])
        let cases: [(system: String, user: String, want: String)] = [
            ("", "", pathJoin([root, "repo.feat-login"])),
            ("worktree-path = '../system/{{ branch | sanitize }}'", "", pathJoin([root, "system/feat-login"])),
            ("worktree-path = '../system/{{ branch | sanitize }}'",
             "worktree-path = '../user/{{ branch | sanitize }}'", pathJoin([root, "user/feat-login"])),
            ("",
             "worktree-path = '../global/{{ branch | sanitize }}'\n[projects.'github.com/*']\nworktree-path = '../host/{{ branch | sanitize }}'\n[projects.'github.com/team/*']\nworktree-path = '../team/{{ branch | sanitize }}'",
             pathJoin([root, "team/feat-login"])),
            ("",
             "[projects.'github.com/team/*']\nworktree-path = '../team/{{ branch | sanitize }}'\n[projects.'github.com/team/subgroup/project']\nworktree-path = '../exact/{{ branch }}'",
             pathJoin([root, "exact/feat/login"])),
        ]
        for (i, tc) in cases.enumerated() {
            try tc.system.write(toFile: system, atomically: true, encoding: .utf8)
            try tc.user.write(toFile: user, atomically: true, encoding: .utf8)
            do {
                let got = try WorktreeKit.previewPath(repo: repo, branch: "feat/login")
                XCTAssertEqual(got, tc.want, "case \(i): got \(got), want \(tc.want)")
            } catch {
                XCTFail("case \(i): \(error)")
            }
        }
    }

    func testPreviewAndCreationAgreeFromLinkedWorktree() throws {
        let env = TestEnv()
        defer { env.restore() }
        let repo = try fixtureRepo(env)
        let first = WorktreeKit.switchWorktree(repo: repo, args: ["--create", "feat/first", "--base", "main"])
        XCTAssertNil(first.error)
        let tree = first.tree
        let primary = try WorktreeKit.previewPath(repo: repo, branch: "feat/second")
        let linked = try WorktreeKit.previewPath(repo: tree.path, branch: "feat/second")
        XCTAssertEqual(linked, primary, "\(linked) \(String(describing: first.error)), want \(primary)")
        try WorktreeKit.createLocal(repo: tree.path, branch: "feat/second", base: "main", path: linked)
        let found = WorktreeKit.list(repo: repo).contains { $0.branch == "feat/second" && $0.path == linked }
        XCTAssertTrue(found, "creation did not use preview path")
    }
}
