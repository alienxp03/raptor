import Foundation
import RaptorPaths
import XCTest
@testable import RaptorRex

/// The fd scan: parsing, the find fallback's presence, and — opt-in — the real
/// remote round trip over SSH (set RAPTOR_REMOTE_SSH_HOST, e.g. "hades").
final class DirScanTests: XCTestCase {
    func testParseDirScanTrimsAndSkipsEmptyLines() {
        let out = "\n/Users/me/project  \n\n   \n/Users/me/other/\n"
        XCTAssertEqual(Rex.parseDirScan(out), ["/Users/me/project", "/Users/me/other"],
                       "fd's trailing slash is normalized")
        XCTAssertEqual(Rex.parseDirScan("/"), ["/"], "the filesystem root keeps its slash")
        XCTAssertEqual(Rex.parseDirScan(nil), [])
        XCTAssertEqual(Rex.parseDirScan(""), [])
        XCTAssertEqual(Rex.parseDirScan("   "), [])
    }

    func testLocalScanPrunesProtectedFoldersAndExpandsHome() {
        // Execx runs without a shell: the root must be the expanded home, never
        // a literal "~" which silently produces an empty scan. TCC-protected
        // folders are pruned so the backend never trips macOS file prompts.
        let args = Rex.localDirScanArgs()
        XCTAssertEqual(args.first, "-H", "hidden directories are part of the scan")
        for pruned in Rex.localDirScanPrunes {
            XCTAssertTrue(args.contains(pruned), "missing prune entry: \(pruned)")
        }
        XCTAssertEqual(args.last, RaptorPaths.home(), "scan root is the expanded home directory")
        XCTAssertFalse(args.contains("~"), "tilde must be expanded before exec")
    }

    func testRemoteScanFallsBackToFindInOneRoundTrip() {
        let command = Rex.remoteDirScanCommand()
        XCTAssertTrue(command.hasPrefix("command -v fd"), "fd is preferred when installed")
        XCTAssertTrue(command.contains("|| find "),
                      "POSIX find must close the command as the fallback")
        for pruned in Rex.remoteDirScanPrunes {
            XCTAssertTrue(command.contains("*/" + pruned), "missing prune entry: \(pruned)")
        }
    }

    func testPrioritizeVisiblePutsProjectDirsAheadOfDotDirs() {
        let scanned = [
            "/Users/me/.cache/pip",
            "/Users/me/Workspace",
            "/Users/me/.local/share",
            "/Users/me/code/app",
        ]
        XCTAssertEqual(Rex.prioritizeVisible(scanned),
                       ["/Users/me/Workspace", "/Users/me/code/app",
                        "/Users/me/.cache/pip", "/Users/me/.local/share"])
        XCTAssertEqual(Rex.prioritizeVisible([]), [])
        XCTAssertEqual(Rex.prioritizeVisible(["/Users/me/.hidden"]),
                       ["/Users/me/.hidden"], "hidden-only scans keep order")
    }

    func testRemoteScanOnUnreachableHostReturnsEmpty() {
        // A reserved documentation IP cannot connect; the scan must degrade to
        // an empty list instead of throwing into the picker.
        XCTAssertEqual(Rex.dirScanOn("192.0.2.1"), [])
    }

    func testRemoteScanOverSSHWhenHostReachable() throws {
        guard let host = ProcessInfo.processInfo.environment["RAPTOR_REMOTE_SSH_HOST"],
              !host.isEmpty else {
            throw XCTSkip("set RAPTOR_REMOTE_SSH_HOST to run the remote scan integration test")
        }
        let dirs = Rex.dirScanOn(host)
        XCTAssertFalse(dirs.isEmpty, "remote scan returned nothing for a reachable host")
        XCTAssertTrue(dirs.contains(where: { $0.hasPrefix("/") || $0.hasPrefix("~") }),
                      "remote rows are remote paths: \(dirs.prefix(5))")
    }
}
