import Foundation
import RaptorExecx
import XCTest
@testable import RaptorWorktree

final class DeletionFingerprintTests: XCTestCase {
    func testIgnoredFilesAndSymlinksAreFingerprintedWithoutFollowingLinks() throws {
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
        try fm.createDirectory(atPath: external, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: modules, withIntermediateDirectories: true)
        try "outside".write(toFile: external + "/data", atomically: true, encoding: .utf8)
        try "/node_modules/\n".write(toFile: path + "/.gitignore", atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: modules + "/directory", withDestinationPath: external)
        try fm.createSymbolicLink(atPath: modules + "/file", withDestinationPath: external + "/data")
        try fm.createSymbolicLink(atPath: modules + "/broken", withDestinationPath: root + "/missing")
        let unusual = modules + "/odd\n'\"\\☃"
        try "one".write(toFile: unusual, atomically: true, encoding: .utf8)
        try "dash".write(toFile: path + "/-leading", atomically: true, encoding: .utf8)
        let longDirectory = modules + "/" + String(repeating: "long-", count: 40)
        try fm.createDirectory(atPath: longDirectory, withIntermediateDirectories: true)
        try "long name".write(toFile: longDirectory + "/file", atomically: true, encoding: .utf8)
        let run: DeletionCommand = { try Execx.run(dir: $0, timeout: 30, name: $1, args: $2) }
        let initial = try WorktreeKit.inspectDeletion(cwd: path, run: run)
        XCTAssertTrue(initial.needsForce)
        XCTAssertFalse(initial.fileHashes.isEmpty)
        XCTAssertLessThan(initial.status.utf8.count, 1024, "Ignored directories must stay compact for Rex transport")
        XCTAssertEqual(initial, try WorktreeKit.inspectDeletion(cwd: path, run: run), "An unchanged snapshot must be deterministic")
        try "external changes are not deleted by unlinking a symlink".write(toFile: external + "/data", atomically: true, encoding: .utf8)
        XCTAssertEqual(initial, try WorktreeKit.inspectDeletion(cwd: path, run: run), "Do not follow directory or file symlinks")
        try "different ignored content".write(toFile: unusual, atomically: true, encoding: .utf8)
        let changed = try WorktreeKit.inspectDeletion(cwd: path, run: run)
        XCTAssertEqual(initial.status, changed.status)
        XCTAssertNotEqual(initial.fileHashes, changed.fileHashes, "Compact status must not hide ignored content changes")
        try fm.removeItem(atPath: modules + "/broken")
        try fm.createSymbolicLink(atPath: modules + "/broken", withDestinationPath: root + "/another-missing")
        XCTAssertNotEqual(changed.fileHashes, try WorktreeKit.inspectDeletion(cwd: path, run: run).fileHashes,
                          "Broken symlink targets must be part of the fingerprint")

        for producer in ["git ls-files --others -z", "tar --no-xattrs --no-acls -cf - --null -T -"] {
            let failing: DeletionCommand = { dir, name, arguments in
                var args = arguments
                if name == "/bin/bash" {
                    args[args.count - 1] = args[args.count - 1].replacingOccurrences(of: producer, with: "false")
                }
                return try run(dir, name, args)
            }
            XCTAssertThrowsError(try WorktreeKit.inspectDeletion(cwd: path, run: failing), "Never hash a partial stream after a producer error")
        }
        let nested = path + "/nested-checkout"
        try fm.createDirectory(atPath: nested, withIntermediateDirectories: true)
        let initialized = try Execx.run(dir: nested, name: "git", args: ["init", "-b", "main"])
        XCTAssertTrue(initialized.ok, initialized.stderr)
        XCTAssertThrowsError(try WorktreeKit.inspectDeletion(cwd: path, run: run)) { error in
            XCTAssertTrue(String(describing: error).contains("nested Git metadata found"))
        }
    }
}
