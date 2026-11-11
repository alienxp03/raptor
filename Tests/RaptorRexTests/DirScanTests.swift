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

    func testLocalScanPrunesTrashAndLibraryAndExpandsHome() {
        // Execx runs without a shell: the root must be the expanded home, never
        // a literal "~" which silently produces an empty scan.
        let args = Rex.localDirScanArgs()
        XCTAssertEqual(args.first, "-H", "hidden directories are part of the scan")
        for pruned in [".Trash", "Library"] {
            XCTAssertTrue(args.contains(pruned), "missing prune entry: \(pruned)")
        }
        XCTAssertEqual(args.last, RaptorPaths.home(), "scan root is the expanded home directory")
        XCTAssertFalse(args.contains("~"), "tilde must be expanded before exec")
    }

    func testRemoteScanFallsBackToFind() {
        let candidates = Rex.remoteDirScanCandidates
        XCTAssertGreaterThanOrEqual(candidates.count, 2)
        XCTAssertEqual(candidates.last?.hasPrefix("find "), true,
                       "POSIX find must close the candidate list")
        for candidate in candidates.dropLast() {
            XCTAssertTrue(candidate.hasPrefix("fd ") || candidate.contains("/fd ") || candidate.hasPrefix("fdfind "),
                          "non-final candidates must be fd invocations: \(candidate)")
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
