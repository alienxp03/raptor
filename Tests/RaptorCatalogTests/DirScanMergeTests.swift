import Foundation
import XCTest
@testable import RaptorCatalog

/// The fd scan is a fallback under zoxide's frecency order: appended, deduped
/// by canonical path, and capped so it never becomes a second index.
final class DirScanMergeTests: XCTestCase {
    func testScanAppendsAfterZoxideAndKeepsFrecencyOrder() {
        let merged = Catalog.mergeDirScan(
            zoxide: ["/home/me/visited", "/home/me/older"],
            scan: ["/home/me/new-project", "/home/me/visited/sub"])
        // visited/sub is a distinct directory zoxide has never seen on its own;
        // only exact canonical twins of known entries are suppressed.
        XCTAssertEqual(merged,
                       ["/home/me/visited", "/home/me/older", "/home/me/new-project", "/home/me/visited/sub"],
                       "scan entries must trail zoxide entries in order")
    }

    func testScanDeduplicatesByCanonicalPath() throws {
        let root = catalogTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let real = root + "/real-project"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        let link = root + "/linked"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)

        // zoxide knows the symlinked form; the scan reports the resolved one.
        let merged = Catalog.mergeDirScan(zoxide: [link], scan: [real])
        XCTAssertEqual(merged, [link], "scan twin of a canonical zoxide entry must be dropped")

        // And the reverse direction: scan form first, zoxide symlink twin second.
        let flipped = Catalog.mergeDirScan(zoxide: [real], scan: [link])
        XCTAssertEqual(flipped, [real])
    }

    func testScanCapBoundsTheFallbackContribution() {
        let zoxide = ["/home/me/visited"]
        let scan = (0..<150).map { "/home/me/project-\($0)" }
        let merged = Catalog.mergeDirScan(zoxide: zoxide, scan: scan)
        XCTAssertEqual(merged.count, 1 + 100, "scan contribution must stop at the cap")
        XCTAssertEqual(Array(merged.dropFirst()), Array(scan.prefix(100)), "cap keeps first scan entries")
    }

    func testEmptyScanAndEmptyZoxide() {
        XCTAssertEqual(Catalog.mergeDirScan(zoxide: [], scan: []), [])
        XCTAssertEqual(Catalog.mergeDirScan(zoxide: [], scan: ["/only/scan"]),
                       ["/only/scan"])
        XCTAssertEqual(Catalog.mergeDirScan(zoxide: ["/only/zoxide"], scan: []),
                       ["/only/zoxide"])
    }

    func testTypedPathDirectoryRequiresPathLikeQuery() throws {
        let root = catalogTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let deep = root + "/deep/nested/thing"
        try FileManager.default.createDirectory(atPath: deep, withIntermediateDirectories: true)

        // Names, fuzzy fragments, and bare words are not paths.
        for query in ["thing", "deep nested", "deep/nested", ""] {
            XCTAssertNil(Catalog.typedPathDirectory(query, []), "query \"\(query)\" must not be a typed path")
        }

        // Path prefixes resolve to an existing directory.
        let typed = Catalog.typedPathDirectory(deep, [])
        XCTAssertEqual(typed?.label, "thing")
        XCTAssertNotNil(Catalog.typedPathDirectory(deep + "/", []), "trailing slash stays a path")
        XCTAssertNotNil(Catalog.typedPathDirectory("~", []), "bare tilde resolves to home")
        // Relative forms are accepted shape-wise; without a matching directory
        // under the process cwd they resolve to nothing instead of guessing.
        XCTAssertNil(Catalog.typedPathDirectory("./no-such-dir-here", []))

        // Nonexistent paths resolve to nothing.
        XCTAssertNil(Catalog.typedPathDirectory(root + "/nope/deeper", []))

        // A file is not a directory row.
        let file = root + "/file.txt"
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        XCTAssertNil(Catalog.typedPathDirectory(file, []))
    }

    func testTypedPathDirectorySkipsAlreadyListedRows() throws {
        let root = catalogTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let project = root + "/project"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        let listed = [Directory(path: project, label: "project")]
        XCTAssertNil(Catalog.typedPathDirectory(project, listed), "listed rows must not duplicate")
        XCTAssertNotNil(Catalog.typedPathDirectory(project, []), "unlisted rows still synthesize")
    }
}
