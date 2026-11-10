import Foundation
import XCTest
@testable import RaptorCatalog

final class BranchesTests: XCTestCase {
    func testFilterBranches() throws {
        var branches = ["feat/long-login", "main", "fix/login", "login", "feat/logout"]
        let original = branches
        // Subtests per query.
        for query in ["", "login", "flgn", "MAIN", "no-such-branch"] {
            let want: [String]
            if query.isEmpty {
                want = branches
            } else {
                want = Fuzzy.find(query, branches).map { branches[$0.index] }
            }
            let got = Catalog.filterBranches(branches, query)
            XCTAssertEqual(got, want, "query \"\(query)\": got \(got), want \(want)")
            if query == "login" {
                XCTAssertTrue(!got.isEmpty && got[0] == "login", "exact match must rank first: \(got)")
            }
        }
        XCTAssertEqual(branches, original, "input changed")
        for empty in [[String](), [String]() as [String]] {
            for query in ["", "main"] {
                let got = Catalog.filterBranches(empty, query)
                XCTAssertTrue(got.isEmpty, "empty input: got \(got)")
            }
        }
    }
}
