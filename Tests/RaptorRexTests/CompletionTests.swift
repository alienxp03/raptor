import Foundation
import XCTest
@testable import RaptorRex

final class CompletionTests: XCTestCase {
    let timestamp = "2026-06-12T10:11:12.923999Z"

    func source(_ state: String = "done", record: String = "") -> CompletionSource {
        CompletionSource(block: "b", record: record, state: state, updatedAt: timestamp)
    }

    func receipt(record: String = "", timestamp: String? = nil, block: String = "b") -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ["block": block, "record": record,
                "date": formatter.date(from: timestamp ?? "2026-06-12T10:11:12.923Z")!]
    }

    func preferences(seen: [[String: Any]] = [], alerted: [[String: Any]] = []) -> [String: Any] {
        ["Workspace.programActivitySeen": ["receipts": seen, "alerted": alerted]]
    }

    func testDoneUnreadSeenAndExactIdentity() {
        XCTAssertTrue(CompletionReceipts(preferences: preferences()).unread(source()))
        XCTAssertFalse(CompletionReceipts(preferences: preferences(seen: [receipt()])).unread(source()))
        for wrong in [receipt(record: "child"), receipt(timestamp: "2026-06-12T10:11:12.924Z"), receipt(block: "other")] {
            XCTAssertTrue(CompletionReceipts(preferences: preferences(seen: [wrong])).unread(source()))
        }
        XCTAssertFalse(CompletionReceipts(preferences: preferences(seen: [receipt(record: "child")])).unread(source(record: "child")))
        XCTAssertTrue(CompletionReceipts(preferences: preferences(seen: [receipt()])).unread(source(record: "child")))
    }

    func testIdleRequiresExactAnnouncementAndNoReceipt() {
        XCTAssertFalse(CompletionReceipts(preferences: preferences()).unread(source("idle")))
        XCTAssertTrue(CompletionReceipts(preferences: preferences(alerted: [receipt()])).unread(source("idle")))
        XCTAssertFalse(CompletionReceipts(preferences: preferences(seen: [receipt()], alerted: [receipt()])).unread(source("idle")))
        XCTAssertFalse(CompletionReceipts(preferences: preferences(alerted: [receipt(record: "other")])).unread(source("idle")))
        for state in ["working", "blocked", "error"] {
            XCTAssertFalse(CompletionReceipts(preferences: preferences(alerted: [receipt()])).unread(source(state)))
        }
    }

    func testUnavailableAndMalformedFailClosed() {
        for prefs: [String: Any]? in [nil, [:], ["Workspace.programActivitySeen": "bad"],
            ["Workspace.programActivitySeen": ["receipts": "bad"]],
            ["Workspace.programActivitySeen": ["alerted": [["block": "b", "record": "", "date": "bad"]]]]] {
            XCTAssertFalse(CompletionReceipts(preferences: prefs).unread(source()))
        }
        var invalid = source()
        invalid.updatedAt = "bad"
        XCTAssertFalse(CompletionReceipts(preferences: preferences()).unread(invalid))
    }

    func testPreferenceFileChangesAndUnavailableFailClosed() throws {
        let directory = testTempDir()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("rex.plist")
        func unread() -> Bool {
            CompletionReceipts(preferences: CompletionReceipts.loadPreferences(from: url)).unread(source())
        }
        func write(_ value: [String: Any]) throws {
            try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
                .write(to: url, options: .atomic)
        }
        XCTAssertFalse(unread())
        try write(preferences())
        XCTAssertTrue(unread())
        try write(preferences(seen: [receipt()]))
        XCTAssertFalse(unread())
        try write(preferences())
        XCTAssertTrue(unread())
        try Data("corrupt".utf8).write(to: url, options: .atomic)
        XCTAssertFalse(unread())
        try write(preferences())
        XCTAssertTrue(unread())
        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(unread())
    }

    func testDecodeRetainsRawCompletionButNormalizesState() throws {
        let json = #"{"sessions":[{"session_id":"s","windows":[{"window_id":"w","blocks":[{"block_id":"b","records":[{"app":"codex","state":"done","updated_at":"2026-06-12T10:11:12.923999Z"},{"id":"child","app":"pi","state":"error","updated_at":"2026-06-12T10:11:12.923999Z"}]}]}]}]}"#
        let agents = try Rex.decodeAgentEntriesWithNames(Data(json.utf8), "", Date(), false)
        XCTAssertEqual(agents.map(\.state), ["idle", "idle"])
        XCTAssertEqual(agents.map(\.completionSource), [source(), source("error", record: "child")])
    }
}
