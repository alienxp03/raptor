import Foundation
import XCTest
import RaptorConfig
import RaptorRex
@testable import RaptorCatalog

final class LauncherPinSlotTests: XCTestCase {
    func testCompositionAndCachedPinsUseCurrentSlotsWithoutChangingOrder() throws {
        let home = testTempDir()
        setenvTemp("HOME", home)
        defer { try? FileManager.default.removeItem(atPath: home) }
        try RaptorConfig.savePins(["/dir"])
        try RaptorConfig.toggleSessionPin(sessionID: "s", host: "one")
        try RaptorConfig.toggleSessionPin(sessionID: "s", host: "two")
        try RaptorConfig.toggleSessionPin(sessionID: "s", host: "one")
        let groups = [HostGroup(label: "two", reachable: true, entries: [
            SessionEntry(kind: "session", id: "two-s", sessionID: "s", label: "work", host: "two"),
            SessionEntry(kind: "session", id: "one-s", sessionID: "s", label: "other", host: "one"),
        ])]
        var rows = Catalog.launcherItems(groups, [], [:], "", [], "Mac", prioritizePins: false)
        XCTAssertEqual(rows.map(\.pinSlot), [2, nil])
        XCTAssertEqual(rows.map(\.pinned), [true, false])
        rows.append(LauncherItem(kind: "dir", id: "/dir", path: "/dir", local: true, pinSlot: 8))
        rows[0].pinSlot = 9
        rows[1].pinSlot = 7
        Catalog.applyLauncherPins(&rows)
        XCTAssertEqual(rows.map(\.id), ["two-s", "one-s", "/dir"])
        XCTAssertEqual(rows.map(\.pinSlot), [2, nil, nil])
        XCTAssertEqual(rows.map(\.pinned), [true, false, true])
        try RaptorConfig.toggleSessionPin(sessionID: "s", host: "two")
        try RaptorConfig.toggleSessionPin(sessionID: "s", host: "one")
        Catalog.applyLauncherPins(&rows)
        XCTAssertEqual(rows.map(\.pinSlot), [nil, 1, nil])
        XCTAssertEqual(rows.map(\.pinned), [false, true, true])
    }

    func testWireOmitsInvalidOrAbsentSlots() throws {
        for slot: Int? in [nil, 0, -1, 10, 1, 9] {
            let data = try JSONEncoder().encode(LauncherItem(pinSlot: slot))
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(fields["pin_slot"] as? Int, slot.flatMap { (1...9).contains($0) ? $0 : nil })
        }
    }
}
