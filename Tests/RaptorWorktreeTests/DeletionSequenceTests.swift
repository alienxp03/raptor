import Foundation
import RaptorExecx
import XCTest
@testable import RaptorWorktree

final class DeletionSequenceTests: XCTestCase {
    func testSequentialRemovalChangesOnlyExpectedRegistrationAndKeepsRemoteRefs() throws {
        let env = TestEnv()
        defer { env.restore() }
        let root = FileManager.default.currentDirectoryPath + "/aux/delete-sequence-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        _ = try isolateWT(env, root: root)
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func git(_ args: [String]) throws -> String {
            let result = try Execx.run(dir: repo, name: "git", args: args)
            XCTAssertTrue(result.ok, result.stderr)
            return result.stdout.trimmingCharacters(in: .newlines)
        }
        _ = try git(["init", "-b", "main"])
        _ = try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "-c", "commit.gpgsign=false",
                     "commit", "--allow-empty", "-m", "fixture"])
        let first = WorktreeKit.switchWorktree(repo: repo, args: ["--create", "feat/first"])
        let second = WorktreeKit.switchWorktree(repo: repo, args: ["--create", "feat/second"])
        XCTAssertNil(first.error)
        XCTAssertNil(second.error)
        let head = try git(["rev-parse", "HEAD"])
        _ = try git(["update-ref", "refs/remotes/origin/feat/first", head])
        _ = try git(["update-ref", "refs/remotes/origin/feat/second", head])
        let run: DeletionCommand = { try Execx.run(dir: $0, timeout: 30, name: $1, args: $2) }
        let a = try WorktreeKit.inspectDeletion(cwd: first.tree.path, run: run)
        let b = try WorktreeKit.inspectDeletion(cwd: second.tree.path, run: run)
        XCTAssertEqual(b.accountingForDeletedWorktrees([]), b)
        XCTAssertEqual(b.accountingForDeletedWorktrees([a.path + "/subdir"]), b)
        let deleted = WorktreeKit.executeDeletion(a, force: false, run: run)
        XCTAssertTrue(deleted.worktreeRemoved, deleted.error ?? "")
        XCTAssertTrue(deleted.branchRemoved, deleted.error ?? "")
        let fresh = try WorktreeKit.inspectDeletion(cwd: b.path, run: run)
        XCTAssertNotEqual(fresh, b)
        XCTAssertEqual(fresh, b.accountingForDeletedWorktrees([a.path]))
        // A different registration change must still fail closed.
        _ = try git(["worktree", "lock", b.path])
        let refused = WorktreeKit.executeDeletion(b.accountingForDeletedWorktrees([a.path]), force: false, run: run)
        XCTAssertFalse(refused.worktreeRemoved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
        _ = try git(["worktree", "unlock", b.path])
        let last = WorktreeKit.executeDeletion(b.accountingForDeletedWorktrees([a.path]), force: false, run: run)
        XCTAssertTrue(last.worktreeRemoved, last.error ?? "")
        XCTAssertTrue(last.branchRemoved, last.error ?? "")
        XCTAssertEqual(try git(["rev-parse", "refs/remotes/origin/feat/first"]), head)
        XCTAssertEqual(try git(["rev-parse", "refs/remotes/origin/feat/second"]), head)
    }
}
