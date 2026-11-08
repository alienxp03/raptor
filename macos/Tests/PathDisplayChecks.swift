import Foundation

// Check failures must exit cleanly instead of trapping: a precondition trap
// makes macOS file a crash report for every headless assertion failure.
private func require(_ condition: Bool, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) {
    if !condition {
        testFailure(message.isEmpty ? "check failed at \(file):\(line)" : message)
    }
}

private func testFailure(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(2)
}

@main
struct PathDisplayChecks {
    static func main() {
        for (path, home, expected) in [
            ("/Users/demo", "/Users/demo", "~"),
            ("/Users/demo/Projects/example-kit", "/Users/demo", "~/Projects/example-kit"),
            ("/Users/demo/Projects/example-kit", "/Users/demo/", "~/Projects/example-kit"),
            ("/Users/demo-other/Projects/example-kit", "/Users/demo", "/Users/demo-other/Projects/example-kit"),
            ("/Users/another/Projects/example-kit", "/Users/demo", "/Users/another/Projects/example-kit"),
            ("/tmp/demo", "/Users/demo", "/tmp/demo"),
            ("~/Projects/example-kit", "/Users/demo", "~/Projects/example-kit"),
            ("/Users/旅行/Projects/例", "/Users/旅行", "~/Projects/例"),
            ("/tmp/demo", "/", "/tmp/demo"),
            ("/tmp/demo", "", "/tmp/demo"),
        ] {
            require(PathDisplay.abbreviate(path, home: home) == expected, "Unexpected path label: \(path)")
        }
        print("PASS: home-path labels, directory boundaries, other users, Unicode, unchanged absolute data")
    }
}
