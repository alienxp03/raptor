import XCTest
import RaptorConfig
import RaptorExecx
@testable import RaptorWorktree

/// Ported from internal/worktree/wt_test.go.
final class WtTests: XCTestCase {
    func testPreviewConfiguredPathAndErrors() throws {
        let env = TestEnv()
        defer { env.restore() }
        let repo = try fixtureRepo(env)
        let configured = pathJoin([dirOf(repo), "configured paths", "{{ branch }}"])
        env.set("WORKTRUNK_WORKTREE_PATH", configured)
        let path = try WorktreeKit.previewPath(repo: repo, branch: "feat/login")
        let want = pathJoin([dirOf(repo), "configured paths", "feat", "login"])
        XCTAssertEqual(path, want, "preview: \(path), want \(want)")
        let compat = WorktreeKit.path(repo: repo, branch: "feat/login", cfg: RaptorConfig(worktreeRoot: "/ignored"))
        XCTAssertEqual(compat, want)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirOf(want)), "preview created directories")
        env.set("WORKTRUNK_WORKTREE_PATH", "{{ missing_variable }}")
        XCTAssertThrowsError(try WorktreeKit.previewPath(repo: repo, branch: "feat/login"), "preview error hidden")
        XCTAssertThrowsError(try WorktreeKit.validate(repo: repo, branch: "feat/login", base: "main", path: ""),
                             "validation error hidden")
        XCTAssertThrowsError(try WorktreeKit.createLocal(repo: repo, branch: "feat/login", base: "main", path: ""),
                             "creation error hidden")
    }

    func testSwitchKeepsExistingAndDefersHooks() throws {
        let env = TestEnv()
        defer { env.restore() }
        let repo = try fixtureRepo(env)
        let hook = pathJoin([dirOf(repo), "hook-ran"])
        let project = repo + "/project.toml"
        try "pre-start = 'touch \(hook)'\npost-start = 'touch \(hook)'\n"
            .write(toFile: project, atomically: true, encoding: .utf8)
        env.set("WORKTRUNK_PROJECT_CONFIG_PATH", project)
        let outcome = WorktreeKit.switchWorktree(repo: repo, args: ["--create", "feat/login", "--base", "main"])
        XCTAssertNil(outcome.error, String(describing: outcome.error))
        XCTAssertTrue(outcome.created)
        XCTAssertEqual(outcome.tree.branch, "feat/login")
        let tree = outcome.tree
        XCTAssertFalse(FileManager.default.fileExists(atPath: hook), "creation ran hooks")
        try "keep".write(toFile: tree.path + "/dirty", atomically: true, encoding: .utf8)
        // Changing the configured path must not relocate an existing worktree.
        env.set("WORKTRUNK_WORKTREE_PATH", pathJoin([dirOf(repo), "elsewhere", "{{ branch | sanitize }}"]))
        let path = try WorktreeKit.previewPath(repo: repo, branch: "feat/login")
        XCTAssertEqual(path, tree.path, "existing preview: \(path)")
        let reuse = WorktreeKit.switchWorktree(repo: repo, args: ["feat/login"])
        XCTAssertNil(reuse.error, String(describing: reuse.error))
        XCTAssertFalse(reuse.created)
        XCTAssertEqual(reuse.tree, tree)
        let data = try String(contentsOfFile: tree.path + "/dirty", encoding: .utf8)
        XCTAssertEqual(data, "keep", "existing changes lost")
    }

    func testSwitchPRPartialFailure() throws {
        let env = TestEnv()
        defer { env.restore() }
        let repo = try fixtureRepo(env)
        let realWT = try XCTUnwrap(Execx.lookup(name: "wt"))
        let bin = dirOf(repo) + "/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        // Simulate failure after wt has registered the PR worktree, without stdout.
        let script = "#!/bin/sh\n"
            + "[ \"$1\" = switch ] && [ \"$2\" = --no-hooks ] && [ \"$3\" = --no-cd ] && [ \"$4\" = --format=json ] && [ \"$5\" = https://github.com/owner/repo/pull/1 ] && [ \"$#\" = 5 ] || exit 99\n"
            + "\"\(realWT)\" switch --no-hooks --no-cd --format=json --create feat/pr --base main >/dev/null\n"
            + "echo after-create-failure >&2\n"
            + "exit 7\n"
        try writeExecutable(bin + "/wt", script: script)
        env.set("PATH", bin + ":" + (env.get("PATH") ?? ""))
        var error: SwitchError?
        do {
            _ = try WorktreeKit.switchPR(repo: repo, url: "https://github.com/owner/repo/pull/1")
        } catch let e as SwitchError {
            error = e
        }
        let failure = try XCTUnwrap(error)
        XCTAssertTrue(failure.created)
        XCTAssertEqual(failure.tree.branch, "feat/pr")
        XCTAssertTrue(String(describing: failure).contains("after-create-failure"), String(describing: failure))
    }
}
