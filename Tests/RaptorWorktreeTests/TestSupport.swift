import Foundation
import XCTest
@testable import RaptorWorktree

/// setenv/unsetenv with recorded originals; mirrors Go's t.Setenv restore.
final class TestEnv {
    private var saved: [String: String?] = [:]

    private func record(_ name: String) {
        if saved[name] == nil {
            if let value = getenv(name) {
                saved[name] = .some(String(cString: value))
            } else {
                saved[name] = .none
            }
        }
    }

    func set(_ name: String, _ value: String) {
        record(name)
        setenv(name, value, 1)
    }

    func unset(_ name: String) {
        record(name)
        unsetenv(name)
    }

    func get(_ name: String) -> String? {
        guard let value = getenv(name) else { return nil }
        return String(cString: value)
    }

    func restore() {
        for (name, value) in saved {
            if let value {
                setenv(name, value, 1)
            } else {
                unsetenv(name)
            }
        }
        saved = [:]
    }
}

func makeTempDir() throws -> String {
    var base = NSTemporaryDirectory()
    while base.hasSuffix("/") { base.removeLast() }
    let dir = base + "/raptor-wt-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// Isolates Worktrunk config from the host and gives the fixture repo a
/// deterministic path template. Returns the symlink-resolved root.
func isolateWT(_ env: TestEnv, root: String) throws -> String {
    let resolved = evalSymlinks(root) ?? root
    let empty = resolved + "/empty.toml"
    try "".write(toFile: empty, atomically: true, encoding: .utf8)
    env.set("WORKTRUNK_CONFIG_PATH", empty)
    env.set("WORKTRUNK_SYSTEM_CONFIG_PATH", empty)
    env.set("WORKTRUNK_PROJECT_CONFIG_PATH", resolved + "/no-project.toml")
    env.set("WORKTRUNK_WORKTREE_PATH", resolved + "/trees/{{ repo }}/{{ branch | sanitize }}")
    return resolved
}

/// Fresh single-commit git repo under an isolated Worktrunk environment.
func fixtureRepo(_ env: TestEnv) throws -> String {
    let root = try makeTempDir()
    try isolateWT(env, root: root)
    let dir = root + "/repo"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for args in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.com"],
                 ["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "initial"]] {
        _ = try WorktreeKit.gitOut(dir: dir, args: args)
    }
    return WorktreeKit.repoRoot(dir: dir)
}

func writeExecutable(_ path: String, script: String) throws {
    try script.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
}
