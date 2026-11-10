import XCTest
@testable import RaptorRex

final class BlockContextTests: XCTestCase {
    func testReportedDirectory() {
        let cases: [(String, String)] = [
            ("/workspace/plain path", "/workspace/plain path"),
            ("file:///workspace/my%20project", "/workspace/my project"),
            ("file://macbook.local/workspace/my%23project", "/workspace/my#project"),
            ("file:///workspace/a+b", "/workspace/a+b"),
            ("file:///workspace/%ZZ", ""),
            ("file:relative", ""),
            ("file://macbook.local", ""),
            ("file:///workspace?query=yes", ""),
            ("file:///workspace#fragment", ""),
        ]
        for (input, want) in cases {
            XCTAssertEqual(Rex.reportedDirectory(input), want, "reportedDirectory(\(input))")
        }
    }

    func testBlockCwdUsesExplicitSession() throws {
        setenvTemp("REX_SESSION", "unrelated-session")
        let dir = testTempDir()
        prependPATH(dir)
        let script = """
        #!/bin/sh
        [ "$1" = do ] && [ "$2" = -s ] && [ "$3" = requested-session ] && [ "$4" = -b ] && [ "$5" = requested-pane ] || exit 1
        printf '%s\\n' /correct/repo
        """
        writeExecutable(dir + "/rex", contents: script)
        XCTAssertEqual(Rex.blockCwdInSession("requested-session", "requested-pane"), "/correct/repo")
    }

    func testBlockLookupsWithoutInheritedSession() throws {
        setenvTemp("REX_SESSION", "")
        setenvTemp("REX_BLOCK", "")
        let dir = testTempDir()
        let log = dir + "/calls"
        setenvTemp("REX_TEST_LOG", log)
        prependPATH(dir)
        let script = """
        #!/bin/sh
        # Native launches have no terminal environment. All lookups need explicit context.
        [ "$1" = do ] && [ "$2" = -b ] && [ "$3" = origin-pane ] && [ "$4" = -e ] || exit 1
        printf '%s\\n' call >> "$REX_TEST_LOG"
        case "$5" in
          *foreground.cwd*) printf '%s\\n' "${REX_TEST_PWD:-/source/repo}";;
          *r.pwd*) printf '%s\\n' "$REX_TEST_PWD";;
          *foreground.name*) printf '%s\\n' zsh;;
        esac
        """
        writeExecutable(dir + "/rex", contents: script)
        setenvTemp("REX_TEST_PWD", "file:///reported/repo")
        XCTAssertEqual(Rex.blockPwd("origin-pane"), "/reported/repo", "reported cwd")
        XCTAssertEqual(Rex.blockCwd("origin-pane"), "/reported/repo", "combined reported cwd")
        try? FileManager.default.removeItem(atPath: log)
        setenvTemp("REX_TEST_PWD", "")
        XCTAssertEqual(Rex.blockCwd("origin-pane"), "/source/repo", "foreground cwd fallback")
        let calls = readTextFile(log)
        XCTAssertEqual(countOccurrences(calls, "call"), 1, "cwd fallback must use one Rex invocation: \(calls)")
        XCTAssertEqual(Rex.blockForeground("origin-pane"), "zsh", "foreground process")
    }
}
