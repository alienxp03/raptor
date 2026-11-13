import Foundation
import RaptorExecx
import XCTest
@testable import RaptorWorktree

func deletionWire(_ fields: [String]) -> String {
    fields.map { Data($0.utf8).base64EncodedString() }.joined(separator: "\n") + "\n"
}

final class DeletionFingerprintTests: XCTestCase {
    private func fields(reason: String? = "same_commit") throws -> [String] {
        var relation: [String: Any] = [:]
        if let reason { relation["integration"] = ["reason": reason] }
        let json: [String: Any] = ["schema": 2, "repo": ["default_branch": "main"], "items": [
            ["branch": "feature", "head": ["sha": "abc123"], "worktree": ["path": "/tree"],
             "default_branch": relation, "display": ["state": "ahead"]]
        ]]
        let listing = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        return ["/tree", "/repo/.git\n",
                "worktree /repo\0HEAD abc123\0branch refs/heads/main\0\0worktree /tree\0HEAD abc123\0branch refs/heads/feature\0\0",
                "refs/heads/feature\n", "abc123\n", "abc123 refs/heads/main\nabc123 refs/heads/feature\n",
                listing, "", ""]
    }

    func testOneCallAndIntegrationReasonsWithoutContentScans() throws {
        for reason in ["same_commit", "ancestor", "no_added_changes", "trees_match", "merge_adds_nothing", "patch_id_match"] {
            var snapshot = try fields(reason: reason)
            snapshot[7] = "!! node_modules/\0?? odd\n'name\0"
            var count = 0
            let plan = try WorktreeKit.inspectDeletion(cwd: "/tree/subdir") { dir, name, args in
                count += 1
                XCTAssertEqual(dir, "/tree/subdir")
                XCTAssertEqual(name, "/bin/bash")
                XCTAssertEqual(Array(args.prefix(3)), ["-o", "pipefail", "-c"])
                let script = try XCTUnwrap(args.last)
                for forbidden in ["git diff", "tar ", "sha256", "shasum", "git ls-files", "merge-base"] {
                    XCTAssertFalse(script.contains(forbidden), forbidden)
                }
                XCTAssertTrue(script.contains("cd -- \"$root\""))
                XCTAssertFalse(script.contains("--ignored"), "Ignored files must follow normal Git status semantics")
                return ExecResult(stdout: deletionWire(snapshot))
            }
            XCTAssertEqual(count, 1)
            XCTAssertFalse(plan.unmerged, reason)
            XCTAssertTrue(plan.needsForce)
            XCTAssertEqual(plan.status, snapshot[7])
            XCTAssertEqual(plan.diff, "")
            XCTAssertEqual(plan.fileHashes, "")
        }
        for reason in [nil, "unknown"] as [String?] {
            var snapshot = try fields(reason: reason)
            snapshot[6] = snapshot[6].replacingOccurrences(of: "ahead", with: "integrated")
            let plan = try WorktreeKit.inspectDeletion(cwd: "/tree") { _, _, _ in ExecResult(stdout: deletionWire(snapshot)) }
            XCTAssertTrue(plan.unmerged, "Display state is not evidence of integration")
        }
    }

    func testForceReasonsDistinguishIgnoredFilesFromChangesAndRenamePaths() throws {
        let cases: [(String, Bool, Bool)] = [
            ("", false, false),
            ("!! node_modules/\0", false, true),
            ("?? new-file\0", true, false),
            (" M tracked-file\0", true, false),
            ("!! build/\0 M tracked-file\0", true, true),
            ("R  renamed-file\0!! old-name\0", true, false),
            ("C  copied-file\0!! source-name\0!! ignored/\0", true, true),
        ]
        for (status, changes, ignored) in cases {
            var snapshot = try fields()
            snapshot[7] = status
            let plan = try WorktreeKit.inspectDeletion(cwd: "/tree") { _, _, _ in ExecResult(stdout: deletionWire(snapshot)) }
            XCTAssertEqual(plan.hasChanges, changes, status)
            XCTAssertEqual(plan.hasIgnoredFiles, ignored, status)
            XCTAssertEqual(plan.needsForce, changes)
        }
    }

    func testMalformedIncompleteAndFailedSnapshotsAreRejected() throws {
        let valid = try fields()
        for output in ["", deletionWire(Array(valid.dropLast())), deletionWire(valid) + "\n",
                       deletionWire(valid).replacingOccurrences(of: "L3RyZWU=", with: "%%%"),
                       String(deletionWire(valid).dropLast())] {
            XCTAssertThrowsError(try WorktreeKit.inspectDeletion(cwd: "/tree") { _, _, _ in ExecResult(stdout: output) })
        }
        XCTAssertThrowsError(try WorktreeKit.inspectDeletion(cwd: "/tree") { _, _, _ in
            ExecResult(stdout: deletionWire(valid), stderr: "producer failed", code: 1)
        })
        for index in [2, 3, 4, 5, 6, 8] {
            var invalid = valid
            invalid[index] = index == 8 ? "./nested/.git\n" : "invalid"
            XCTAssertThrowsError(try WorktreeKit.inspectDeletion(cwd: "/tree") { _, _, _ in ExecResult(stdout: deletionWire(invalid)) })
        }
        for old in ["/tree", "feature", "abc123"] {
            var invalid = valid
            invalid[6] = invalid[6].replacingOccurrences(of: old, with: "different")
            XCTAssertThrowsError(try WorktreeKit.inspectDeletion(cwd: "/tree") { _, _, _ in ExecResult(stdout: deletionWire(invalid)) })
        }
    }

