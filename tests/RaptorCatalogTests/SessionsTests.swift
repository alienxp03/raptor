import Foundation
import XCTest
import RaptorRex
@testable import RaptorCatalog

final class SessionsTests: XCTestCase {
    func testFilterSessionsKeepsGroups() throws {
        let entries = [
            SessionEntry(kind: "session", sessionID: "a", label: "Project"),
            SessionEntry(kind: "window", sessionID: "a", label: "build server", sessionLabel: "Project"),
            SessionEntry(kind: "window", sessionID: "a", label: "shell", sessionLabel: "Project"),
            SessionEntry(kind: "window", sessionID: "a", label: "build", sessionLabel: "Project"),
            SessionEntry(kind: "session", sessionID: "b", label: "Tools"),
            SessionEntry(kind: "window", sessionID: "b", label: "build", sessionLabel: "Tools"),
            SessionEntry(kind: "window", sessionID: "b", label: "logs", sessionLabel: "Tools"),
            SessionEntry(kind: "session", sessionID: "c", label: "Empty"),
        ]
        let cases: [(name: String, query: String, want: [Int])] = [
            ("all rows", "", [0, 1, 2, 3, 4, 5, 6, 7]),
            ("matching tabs retain parents once and keep order", "build", [0, 1, 3, 4, 5]),
            ("fuzzy tab match retains parent", "shl", [0, 2]),
            ("session match excludes unrelated tabs", "Project", [0]),
            ("empty session remains selectable", "Empty", [7]),
            ("no matches", "zzzz", []),
        ]
        for tc in cases {
            XCTAssertEqual(Catalog.filterSessions(entries, tc.query), tc.want, "[\(tc.name)]")
        }
    }

    func testFilterSessionsMissingParent() throws {
        let entries = [
            SessionEntry(kind: "session", sessionID: "other", label: "Other"),
            SessionEntry(kind: "window", sessionID: "missing", label: "shell"),
        ]
        XCTAssertEqual(Catalog.filterSessions(entries, "shell"), [1], "missing parent included an unrelated session")
        XCTAssertTrue(Catalog.filterSessions([], "").isEmpty, "empty list")
    }
}
