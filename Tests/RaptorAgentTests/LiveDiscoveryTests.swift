import XCTest
@testable import RaptorAgent

final class LiveDiscoveryTests: XCTestCase {
    func testLive() async throws {
        guard AgentCatalogStore.locateTool("pi") != nil, AgentCatalogStore.locateTool("codex") != nil else {
            throw XCTSkip("requires pi and codex on PATH")
        }
        let piCatalog = await AgentCatalogStore.catalog(agent: "pi", refresh: true, cwd: "/tmp")
        print("PI:", piCatalog.models.count, "| warning:", piCatalog.warning.isEmpty ? "-" : piCatalog.warning)
        for m in piCatalog.models.prefix(6) {
            print("  pi:", m.provider + "/" + m.id, "| levels:", m.reasoning.joined(separator: ","), "| default:", m.defaultReasoning)
        }
        let codexCatalog = await AgentCatalogStore.catalog(agent: "codex", refresh: true)
        print("CODEX:", codexCatalog.models.count, "| warning:", codexCatalog.warning.isEmpty ? "-" : codexCatalog.warning)
        for m in codexCatalog.models.prefix(4) {
            print("  codex:", m.id, "| levels:", m.reasoning.joined(separator: ","), "| default:", m.defaultReasoning, "| isDefault:", m.isDefault)
        }
        print("cached codex:", AgentCatalogStore.cachedCatalog(agent: "codex")?.models.count ?? -1)
        print("launch pi:", AgentLaunch.arguments(agent: "pi", provider: "zai", model: "glm-5.3", reasoning: "max") ?? [])
        print("launch codex:", AgentLaunch.arguments(agent: "codex", provider: "", model: "gpt-6-luna", reasoning: "high") ?? [])
        XCTAssertFalse(piCatalog.models.isEmpty)
        XCTAssertFalse(codexCatalog.models.isEmpty)
    }
}
