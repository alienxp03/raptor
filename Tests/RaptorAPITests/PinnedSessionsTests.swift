import Foundation
import RaptorConfig
import RaptorRex
import XCTest
@testable import RaptorAPI

final class PinnedSessionsTests: APITestCase {
    private var root = ""

    override func setUp() {
        super.setUp()
        root = makeTempDir()
        env.set("HOME", root)
        env.set("XDG_CONFIG_HOME", root + "/config")
        env.set("XDG_CACHE_HOME", root + "/cache")
        env.set("PATH", root + ":" + (env.get("PATH") ?? ""))
        Rex.apiHostnameLock.lock()
        let previous = Rex.apiHostnameCache
        Rex.apiHostnameCache = "local-mac"
        Rex.apiHostnameLock.unlock()
        addTeardown {
            Rex.apiHostnameLock.lock()
            Rex.apiHostnameCache = previous
            Rex.apiHostnameLock.unlock()
        }
    }

    private func pins(_ json: String) throws {
        try put(root + "/.config/raptor/session-pins.json", json, mode: 0o600)
    }

    private func stub(list: String, offline: Bool = false, selectFailure: Bool = false) throws {
        try put(root + "/rex", """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(root)/calls'
        case "$*" in
          'ls --json'|'-S remote ls --json')
            \(offline ? "echo offline >&2; exit 1" : "printf '%s\\n' '\(list)'") ;;
          *client.list*)
            echo '{"clients":[{"client_id":"client:viewer","connection_state":"connected","info":{"kind":"app","label":"My Mac"}}]}' ;;
          *'do session.select session_id=session:target') \(selectFailure ? "echo 'selection denied' >&2; exit 1" : ":") ;;
          *) echo "unexpected Rex call: $*" >&2; exit 1 ;;
        esac
        """)
    }

    private func handler() -> Handler {
        Handler(ctx: Ctx(session: "session:origin", client: "client:viewer"), cfg: .default())
    }

    private func calls() throws -> String {
        fileExists(root + "/calls") ? try readFile(root + "/calls") : ""
    }

    func testLocalDisplayHostAndOriginClientWithFreshListing() throws {
        try pins("""
        [{"sessionID":"session:target","host":"LOCAL-MAC","slot":1}]
        """)
        try stub(list: "{\"sessions\":[{\"session_id\":\"session:target\"}]}")
        XCTAssertEqual(try handler().selectPinnedSession(slot: 1), "session:target")
        XCTAssertEqual(try calls(), "ls --json\n-C client:viewer do session.select session_id=session:target\n")
    }

    func testResolveLocalPinValidatesWithoutCallingWaitingClient() throws {
        try pins("""
        [{"sessionID":"session:target","host":"LOCAL-MAC","slot":1}]
        """)
        try stub(list: "{\"sessions\":[{\"session_id\":\"session:target\"}]}")
        let pin = try handler().resolvePinnedSession(slot: 1)
        XCTAssertEqual(pin.sessionID, "session:target")
        XCTAssertEqual(pin.host, "")
        XCTAssertEqual(pin.slot, 1)
        XCTAssertEqual(try calls(), "ls --json\n")
    }

    func testResolveRemotePinKeepsHostAndDoesNotSelect() throws {
        try pins("""
        [{"sessionID":"session:target","host":"remote","slot":9}]
        """)
        try stub(list: "{\"sessions\":[{\"session_id\":\"session:target\"}]}")
        let pin = try handler().resolvePinnedSession(slot: 9)
        XCTAssertEqual(pin.host, "remote")
        XCTAssertEqual(pin.sessionID, "session:target")
        XCTAssertEqual(try calls(), "-S remote ls --json\n")
    }

    func testRemoteStoredHostOnlyAndVariadicSelection() throws {
        try pins("""
        [{"sessionID":"session:target","host":"remote","slot":9}]
        """)
        try stub(list: "{\"sessions\":[{\"session_id\":\"session:target\"}]}")
        XCTAssertEqual(try handler().selectPinnedSession(slot: 9), "session:target")
        let log = try calls()
        XCTAssertTrue(log.hasPrefix("-S remote ls --json\n"), log)
        XCTAssertTrue(log.contains("-S remote -C client:viewer do session.select session_id=session:target"), log)
        XCTAssertFalse(log.contains("session.view"), log)
        XCTAssertFalse(log.contains("new"), log)
    }

    func testInvalidAndEmptySlotsDoNotContactRex() throws {
        try pins("[]")
        try stub(list: "{}")
        for slot in [-1, 0, 1, 9, 10] {
            XCTAssertThrowsError(try handler().selectPinnedSession(slot: slot)) { error in
                XCTAssertTrue(String(describing: error).contains(slot == 1 || slot == 9 ? "no pinned session" : "1...9"))
            }
        }
        XCTAssertEqual(try calls(), "")
    }

    func testMissingExactIdentityNeverSelectsOrRepoints() throws {
        try pins("""
        [{"sessionID":"session:target","host":"remote","slot":1}]
        """)
        // Prefix matches and identical labels are not the pinned identity.
        try stub(list: "{\"sessions\":[{\"session_id\":\"session:target-other\",\"label\":\"session:target\"}]}")
        XCTAssertThrowsError(try handler().selectPinnedSession(slot: 1)) { error in
            XCTAssertTrue(String(describing: error).contains("closed or missing on remote"))
        }
        XCTAssertEqual(try calls(), "-S remote ls --json\n")
        XCTAssertEqual(RaptorConfig.loadSessionPins().first?.sessionID, "session:target")
    }

    func testSelectionFailureIsReportedWithoutFallbackCreation() throws {
        try pins("""
        [{"sessionID":"session:target","host":"local-mac","slot":1}]
        """)
        try stub(list: "{\"sessions\":[{\"session_id\":\"session:target\"}]}", selectFailure: true)
        XCTAssertThrowsError(try handler().selectPinnedSession(slot: 1)) { error in
            XCTAssertTrue(String(describing: error).contains("could not select session:target"))
        }
        XCTAssertEqual(try calls(), "ls --json\n-C client:viewer do session.select session_id=session:target\n")
    }

    func testOfflineAndMalformedListingFailClosed() throws {
        try pins("""
        [{"sessionID":"session:target","host":"remote","slot":1}]
        """)
        for (payload, offline, message) in [("{}", false, "invalid session listing"), ("not-json", false, "invalid session listing"), ("", true, "cannot reach remote")] {
            try stub(list: payload, offline: offline)
            XCTAssertThrowsError(try handler().selectPinnedSession(slot: 1)) { error in
                XCTAssertTrue(String(describing: error).contains(message), "\(error)")
            }
        }
        XCTAssertEqual(try calls().split(separator: "\n").count, 3)
    }
}
