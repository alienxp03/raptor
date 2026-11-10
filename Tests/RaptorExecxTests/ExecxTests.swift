import XCTest
@testable import RaptorExecx

final class ExecxTests: XCTestCase {
    func testCapturesStreamsAndCode() throws {
        let r = try Execx.run(name: "/bin/sh", args: ["-c", "echo out; echo err >&2; exit 3"])
        XCTAssertEqual(r.stdout, "out\n")
        XCTAssertEqual(r.stderr, "err\n")
        XCTAssertEqual(r.code, 3)
        XCTAssertFalse(r.ok)
    }

    func testWorkingDirectory() throws {
        let r = try Execx.run(dir: "/tmp", name: "/bin/pwd")
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "/private/tmp".replacingOccurrences(of: "/private", with: r.stdout.contains("/private") ? "/private" : ""))
    }

    func testTimeoutKillsAndKeepsOutput() throws {
        var thrown: ExecxError?
        do {
            _ = try Execx.run(timeout: 0.3, name: "/bin/sh", args: ["-c", "echo partial; sleep 30"])
        } catch let e as ExecxError {
            thrown = e
        }
        let e = try XCTUnwrap(thrown)
        XCTAssertEqual(e.result.stdout, "partial\n")
        XCTAssertEqual(e.result.stderr, "timed out")
        XCTAssertTrue(e.message.contains("timed out"))
    }

    func testLookupResolvesPath() throws {
        XCTAssertNotNil(Execx.lookup(name: "sh"))
        XCTAssertNil(Execx.lookup(name: "definitely-not-a-real-command"))
        _ = try Execx.run(name: "echo", args: ["via-path"])
    }
}
