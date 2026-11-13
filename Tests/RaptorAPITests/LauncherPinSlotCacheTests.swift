import Foundation
import XCTest
import RaptorCatalog
@testable import RaptorAPI

final class LauncherPinSlotCacheTests: XCTestCase {
    func testCacheRoundTripPreservesPinSlots() throws {
        let items = [LauncherItem(kind: "session", id: "s", pinned: true, pinSlot: 9),
                     LauncherItem(kind: "session", id: "overflow", pinned: true)]
        let decoded = try XCTUnwrap(decodeLauncherCache(encodeLauncherCache(LauncherCacheEntry(items: items))))
        XCTAssertEqual(decoded.items, items)
    }

    func testOldAndMalformedCacheSlotsAreUnslotted() throws {
        for field in ["", ",\"pin_slot\":null", ",\"pin_slot\":0", ",\"pin_slot\":10",
                      ",\"pin_slot\":-1", ",\"pin_slot\":true", ",\"pin_slot\":\"2\"", ",\"pin_slot\":2.5"] {
            let data = Data("{\"items\":[{\"kind\":\"session\",\"is_pinned\":true\(field)}]}".utf8)
            let item = try XCTUnwrap(decodeLauncherCache(data)?.items?.first)
            XCTAssertTrue(item.pinned)
            XCTAssertNil(item.pinSlot, field)
        }
    }
}
