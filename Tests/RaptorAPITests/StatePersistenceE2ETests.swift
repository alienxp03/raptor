import Foundation
import RaptorRex
import XCTest
@testable import RaptorAPI
@testable import RaptorConfig

final class StatePersistenceE2ETests: APITestCase {
    func testLegacyMigrationAndPinRecencyUpdatesShareStateAcrossReloads() throws {
        let home = try XCTUnwrap(env.get("HOME"))
        let cache = makeTempDir()
        env.set("XDG_CACHE_HOME", cache)
        addTeardown { try? FileManager.default.removeItem(atPath: cache) }
        let legacyPinsPath = home + "/.config/raptor/session-pins.json"
        let legacyRecencyPath = cache + "/raptor/session-recency.json"
        try put(legacyPinsPath, """
        [{"sessionID":"session:legacy-pin","host":"Build Host","slot":2}]
        """, mode: 0o600)
        try FileManager.default.createDirectory(atPath: (legacyRecencyPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        let oldVisit = formatter.string(from: Date().addingTimeInterval(-60))
        try put(legacyRecencyPath, """
        {"version":1,"visits":[{"host":"","session_id":"session:legacy-visit","at":"\(oldVisit)"}]}
        """, mode: 0o600)

        let migratedPins = RaptorConfig.loadSessionPins()
        XCTAssertEqual(migratedPins.map(\.sessionID), ["session:legacy-pin"])
        XCTAssertEqual(migratedPins.first?.slot, 2)
        XCTAssertEqual(Rex.loadSessionRecency().rank("", "session:legacy-visit"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPinsPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyRecencyPath))

        XCTAssertTrue(try RaptorConfig.toggleSessionPin(sessionID: "session:new-pin", host: "local"))
        try Rex.recordSessionUse("", "session:new-visit")

        // Fresh reads after writes exercise the same disk boundary used by a new app process.
        XCTAssertEqual(RaptorConfig.loadSessionPins().map(\.sessionID), ["session:legacy-pin", "session:new-pin"])
        let reloadedRecency = Rex.loadSessionRecency()
        XCTAssertEqual(reloadedRecency.rank("", "session:new-visit"), 0)
        XCTAssertEqual(reloadedRecency.rank("", "session:legacy-visit"), 1)

        let statePath = home + "/Library/Application Support/raptor/state.json"
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: statePath))) as? [String: Any])
        XCTAssertEqual(state["version"] as? Int, 1)
        XCTAssertEqual((state["session_pins"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(((state["session_recency"] as? [String: Any])?["visits"] as? [[String: Any]])?.count, 2)
    }
}
