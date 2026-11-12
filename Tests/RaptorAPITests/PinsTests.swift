import Foundation
import RaptorCatalog
import RaptorConfig
import RaptorRex
import XCTest
@testable import RaptorAPI

final class PinsTests: APITestCase {
    private func handler() -> Handler {
        env.set("HOME", makeTempDir())
        env.set("XDG_CACHE_HOME", makeTempDir())
        let h = Handler(ctx: Ctx(session: "origin"), cfg: .default())
        h.commitLauncher([
            LauncherItem(kind: "session", id: "origin", sessionID: "origin", label: "Origin", host: "mac", local: true),
            LauncherItem(kind: "session", id: "shared", sessionID: "shared", label: "Project", host: "one"),
            LauncherItem(kind: "session", id: "shared", sessionID: "shared", label: "Project", host: "two"),
            LauncherItem(kind: "dir", id: "/work/other", path: "/work/other", label: "Other", host: "mac", local: true),
            LauncherItem(kind: "dir", id: "/work/project", path: "/work/project", label: "Project", host: "mac", local: true),
        ], [])
        return h
    }

    private func toggle(_ h: Handler, _ params: String) throws -> Bool {
        let (result, error) = h.call(CancelToken(), "pins.toggle", Array(params.utf8))
        XCTAssertNil(error)
        guard case let .pins(pinned)? = result else {
            XCTFail("missing pins response")
            return false
        }
        return pinned
    }

    func testSessionPinsPersistAndSeparateHostsWithoutScan() throws {
        let h = handler()
        XCTAssertTrue(try toggle(h, "{\"session_id\":\"shared\",\"host\":\"two\"}"))
        XCTAssertEqual(RaptorConfig.loadSessionPins(), [SessionPin(sessionID: "shared", host: "two")])
        let items = try XCTUnwrap(h.launcherItems())
        XCTAssertEqual(items.first?.host, "two")
        XCTAssertTrue(items[0].pinned)
        XCTAssertEqual(items[1].sessionID, "origin")
        XCTAssertFalse(try XCTUnwrap(items.first { $0.host == "one" }).pinned)
        XCTAssertFalse(h.revalidating)
        XCTAssertFalse(h.refreshPending)

        // A restarted backend reads both the disk snapshot and persistent pin state.
        let restarted = Handler(ctx: Ctx(session: "origin"), cfg: .default())
        XCTAssertEqual(restarted.launcherItems(), items)
        XCTAssertFalse(restarted.revalidating)
        XCTAssertFalse(try toggle(restarted, "{\"session_id\":\"shared\",\"host\":\"two\"}"))
        XCTAssertEqual(restarted.launcherItems()?.first?.sessionID, "origin")
        XCTAssertTrue(RaptorConfig.loadSessionPins().isEmpty)
    }

    func testDirectoryAndSessionPinsAboveOriginAndRestoreSourceOrder() throws {
        let h = handler()
        XCTAssertTrue(try toggle(h, "{\"path\":\"/work/project\"}"))
        XCTAssertTrue(try toggle(h, "{\"session_id\":\"shared\",\"host\":\"two\"}"))
        let items = try XCTUnwrap(h.launcherItems())
        XCTAssertEqual(items.prefix(3).map(\.id), ["shared", "/work/project", "origin"])
        let (result, error) = h.call(CancelToken(), "sessions", Array("{}".utf8))
        XCTAssertNil(error)
        let reply = try jsonDict(XCTUnwrap(result).encode())
        XCTAssertEqual(reply["selected_id"] as? String, "origin", "Pinned rows must not change the current-session default")
        XCTAssertEqual(RaptorConfig.loadPins(), ["/work/project"])
        let matching = Catalog.filterLauncherItems(items, "Project", "")
        XCTAssertEqual(matching.count, 3)
        XCTAssertEqual(matching.filter(\.pinned).count, 2)
        let other = Catalog.filterLauncherItems(items, "Other", "")
        XCTAssertEqual(other.map(\.id), ["/work/other"])
        XCTAssertFalse(try toggle(h, "{\"path\":\"/work/project\"}"))
        XCTAssertEqual(h.launcherItems()?.suffix(2).map(\.id), ["/work/other", "/work/project"])
        XCTAssertFalse(h.revalidating)
    }

    func testSearchTiesKeepRecencyWhileEmptyQueryPrioritizesPins() throws {
        let h = handler()
        h.ranks = SessionRecency(["\u{0}session:newer": 0, "\u{0}session:older": 1])
        h.commitLauncher([
            LauncherItem(kind: "session", id: "session:older", sessionID: "session:older", label: "Project", host: "mac", local: true),
            LauncherItem(kind: "session", id: "session:newer", sessionID: "session:newer", label: "Project", host: "mac", local: true),
        ], [])
        XCTAssertTrue(try toggle(h, "{\"session_id\":\"session:older\",\"host\":\"mac\"}"))

        XCTAssertEqual(sessionRows(h, "Project"), ["mac/session:newer", "mac/session:older"])
        XCTAssertEqual(sessionRows(h, ""), ["mac/session:older", "mac/session:newer"])
        XCTAssertEqual(sessionRows(h, "Project"), ["mac/session:newer", "mac/session:older"])
    }

    func testStaleScanCannotUndoPin() throws {
        let h = handler()
        let stale = try XCTUnwrap(h.launcher.items)
        XCTAssertTrue(try toggle(h, "{\"session_id\":\"shared\",\"host\":\"two\"}"))
        h.commitLauncherAt(stale, [], Date())
        XCTAssertEqual(h.launcherItems()?.first?.host, "two")
        XCTAssertEqual(h.launcherItems()?.first?.pinned, true)
        let restarted = Handler(ctx: Ctx(session: "origin"), cfg: .default())
        XCTAssertEqual(restarted.launcherItems()?.first?.pinned, true)
    }

    func testValidation() {
        let h = handler()
        for params in ["{}", "{\"session_id\":\"shared\"}",
                       "{\"path\":\"/work\",\"session_id\":\"shared\",\"host\":\"one\"}",
                       "{\"session_id\":4,\"host\":\"one\"}"] {
            let (_, error) = h.call(CancelToken(), "pins.toggle", Array(params.utf8))
            XCTAssertNotNil(error, params)
        }
    }
}
