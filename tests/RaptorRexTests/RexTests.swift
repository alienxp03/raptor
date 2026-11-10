import XCTest
@testable import RaptorRex

final class RexTests: XCTestCase {
    func testSelectSessionRemembersOnlyOnSuccess() throws {
        fakeRex()
        let ctx = Ctx(session: "session:current", client: "client:app")
        try seedHistory("", "session:previous")
        let recencyFile = Rex.recencyPath()
        let before = readTextFile(recencyFile)
        setenvTemp("REX_TEST_FAIL", "select")
        XCTAssertThrowsError(try Rex.selectSession(ctx, "session:previous"))
        let after = readTextFile(recencyFile)
        XCTAssertEqual(before, after, "failed selection changed history")
        setenvTemp("REX_TEST_FAIL", "")
        try Rex.selectSession(ctx, "session:previous")
        let ranks = Rex.loadSessionRecency()
        XCTAssertEqual(ranks.rank("", "session:previous"), 0)
        XCTAssertEqual(ranks.rank("", ctx.session), 1)
    }

    func testSelectLastSkipsDeletedAndToggles() throws {
        fakeRex()
        try seedHistory("", "session:previous", "session:deleted", "session:current")
        var ctx = Ctx(session: "session:current", client: "client:app")
        for want in ["session:previous", "session:current", "session:previous"] {
            let got = try Rex.selectLast(ctx)
            XCTAssertEqual(got, want)
            ctx.session = got
        }
    }

    func testSelectLastFailurePreservesHistory() throws {
        for failure in ["select", "list", "malformed"] {
            fakeRex()
            try seedHistory("", "session:previous")
            let recencyFile = Rex.recencyPath()
            let before = readTextFile(recencyFile)
            setenvTemp("REX_TEST_FAIL", failure)
            XCTAssertThrowsError(try Rex.selectLast(Ctx(session: "session:current", client: "client:app")))
            let after = readTextFile(recencyFile)
            XCTAssertEqual(before, after, "failed navigation changed history")
        }
    }

    func testSelectLastRemote() throws {
        let log = fakeRex()
        try seedHistory("work-host", "session:previous")
        let got = try Rex.selectLast(Ctx(session: "session:current", client: "client:app"))
        XCTAssertEqual(got, "session:previous")
        let calls = readTextFile(log)
        XCTAssertTrue(calls.contains("-S work-host -C client:app do session.select session_id=session:previous"), "wrong remote routing: \(calls)")
        XCTAssertEqual(Rex.loadSessionRecency().rank("work-host", got), 0, "remote selection not recorded")
    }

    func testSelectLastRemoteRequiresApp() throws {
        let log = fakeRex()
        try seedHistory("work-host", "session:previous")
        setenvTemp("REX_TEST_FAIL", "client")
        let recencyFile = Rex.recencyPath()
        let before = readTextFile(recencyFile)
        XCTAssertThrowsError(try Rex.selectLast(Ctx(session: "session:current", client: "client:app")))
        let after = readTextFile(recencyFile)
        let calls = readTextFile(log)
        XCTAssertEqual(before, after)
        XCTAssertFalse(calls.contains("session.select"))
        XCTAssertFalse(calls.contains("session.focus_window"), "failed remote routing changed history or focus")
    }

    func testSelectLastLegacyFallback() throws {
        fakeRex()
        let stateFile = Rex.statePath()
        try FileManager.default.createDirectory(atPath: (stateFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("session:previous\n".utf8).write(to: URL(fileURLWithPath: stateFile))
        let got = try Rex.selectLast(Ctx(session: "session:current", client: "client:app"))
        XCTAssertEqual(got, "session:previous")
    }

    func testSelectLastRejectsMissingContextOrHistory() throws {
        fakeRex()
        let contexts = [
            Ctx(),
            Ctx(session: "session:current"),
            Ctx(client: "client:app"),
            Ctx(session: "session:current", client: "client:app"),
        ]
        for ctx in contexts {
            XCTAssertThrowsError(try Rex.selectLast(ctx), "expected error for \(ctx)")
        }
    }
}
