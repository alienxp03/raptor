import XCTest
import RaptorExecx
import RaptorWorktree
@testable import RaptorDispatch

/// setenv/unsetenv with recorded originals; mirrors Go's t.Setenv restore.
final class TestEnv {
    private var saved: [String: String?] = [:]

    private func record(_ name: String) {
        if saved[name] == nil {
            if let value = getenv(name) {
                saved[name] = .some(String(cString: value))
            } else {
                saved[name] = .some(nil)
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
    let dir = base + "/raptor-dispatch-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// t.Run-style labeled failure reporting for table-driven cases.
func subtest(_ label: String, _ body: () throws -> Void) {
    do {
        try body()
    } catch {
        XCTFail("\(label): \(error)")
    }
}

func writeExecutable(_ path: String, _ script: String) throws {
    try script.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
}

func readText(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

func countOccurrences(_ haystack: String, _ needle: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var range = haystack.startIndex..<haystack.endIndex
    while let found = haystack.range(of: needle, options: [], range: range) {
        count += 1
        range = found.upperBound..<haystack.endIndex
    }
    return count
}

func git(_ dir: String, _ args: [String]) throws {
    let r = try Execx.run(dir: dir, timeout: 120, name: "git", args: args)
    if r.code != 0 {
        throw MessageError("git \(args.joined(separator: " ")): \(r.stdout)\(r.stderr)")
    }
}
