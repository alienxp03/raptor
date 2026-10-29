import Foundation

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
            precondition(PathDisplay.abbreviate(path, home: home) == expected, "Unexpected path label: \(path)")
        }
        print("PASS: home-path labels, directory boundaries, other users, Unicode, unchanged absolute data")
    }
}
