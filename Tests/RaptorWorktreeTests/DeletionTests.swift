import Foundation
import RaptorExecx
import XCTest
@testable import RaptorWorktree

final class DeletionTests: XCTestCase {
    func testFixtureRemovalAndForceNeverDeleteRemoteRefs() throws {
        let env = TestEnv()
        defer { env.restore() }
        let root = FileManager.default.currentDirectoryPath + "/aux/delete-fixture-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        _ = try isolateWT(env, root: root)
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func git(_ args: [String], at dir: String? = nil) throws -> String {
            let r = try Execx.run(dir: dir ?? repo, name: "git", args: args)
            XCTAssertEqual(r.code, 0, r.stderr)
            return r.stdout.trimmingCharacters(in: .newlines)
        }
        _ = try git(["init", "-b", "main"])
        _ = try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "-c", "commit.gpgsign=false",
                     "commit", "--allow-empty", "-m", "fixture"])
        let created = WorktreeKit.switchWorktree(repo: repo, args: ["--create", "feat/delete-fixture"])
        XCTAssertNil(created.error)
        let path = created.tree.path
        XCTAssertFalse(path.isEmpty)
        var calls: [(String, [String])] = []
        let run: DeletionCommand = { dir, name, args in
            calls.append((name, args))
            return try Execx.run(dir: dir, timeout: 30, name: name, args: args)
        }
        XCTAssertThrowsError(try WorktreeKit.inspectDeletion(cwd: repo, run: run))
        let head = try git(["rev-parse", "HEAD"])
        _ = try git(["update-ref", "refs/remotes/origin/feat/delete-fixture", head])
        try "keep me".write(toFile: path + "/dirty", atomically: true, encoding: .utf8)
        try "odd filename".write(toFile: path + "/odd\n'name", atomically: true, encoding: .utf8)
        var plan = try WorktreeKit.inspectDeletion(cwd: path, run: run)
        XCTAssertTrue(plan.needsForce)
        let refused = WorktreeKit.executeDeletion(plan, force: false, run: run)
        XCTAssertFalse(refused.worktreeRemoved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/dirty"))
        try "changed content".write(toFile: path + "/dirty", atomically: true, encoding: .utf8)
        XCTAssertNotEqual(plan, try WorktreeKit.inspectDeletion(cwd: path, run: run))
        _ = try git(["add", "dirty"], at: path)
        _ = try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "-c", "commit.gpgsign=false",
                     "commit", "-m", "unmerged fixture"], at: path)
        plan = try WorktreeKit.inspectDeletion(cwd: path, run: run)
        XCTAssertTrue(plan.unmerged)
        XCTAssertFalse(WorktreeKit.executeDeletion(plan, force: false, run: run).worktreeRemoved)
        let removed = WorktreeKit.executeDeletion(plan, force: true, run: run)
        XCTAssertTrue(removed.worktreeRemoved, removed.error ?? "")
        XCTAssertTrue(removed.branchRemoved, removed.error ?? "")
        XCTAssertNil(removed.error)
        XCTAssertEqual(try git(["rev-parse", "refs/remotes/origin/feat/delete-fixture"]), head)
        let removals = calls.filter { $0.0 == "wt" && $0.1.first == "remove" }
        XCTAssertEqual(removals.count, 1)
        for flag in ["--foreground", "--format=json", "--no-hooks", "--yes", "--force", "--force-delete"] {
            XCTAssertTrue(removals[0].1.contains(flag))
        }
        XCTAssertFalse(calls.contains { $0.1.contains("push") || $0.1.contains("branch") || $0.1.contains("rm") })
        let clean = WorktreeKit.switchWorktree(repo: repo, args: ["--create", "feat/delete-clean"])
        XCTAssertNil(clean.error)
        let cleanPlan = try WorktreeKit.inspectDeletion(cwd: clean.tree.path, run: run)
        XCTAssertFalse(cleanPlan.needsForce)
        let normal = WorktreeKit.executeDeletion(cleanPlan, force: false, run: run)
        XCTAssertNil(normal.error)
        XCTAssertTrue(normal.worktreeRemoved)
        XCTAssertTrue(normal.branchRemoved)
        let last = try XCTUnwrap(calls.last { $0.0 == "wt" && $0.1.first == "remove" })
        XCTAssertFalse(last.1.contains("--force"))
        XCTAssertFalse(last.1.contains("--force-delete"))
    }
}
