import Foundation
import RaptorExecx
import XCTest
@testable import RaptorWorktree

final class DeletionTests: XCTestCase {
    func testPrimaryWorktreeErrorUsesItsActualBranch() throws {
        for branch in ["master", "main", "feat/custom-primary", ""] {
            let record = branch.isEmpty ? "detached" : "branch refs/heads/" + branch
            let run: DeletionCommand = { _, name, args in
                XCTAssertEqual(name, "/bin/bash")
                XCTAssertEqual(Array(args.prefix(3)), ["-o", "pipefail", "-c"])
                return ExecResult(stdout: deletionWire(["/repo", "/repo/.git\n",
                    "worktree /repo\0HEAD abc123\0\(record)\0\0", "", "abc123\n", "", "{}", "", ""]))
            }
            XCTAssertThrowsError(try WorktreeKit.inspectDeletion(cwd: "/repo", run: run)) { error in
                let expected = branch.isEmpty
                    ? "Cannot delete the primary worktree (detached HEAD)."
                    : "Cannot delete branch `\(branch)`."
                XCTAssertEqual(String(describing: error), expected)
            }
        }
    }

    func testSquashAndRebasedCommitsAreIntegratedEvenWhenDirty() throws {
        let env = TestEnv()
        defer { env.restore() }
        let root = FileManager.default.currentDirectoryPath + "/aux/delete-integration-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        _ = try isolateWT(env, root: root)
        for mode in ["squash", "rebase"] {
            let repo = root + "/" + mode
            try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
            func git(_ args: [String], at directory: String? = nil) throws -> String {
                let result = try Execx.run(dir: directory ?? repo, name: "git", args: args)
                XCTAssertTrue(result.ok, result.stderr)
                return result.stdout.trimmingCharacters(in: .newlines)
            }
            _ = try git(["init", "-b", "main"])
            _ = try git(["config", "user.name", "Fixture"])
            _ = try git(["config", "user.email", "fixture@example.com"])
            _ = try git(["config", "commit.gpgsign", "false"])
            _ = try git(["commit", "--allow-empty", "-m", "initial"])
            let created = WorktreeKit.switchWorktree(repo: repo, args: ["--create", "feat/integrated"])
            XCTAssertNil(created.error)
            let path = created.tree.path
            try "feature".write(toFile: path + "/feature", atomically: true, encoding: .utf8)
            _ = try git(["add", "feature"], at: path)
            _ = try git(["commit", "-m", "feature"], at: path)
            let head = try git(["rev-parse", "HEAD"], at: path)
            try "main advanced".write(toFile: repo + "/other", atomically: true, encoding: .utf8)
            _ = try git(["add", "other"])
            _ = try git(["commit", "-m", "advance main"])
            if mode == "squash" {
                _ = try git(["merge", "--squash", "feat/integrated"])
                _ = try git(["commit", "-m", "squashed feature"])
            } else {
                // Replay on the advanced base, as a rebase-and-merge does.
                _ = try git(["cherry-pick", head])
            }
            let ancestor = try Execx.run(dir: repo, name: "git", args: ["merge-base", "--is-ancestor", head, "main"])
            XCTAssertEqual(ancestor.code, 1)
            try "dirty but integrated".write(toFile: path + "/feature", atomically: true, encoding: .utf8)
            let plan = try WorktreeKit.inspectDeletion(cwd: path) { try Execx.run(dir: $0, timeout: 30, name: $1, args: $2) }
            XCTAssertFalse(plan.unmerged, mode)
            XCTAssertFalse(plan.status.isEmpty)
            XCTAssertTrue(plan.needsForce, "Dirty status still requires Force")
        }
    }

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
        XCTAssertThrowsError(try WorktreeKit.inspectDeletion(cwd: repo, run: run)) { error in
            XCTAssertEqual(String(describing: error), "Cannot delete branch `main`.")
        }
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
        XCTAssertEqual(plan, try WorktreeKit.inspectDeletion(cwd: path, run: run), "Same-status content changes are not scanned")
        try "new status entry".write(toFile: path + "/another", atomically: true, encoding: .utf8)
        XCTAssertNotEqual(plan, try WorktreeKit.inspectDeletion(cwd: path, run: run))
        _ = try git(["add", "dirty"], at: path)
        _ = try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "-c", "commit.gpgsign=false",
                     "commit", "-m", "unmerged fixture"], at: path)
        let stale = WorktreeKit.executeDeletion(plan, force: true, run: run)
        XCTAssertFalse(stale.worktreeRemoved, "HEAD/status changes must block stale Force plans")
        XCTAssertTrue(stale.error?.contains("validation failed") == true)
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
        // Ignored dependencies do not make a worktree dirty or require Force.
        let modules = clean.tree.path + "/node_modules"
        try FileManager.default.createDirectory(atPath: modules, withIntermediateDirectories: true)
        try "cache".write(toFile: modules + "/cache", atomically: true, encoding: .utf8)
        try "/node_modules/\n".write(toFile: repo + "/.git/info/exclude", atomically: true, encoding: .utf8)
        XCTAssertEqual(try git(["status", "--porcelain"], at: clean.tree.path), "")
        let cleanPlan = try WorktreeKit.inspectDeletion(cwd: clean.tree.path, run: run)
        XCTAssertTrue(cleanPlan.status.isEmpty)
        XCTAssertFalse(cleanPlan.hasChanges)
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
