import XCTest
@testable import RaptorWorktree

final class FastSuggestionTests: XCTestCase {
    func testSkipsExistingAndRefPrefixCollisions() {
        let names = ["amber-birch", "cedar-dune", "elm-fern"]
        XCTAssertEqual(WorktreeKit.suggestTaskNameFast(
            branches: ["amber-birch", "cedar-dune/topic/nested"], names: names), "elm-fern")
        XCTAssertEqual(WorktreeKit.suggestTaskNameFast(
            branches: names, names: names), "")
        XCTAssertEqual(WorktreeKit.suggestTaskNameFast(branches: [], names: []), "")
        XCTAssertEqual(WorktreeKit.suggestTaskNameFast(
            branches: ["amber-birch-other", "prefix/amber-birch"], names: names), "amber-birch")
    }

    func testPrefixCollisionInBothDirections() {
        XCTAssertEqual(WorktreeKit.suggestTaskNameFast(
            branches: ["topic"], names: ["topic/child", "elm-fern"]), "elm-fern")
        XCTAssertEqual(WorktreeKit.suggestTaskNameFast(
            branches: ["topic/child"], names: ["topic/other"]), "topic/other")
    }

    func testPublicHelperPreservesTwoWordTaskNaming() {
        let words = Set(taskWordList.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        for _ in 0..<20 {
            let name = WorktreeKit.suggestTaskNameFast(branches: [])
            let parts = name.split(separator: "-").map(String.init)
            XCTAssertEqual(parts.count, 2)
            XCTAssertEqual(Set(parts).count, 2)
            XCTAssertTrue(parts.allSatisfy { words.contains($0) })
            XCTAssertEqual(WorktreeKit.suggestTaskNameFast(branches: [name], names: [name]), "")
            XCTAssertEqual(WorktreeKit.suggestTaskNameFast(branches: [name + "/child"], names: [name]), "")
        }
    }
}
