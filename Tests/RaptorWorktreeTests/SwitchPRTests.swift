import XCTest
import RaptorExecx
@testable import RaptorWorktree

/// Ported from internal/worktree/switch_pr_test.go.
final class SwitchPRTests: XCTestCase {
    func testSwitchPRReconcilesRegistration() throws {
        for kind in ["created", "existing", "malformed", "failure"] {
            let env = TestEnv()
            defer { env.restore() }
            let repo = try fixtureRepo(env)
            let realWT = try XCTUnwrap(Execx.lookup(name: "wt"), kind)
            if kind == "existing" {
                let pre = WorktreeKit.switchWorktree(repo: repo, args: ["--create", "fork/topic", "--base", "main"])
                XCTAssertNil(pre.error, "\(kind): \(String(describing: pre.error))")
            } else {
                _ = try WorktreeKit.gitOut(dir: repo, args: ["branch", "fork/topic"])
            }
            let bin = dirOf(repo) + "/bin"
            try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
            var script = "#!/bin/sh\n\"\(realWT)\" switch --no-hooks --no-cd --format=json fork/topic\n"
            if kind == "malformed" {
                script = "#!/bin/sh\n\"\(realWT)\" switch --no-hooks --no-cd --format=json fork/topic >/dev/null\necho invalid-json\n"
            }
            if kind == "failure" {
                script = "#!/bin/sh\necho unavailable >&2\nexit 7\n"
            }
            try writeExecutable(bin + "/wt", script: script)
            env.set("PATH", bin + ":" + (env.get("PATH") ?? ""))
            var tree = Worktree()
            var created = false
            var err: (any Error)?
            do {
                let result = try WorktreeKit.switchPR(repo: repo, url: "https://github.com/owner/repo/pull/1")
                tree = result.tree
                created = result.created
            } catch let e as SwitchError {
                tree = e.tree
                created = e.created
                err = e
            }
            if kind == "failure" {
                XCTAssertEqual(tree.path, "", "\(kind)")
                XCTAssertFalse(created, kind)
                XCTAssertNotNil(err, kind)
                XCTAssertEqual(WorktreeKit.list(repo: repo).count, 1, kind)
                continue
            }
            XCTAssertNotEqual(tree.path, "", kind)
            XCTAssertEqual(tree.branch, "fork/topic", kind)
            XCTAssertEqual(created, kind != "existing", kind)
            if (err != nil) != (kind == "malformed") {
                XCTFail("\(kind): unexpected error: \(String(describing: err))")
            }
        }
    }
}
