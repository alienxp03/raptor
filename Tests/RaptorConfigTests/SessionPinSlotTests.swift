import Foundation
import XCTest
@testable import RaptorConfig

final class SessionPinSlotTests: XCTestCase {
    private func isolate() throws -> String {
        let original = getenv("HOME").map { String(cString: $0) }
        let home = NSTemporaryDirectory() + "pin-slots-\(UUID().uuidString)"
        setenv("HOME", home, 1)
        addTeardownBlock {
            if let original { setenv("HOME", original, 1) } else { unsetenv("HOME") }
            try? FileManager.default.removeItem(atPath: home)
        }
        let path = (RaptorConfig.configPath() as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path + "/session-pins.json"
    }

    func testLegacyMigrationIsReadOnlyAndOverflowNeverPromoted() throws {
        let path = try isolate()
        let legacy = try JSONSerialization.data(withJSONObject: (1...11).map {
            ["sessionID": "s\($0)", "host": "h"]
        })
        try legacy.write(to: URL(fileURLWithPath: path))
        let pins = RaptorConfig.loadSessionPins()
        XCTAssertEqual(pins.map(\.slot), (1...9).map { Optional($0) } + [nil, nil])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), legacy, "reads must not migrate disk")
        XCTAssertFalse(try RaptorConfig.toggleSessionPin(sessionID: "s3", host: "h"))
        let reloaded = RaptorConfig.loadSessionPins()
        XCTAssertEqual(reloaded.map(\.slot), [1, 2, 4, 5, 6, 7, 8, 9, nil, nil])
        let disk = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [[String: Any]])
        XCTAssertEqual(disk.suffix(2).compactMap { $0["slot"] as? Int }, [0, 0])
        XCTAssertTrue(try RaptorConfig.toggleSessionPin(sessionID: "new", host: "h"))
        XCTAssertEqual(RaptorConfig.loadSessionPins().last?.slot, 3)
        XCTAssertNil(RaptorConfig.loadSessionPins().first { $0.sessionID == "s10" }?.slot)
        XCTAssertFalse(try RaptorConfig.toggleSessionPin(sessionID: "s1", host: "h"))
        XCTAssertEqual(RaptorConfig.loadSessionPins().last?.slot, 3)
    }

    func testMalformedSlotsFailClosedAndLegacyRespectsExistingSlots() throws {
        let path = try isolate()
        let data = Data(#"[{"sessionID":"legacy","host":"h"},{"sessionID":"owner","host":"h","slot":1},{"sessionID":"duplicate","host":"h","slot":1},{"sessionID":"zero","host":"h","slot":0},{"sessionID":"negative","host":"h","slot":-1},{"sessionID":"large","host":"h","slot":10},{"sessionID":"string","host":"h","slot":"3"},{"sessionID":"null","host":"h","slot":null},{"sessionID":"fraction","host":"h","slot":2.5}]"#.utf8)
        try data.write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(RaptorConfig.loadSessionPins().map(\.slot), [2, 1, nil, nil, nil, nil, nil, nil, nil])
        XCTAssertTrue(try RaptorConfig.toggleSessionPin(sessionID: "new", host: "h"))
        XCTAssertEqual(RaptorConfig.loadSessionPins().map(\.slot), [2, 1, nil, nil, nil, nil, nil, nil, nil, 3])
    }

    func testHostIdentityAndHashIgnoreSlotMetadata() throws {
        _ = try isolate()
        let pin = SessionPin(sessionID: "shared", host: "one", slot: 7)
        XCTAssertEqual(pin, SessionPin(sessionID: "shared", host: "one"))
        XCTAssertTrue(Set([pin]).contains(SessionPin(sessionID: "shared", host: "one", slot: 2)))
        XCTAssertFalse(Set([pin]).contains(SessionPin(sessionID: "shared", host: "two", slot: 7)))
        XCTAssertTrue(try RaptorConfig.toggleSessionPin(sessionID: "shared", host: "one"))
        XCTAssertTrue(try RaptorConfig.toggleSessionPin(sessionID: "shared", host: "two"))
        XCTAssertEqual(RaptorConfig.loadSessionPins().map(\.slot), [1, 2])
        XCTAssertFalse(try RaptorConfig.toggleSessionPin(sessionID: "shared", host: "one"))
        XCTAssertEqual(RaptorConfig.loadSessionPins().map(\.slot), [2])
    }
}
