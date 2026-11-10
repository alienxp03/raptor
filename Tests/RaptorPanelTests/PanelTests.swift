import XCTest
@testable import RaptorPanel

final class PanelTests: XCTestCase {
    private func tempDir() -> String {
        NSTemporaryDirectory() + "raptor-panel-\(UUID().uuidString)"
    }

    /// Go omitempty: empty fields stay off the wire; action is always present
    /// and defaults to "open".
    func testRequestEncodingOmitsEmptyFields() throws {
        let wire = String(data: try JSONEncoder().encode(Request(action: "open", session: "s1", title: "Bug")), encoding: .utf8)!
        XCTAssertTrue(wire.contains("\"action\":\"open\""), wire)
        XCTAssertTrue(wire.contains("\"session\":\"s1\""), wire)
        XCTAssertTrue(wire.contains("\"title\":\"Bug\""), wire)
        for absent in ["mode", "block", "client", "repo"] {
            XCTAssertFalse(wire.contains("\"\(absent)\""), "empty \(absent) must be omitted: \(wire)")
        }
        let all = String(data: try JSONEncoder().encode(Request(action: "ping", mode: "split", session: "s", block: "b", client: "c", title: "t", repo: "r")), encoding: .utf8)!
        for key in ["action", "mode", "session", "block", "client", "title", "repo"] {
            XCTAssertTrue(all.contains("\"\(key)\":"), all)
        }
    }

    func testReplyRoundTrip() throws {
        let failing = try JSONDecoder().decode(Reply.self, from: Data("{\"ok\":false,\"error\":\"boom\"}".utf8))
        XCTAssertEqual(failing, Reply(ok: false, error: "boom"))
        let ok = try JSONDecoder().decode(Reply.self, from: Data("{\"ok\":true}".utf8))
        XCTAssertEqual(ok, Reply(ok: true, error: ""))
        let encoded = String(data: try JSONEncoder().encode(ok), encoding: .utf8)!
        XCTAssertEqual(encoded, "{\"ok\":true}")
    }

    /// No resident host: call fails with the sentinel, like Go.
    func testCallUnavailableWhenSocketMissing() {
        setenv("XDG_CACHE_HOME", tempDir(), 1)
        defer { unsetenv("XDG_CACHE_HOME") }
        XCTAssertThrowsError(try Panel.call(Request(action: "ping"))) { error in
            XCTAssertTrue(error is UnavailableError, "\(error)")
            XCTAssertEqual("\(error)", "panel host is not running")
        }
    }
}