    func testUnsafeRegistrationAndBranchStatesAreRejected() throws {
        let original = try fields()
        let target = "worktree /tree\0HEAD abc123\0branch refs/heads/feature\0\0"
        let invalidRecords = [
            target.replacingOccurrences(of: "\0\0", with: "\0locked\0\0"),
            target.replacingOccurrences(of: "\0\0", with: "\0prunable missing directory\0\0"),
            target + target,
            target + "worktree /other\0HEAD abc123\0branch refs/heads/feature\0\0",
            target.replacingOccurrences(of: "branch refs/heads/feature", with: "detached"),
            target.replacingOccurrences(of: "HEAD abc123", with: "HEAD other")
        ]
        for record in invalidRecords {
            var snapshot = original
            snapshot[2] = snapshot[2].replacingOccurrences(of: target, with: record)
            XCTAssertThrowsError(try WorktreeKit.inspectDeletion(cwd: "/tree") { _, _, _ in ExecResult(stdout: deletionWire(snapshot)) })
        }
    }

    func testStatusAndHeadChangesInvalidateFinalValidation() throws {
        let original = try fields()
        let plan = try WorktreeKit.inspectDeletion(cwd: "/tree") { _, _, _ in ExecResult(stdout: deletionWire(original)) }
        for index in [2, 4, 7] {
            var changed = original
            changed[index] += "changed"
            var count = 0
            let outcome = WorktreeKit.executeDeletion(plan, force: true) { _, name, _ in
                count += 1
                XCTAssertEqual(name, "/bin/bash")
                return ExecResult(stdout: deletionWire(changed))
            }
            XCTAssertFalse(outcome.worktreeRemoved)
            XCTAssertEqual(count, 1)
        }
    }

    func testIgnoredFilesAndSymlinksAreNotReadAndNestedGitIsProtected() throws {
        let env = TestEnv()
        defer { env.restore() }
        let root = FileManager.default.currentDirectoryPath + "/aux/delete-links-" + UUID().uuidString
        let fm = FileManager.default
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        _ = try isolateWT(env, root: root)
        let repo = root + "/repo"
        try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func git(_ args: [String]) throws {
            let result = try Execx.run(dir: repo, name: "git", args: args)
            XCTAssertTrue(result.ok, result.stderr)
        }
        try git(["init", "-b", "main"])
        try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "-c", "commit.gpgsign=false",
                 "commit", "--allow-empty", "-m", "fixture"])
        let created = WorktreeKit.switchWorktree(repo: repo, args: ["--create", "feat/symlinks"])
        XCTAssertNil(created.error)
        let path = created.tree.path
        let external = root + "/external"
        let modules = path + "/node_modules"
        try fm.createDirectory(atPath: external + "/.git", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: modules, withIntermediateDirectories: true)
        try "/node_modules/\n".write(toFile: path + "/.gitignore", atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: modules + "/directory", withDestinationPath: external)
        try fm.createSymbolicLink(atPath: modules + "/broken", withDestinationPath: root + "/missing")
        let unusual = modules + "/odd\n'\"\\☃"
        try "one".write(toFile: unusual, atomically: true, encoding: .utf8)
        // A FIFO would block a content reader. Inspection must only list names.
        let fifo = try Execx.run(dir: path, name: "mkfifo", args: [modules + "/pipe"])
        XCTAssertTrue(fifo.ok, fifo.stderr)
        let run: DeletionCommand = { try Execx.run(dir: $0, timeout: 10, name: $1, args: $2) }
        let initial = try WorktreeKit.inspectDeletion(cwd: path, run: run)
        XCTAssertTrue(initial.needsForce)
        XCTAssertTrue(initial.fileHashes.isEmpty)
        XCTAssertLessThan(initial.status.utf8.count, 1024)
        try "different ignored content".write(toFile: unusual, atomically: true, encoding: .utf8)
        XCTAssertEqual(initial, try WorktreeKit.inspectDeletion(cwd: path, run: run))
        // Follow no links, but reject a nested .git directory, file, or symlink.
        let nested = modules + "/nested"
        try fm.createDirectory(atPath: nested, withIntermediateDirectories: true)
        for kind in ["directory", "file", "symlink"] {
            let metadata = nested + "/.git"
            if kind == "directory" { try fm.createDirectory(atPath: metadata, withIntermediateDirectories: true) }
            if kind == "file" { try "gitdir: elsewhere".write(toFile: metadata, atomically: true, encoding: .utf8) }
            if kind == "symlink" { try fm.createSymbolicLink(atPath: metadata, withDestinationPath: external) }
            XCTAssertThrowsError(try WorktreeKit.inspectDeletion(cwd: path, run: run)) { error in
                XCTAssertTrue(String(describing: error).contains("nested Git metadata found"))
            }
            try fm.removeItem(atPath: metadata)
        }
        // pipefail must preserve an error from any snapshot producer.
        for producer in ["git worktree list --porcelain -z", "git status --porcelain=v1", "find ."] {
            XCTAssertThrowsError(try WorktreeKit.inspectDeletion(cwd: path) { dir, name, args in
                var failing = args
                failing[failing.count - 1] = failing.last!.replacingOccurrences(of: producer, with: "false")
                return try run(dir, name, failing)
            })
        }
    }
}
