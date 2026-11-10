import XCTest
@testable import RaptorPaths

final class PathsTests: XCTestCase {
    func testExpandHome() {
        let home = String(cString: getenv("HOME"))
        XCTAssertEqual(RaptorPaths.expandHome("~"), home)
        XCTAssertEqual(RaptorPaths.expandHome("~/x/y"), home + "/x/y")
        XCTAssertEqual(RaptorPaths.expandHome("/tmp/x"), "/tmp/x")
        XCTAssertEqual(RaptorPaths.expandHome("not/~home"), "not/~home")
    }

    func testHomeRelative() {
        let home = String(cString: getenv("HOME"))
        XCTAssertEqual(RaptorPaths.homeRelative(home + "/a/b"), "~/a/b")
        XCTAssertEqual(RaptorPaths.homeRelative("/opt/x"), "/opt/x")
        XCTAssertEqual(RaptorPaths.homeRelative(""), "")
    }

    func testBasenameTrimsTrailingSlash() {
        XCTAssertEqual(RaptorPaths.basename("/a/b/"), "b")
        XCTAssertEqual(RaptorPaths.basename("/a/b"), "b")
        XCTAssertEqual(RaptorPaths.basename("/"), "/")
        XCTAssertEqual(RaptorPaths.basename("plain"), "plain")
    }

    func testCanonicalReturnsAbsolutePath() {
        let dir = NSTemporaryDirectory() + "raptor-paths-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        XCTAssertEqual(RaptorPaths.canonical(dir + "/sub"), (dir + "/sub" as NSString).standardizingPath)
        XCTAssertEqual(RaptorPaths.canonical(""), "")
        try! FileManager.default.removeItem(atPath: dir)
    }

    func testPanelSocketUnderCache() {
        XCTAssertTrue(RaptorPaths.panelSocket().hasSuffix("/raptor/panel.sock"))
    }
}
