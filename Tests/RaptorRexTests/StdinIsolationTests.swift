import Foundation
import XCTest
@testable import RaptorRex

final class StdinIsolationTests: XCTestCase {
    // Checking fd 0 itself (not merely EOF) catches accidental inheritance even
    // when the test runner's stdin happens to be an empty pipe.
    private let probe = "[ /dev/fd/0 -ef /dev/null ] && printf isolated"

    func testRecencyCaptureUsesNullStdin() throws {
        let data = try XCTUnwrap(Rex.runCapture(timeout: 2, name: "/bin/sh", args: ["-c", probe]))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "isolated")
    }

    func testWatcherBoundedCaptureUsesNullStdin() throws {
        let watcher = EventWatcher(changes: ChangeChannel())
        defer { watcher.close() }
        let data = try XCTUnwrap(watcher.runBounded(name: "/bin/sh", args: ["-c", probe], timeout: 2, limit: 1024))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "isolated")
    }

    func testWatcherStreamUsesNullStdin() throws {
        let dir = testTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        prependPATH(dir)
        writeExecutable(dir + "/rex", contents: """
        #!/bin/sh
        [ /dev/fd/0 -ef /dev/null ] || exit 1
        printf '%s\\n' '{"type":"raptor_ready"}'
        """)
        let watcher = EventWatcher(changes: ChangeChannel())
        defer { watcher.close() }
        watcher.stream("")
        XCTAssertNotNil(watcher.changes.wait(timeout: 0.1), "stream did not see /dev/null on fd 0")
    }
}
