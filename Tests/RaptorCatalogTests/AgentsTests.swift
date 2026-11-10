import Foundation
import XCTest
import RaptorRex
@testable import RaptorCatalog

final class AgentsTests: XCTestCase {
    func testFilterAgents() throws {
        let entries = [
            AgentEntry(label: "Fix login", app: "pi", state: "working", sessionLabel: "Personal", windowLabel: "Backend"),
            AgentEntry(label: "Review", app: "codex", state: "blocked", sessionLabel: "Work", windowLabel: "Frontend"),
        ]
        let cases: [(query: String, want: [Int])] = [
            ("", [0, 1]), ("login", [0]), ("pi", [0]), ("blocked", [1]), ("Work", [0, 1]), ("Frontend", [1]), ("zzzzzz", []),
        ]
        for tc in cases {
            XCTAssertEqual(Catalog.filterAgents(entries, tc.query), tc.want, "query=\"\(tc.query)\"")
        }
    }
}
