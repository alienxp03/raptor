import Foundation
import XCTest
@testable import RaptorState

final class StateStoreTests: XCTestCase {
    private func isolate() -> (home: String, cache: String) {
        let oldHome = getenv("HOME").map { String(cString: $0) }
        let oldCache = getenv("XDG_CACHE_HOME").map { String(cString: $0) }
        let home = NSTemporaryDirectory() + "raptor-state-\(UUID().uuidString)"
        let cache = home + "/legacy-cache"
        setenv("HOME", home, 1)
        setenv("XDG_CACHE_HOME", cache, 1)
        addTeardownBlock {
            if let oldHome { setenv("HOME", oldHome, 1) } else { unsetenv("HOME") }
            if let oldCache { setenv("XDG_CACHE_HOME", oldCache, 1) } else { unsetenv("XDG_CACHE_HOME") }
            try? FileManager.default.removeItem(atPath: home)
        }
        return (home, cache)
    }

    func testMacStatePathUsesApplicationSupport() {
        let home = isolate().home
        #if os(macOS)
        XCTAssertEqual(RaptorStateStore.statePath(), home + "/Library/Application Support/raptor/state.json")
        #else
        XCTAssertEqual(RaptorStateStore.statePath(), home + "/.local/state/raptor/state.json")
        #endif
    }

    func testReadingMissingStateDoesNotCreateFiles() throws {
        let home = isolate().home
        let state = try RaptorStateStore.read()
        XCTAssertTrue((state[RaptorStateStore.sessionPinsKey] as? [Any])?.isEmpty ?? false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: RaptorStateStore.statePath()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: RaptorStateStore.statePath() + ".lock"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/Library/Application Support/raptor"))
    }

    func testMigratesPinsAndRecencyTogether() throws {
        let (home, cache) = isolate()
        let legacyPins = home + "/.config/raptor/session-pins.json"
        let legacyRecency = cache + "/raptor/session-recency.json"
        try FileManager.default.createDirectory(atPath: (legacyPins as NSString).deletingLastPathComponent,
                                               withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: (legacyRecency as NSString).deletingLastPathComponent,
                                               withIntermediateDirectories: true)
        let pins = Data(#"[{"sessionID":"session:pinned","host":"Build Host","slot":2}]"#.utf8)
        let visits = Data(#"{"version":1,"visits":[{"host":"","session_id":"session:recent","at":"2026-01-01T00:00:00Z"}]}"#.utf8)
        try pins.write(to: URL(fileURLWithPath: legacyPins))
        try visits.write(to: URL(fileURLWithPath: legacyRecency))

        let state = try RaptorStateStore.read()
        let migratedPins = try XCTUnwrap(state[RaptorStateStore.sessionPinsKey] as? [[String: Any]])
        let migratedRecency = try XCTUnwrap(state[RaptorStateStore.sessionRecencyKey] as? [String: Any])
        XCTAssertEqual(migratedPins.first?["sessionID"] as? String, "session:pinned")
        XCTAssertEqual(migratedPins.first?["slot"] as? Int, 2)
        XCTAssertEqual((migratedRecency["visits"] as? [[String: Any]])?.first?["session_id"] as? String, "session:recent")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPins))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyRecency))
        XCTAssertTrue(FileManager.default.fileExists(atPath: RaptorStateStore.statePath()))
    }

    func testConcurrentWritersPreserveBothStateSectionsAndRestrictPermissions() throws {
        let home = isolate().home
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            do {
                try RaptorStateStore.update { state, _, _ in
                    state["test_counter"] = (state["test_counter"] as? Int ?? 0) + 1
                    state[RaptorStateStore.sessionPinsKey] = [["sessionID": "session:pinned-\(index)", "host": "local", "slot": index + 1]]
                }
                try RaptorStateStore.update { state, _, _ in
                    state[RaptorStateStore.sessionRecencyKey] = ["version": 1, "visits": [[
                        "host": "", "session_id": "session:recent-\(index)", "at": "2026-01-01T00:00:00Z",
                    ]]]
                }
            } catch {
                XCTFail("concurrent update failed: \(error)")
            }
        }
        let state = try RaptorStateStore.read()
        XCTAssertEqual(state["test_counter"] as? Int, 16)
        XCTAssertEqual((state[RaptorStateStore.sessionPinsKey] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(((state[RaptorStateStore.sessionRecencyKey] as? [String: Any])?["visits"] as? [[String: Any]])?.count, 1)
        let file = try FileManager.default.attributesOfItem(atPath: RaptorStateStore.statePath())
        let fileMode = (file[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        XCTAssertEqual(fileMode, 0o600)
        let directory = try FileManager.default.attributesOfItem(atPath: (RaptorStateStore.statePath() as NSString).deletingLastPathComponent)
        let directoryMode = (directory[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home))
    }

    func testCorruptStateIsBackedUpBeforeMutation() throws {
        _ = isolate()
        let path = RaptorStateStore.statePath()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: URL(fileURLWithPath: path))
        try RaptorStateStore.update { state, _, _ in
            state[RaptorStateStore.sessionPinsKey] = [["sessionID": "session:kept", "host": "local", "slot": 1]]
        }
        let backups = try FileManager.default.contentsOfDirectory(atPath: (path as NSString).deletingLastPathComponent)
            .filter { $0.hasPrefix("state.json.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOfFile: (path as NSString).deletingLastPathComponent + "/" + backups[0], encoding: .utf8), "{broken")
        XCTAssertEqual((try RaptorStateStore.read()[RaptorStateStore.sessionPinsKey] as? [[String: Any]])?.first?["sessionID"] as? String,
                       "session:kept")
    }
}
