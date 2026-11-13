import Foundation
import XCTest
@testable import RaptorAgent

final class CodexDiscoveryTests: XCTestCase {
    private func discover(configResponse: String) async throws -> AgentCatalog {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("aux/codex-defaults-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        [ "$*" = 'app-server --listen stdio://' ] || exit 1
        while IFS= read -r line; do
          case "$line" in
            *'"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
            *model*list*) printf '%s\\n' '{"id":2,"result":{"data":[{"model":"recommended","isDefault":true,"defaultReasoningEffort":"medium"},{"model":"configured","isDefault":false,"defaultReasoningEffort":"low"}],"nextCursor":null}}' ;;
            *config*read*) printf '%s\\n' '\(configResponse)' ;;
          esac
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return await CodexModels.discover(codexPath: executable.path)
    }

    func testDiscoveryReadsConfiguredDefaultsWithoutStartingThread() async throws {
        let catalog = try await discover(configResponse: #"{"id":100,"result":{"config":{"model":"configured","model_reasoning_effort":"high"}}}"#)
        XCTAssertTrue(catalog.warning.isEmpty, catalog.warning)
        XCTAssertEqual(catalog.models.map(\.isDefault), [false, true])
        XCTAssertEqual(catalog.models.map(\.defaultReasoning), ["high", "high"])
    }

    func testOlderServerKeepsCatalogButDoesNotClaimRecommendedModelIsConfiguredDefault() async throws {
        let catalog = try await discover(configResponse: #"{"id":100,"error":{"code":-32601,"message":"unknown method"}}"#)
        XCTAssertEqual(catalog.models.count, 2)
        XCTAssertFalse(catalog.models.contains(where: \.isDefault))
        XCTAssertEqual(catalog.models.map(\.defaultReasoning), ["", ""])
        XCTAssertTrue(catalog.warning.contains("configured defaults unavailable"), catalog.warning)
    }
}
