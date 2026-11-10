import XCTest
@testable import RaptorLauncherupdate

final class LauncherupdateTests: XCTestCase {
    private func tempDir() -> String {
        NSTemporaryDirectory() + "raptor-launcherupdate-\(UUID().uuidString)"
    }

    func testSinceFencesByScanStart() {
        setenv("XDG_CACHE_HOME", tempDir(), 1)
        defer { unsetenv("XDG_CACHE_HOME") }
        Launcherupdate.record(Session(id: "new-session", label: "new-worktree", host: "This Mac", local: true, path: "/wt/new"))
        let after = Date()
        let entries = Launcherupdate.since(after.addingTimeInterval(-60))
        guard entries.count == 1, entries[0].id == "new-session", entries[0].label == "new-worktree" else {
            return XCTFail("pre-creation scan must see the creation: \(entries)")
        }
        XCTAssertEqual(Launcherupdate.since(after).count, 0, "a scan started after the creation is authoritative")
        // A second reader (new resident process) sees the same disk journal.
        XCTAssertEqual(Launcherupdate.since(Date(timeIntervalSince1970: 0)).count, 1, "cross-process read lost the creation")
    }

    func testRecordIgnoresIncompleteIdentity() {
        setenv("XDG_CACHE_HOME", tempDir(), 1)
        defer { unsetenv("XDG_CACHE_HOME") }
        Launcherupdate.record(Session(id: "", label: "guess"))
        Launcherupdate.record(Session(id: "sid", label: ""))
        XCTAssertEqual(Launcherupdate.since(Date(timeIntervalSince1970: 0)).count, 0, "incomplete identities must not be recorded")
    }

    func testSinceExpiresOldCreations() throws {
        let cache = tempDir()
        setenv("XDG_CACHE_HOME", cache, 1)
        defer { unsetenv("XDG_CACHE_HOME") }
        let dir = cache + "/raptor/launcher-creations"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let stale = "{\"id\":\"old\",\"label\":\"old\",\"created\":\"2020-01-01T00:00:00Z\"}"
        try stale.write(toFile: dir + "/expired.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(Launcherupdate.since(Date(timeIntervalSince1970: 0)).count, 0, "expired creations must not surface")
    }

    /// Round-trips through the on-disk JSON shape (RFC3339 created) exactly as
    /// Go's encoding does.
    func testSessionJSONRoundTrip() throws {
        let created = Date(timeIntervalSince1970: 1_735_689_600.25)
        let s = Session(id: "abc", label: "repo", host: "This Mac", local: true, path: "/wt", created: created)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(back, s)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"id\":\"abc\""))
        XCTAssertTrue(json.contains("\"host\":\"This Mac\""))
        XCTAssertTrue(json.contains("\"local\":true"))
        XCTAssertTrue(json.contains("\"created\":\"2025-01-01T00:00:00.25Z\""), json)
    }
}
