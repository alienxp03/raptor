import Foundation
import XCTest
@testable import RaptorCatalog

// Shared helpers mirroring the Go test utilities (t.TempDir, t.Setenv,
// os.WriteFile, os.Symlink, isolateWorktrunk from wt_test.go).

func catalogTempDir() -> String {
    let dir = NSTemporaryDirectory() + "raptor-catalog-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

func getEnvValue(_ key: String) -> String? {
    getenv(key).map { String(cString: $0) }
}

func setEnvValue(_ key: String, _ value: String?) {
    if let value {
        setenv(key, value, 1)
    } else {
        unsetenv(key)
    }
}

extension XCTestCase {
    /// t.Setenv: sets the variable and restores the previous value at teardown.
    func setenvTemp(_ key: String, _ value: String?) {
        let old = getEnvValue(key)
        setEnvValue(key, value)
        addTeardownBlock { setEnvValue(key, old) }
    }

    /// t.TempDir.
    func testTempDir() -> String {
        catalogTempDir()
    }

    func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    }

    /// isolateWorktrunk from wt_test.go.
    func isolateWorktrunk() {
        let root = testTempDir()
        let empty = root + "/empty.toml"
        FileManager.default.createFile(atPath: empty, contents: nil, attributes: [.posixPermissions: 0o600])
        setenvTemp("WORKTRUNK_CONFIG_PATH", empty)
        setenvTemp("WORKTRUNK_SYSTEM_CONFIG_PATH", empty)
        setenvTemp("WORKTRUNK_PROJECT_CONFIG_PATH", empty)
        setenvTemp("WORKTRUNK_WORKTREE_PATH", root + "/trees/{{ repo }}/{{ branch | sanitize }}")
    }

    func testRecentSessionID(_ n: Int) -> String {
        String(format: "session:00000000-0000-4000-8000-%012d", n)
    }
}
