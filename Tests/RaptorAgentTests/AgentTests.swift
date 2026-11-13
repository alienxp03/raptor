import XCTest

@testable import RaptorAgent

final class AgentLaunchTests: XCTestCase {
    func testPiArguments() {
        XCTAssertEqual(
            AgentLaunch.arguments(agent: "pi", provider: "zai", model: "glm-5.3", reasoning: "max"),
            ["--provider", "zai", "--model", "glm-5.3", "--thinking", "max"])
        XCTAssertEqual(
            AgentLaunch.arguments(agent: "pi", provider: "", model: "glm-5.3", reasoning: ""),
            ["--model", "glm-5.3"])
    }

    func testCodexArguments() {
        XCTAssertEqual(
            AgentLaunch.arguments(agent: "codex", provider: "", model: "gpt-6-luna", reasoning: "high"),
            ["--model", "gpt-6-luna", "-c", "model_reasoning_effort=\"high\""])
        XCTAssertEqual(
            AgentLaunch.arguments(agent: "codex", provider: "", model: "gpt-6-luna", reasoning: ""),
            ["--model", "gpt-6-luna"])
    }

    func testDefaultReasoningOmitsFlag() {
        for reasoning in [AgentLaunch.defaultReasoning, "", "  "] {
            XCTAssertEqual(
                AgentLaunch.arguments(agent: "pi", provider: "", model: "m", reasoning: reasoning),
                ["--model", "m"], reasoning)
        }
    }

    func testNoneAgentAndEmptyModelMeanNoLaunch() {
        XCTAssertNil(AgentLaunch.arguments(agent: "none", provider: "", model: "m", reasoning: ""))
        XCTAssertNil(AgentLaunch.arguments(agent: "pi", provider: "", model: "  ", reasoning: ""))
    }

    func testShellLineQuotesData() {
        XCTAssertEqual(AgentLaunch.shellLine(["pi", "--thinking", "max"]), "'pi' '--thinking' 'max'")
        XCTAssertEqual(AgentLaunch.shellLine(["pi --model 'a'"]), "'pi --model '\\''a'\\'''")
        XCTAssertEqual(AgentLaunch.shellLine([""]), "''")
    }
}

final class PiParseTests: XCTestCase {
    func testParseOutputMapsRows() {
        let json = """
        {"models":[{"id":"glm-5.3","provider":"zai","label":"GLM-5.3","reasoning":["low","high","max"],"defaultReasoning":"high","isDefault":true},
                   {"id":"gpt-6-luna","provider":"openai-codex","label":"Luna","reasoning":["off"],"defaultReasoning":"off","isDefault":false}],
         "warnings":["ambiguous provider x"]}
        """
        let parsed = PiModels.parseOutput(json)
        XCTAssertEqual(parsed?.models.count, 2)
        XCTAssertEqual(parsed?.models[0].id, "glm-5.3")
        XCTAssertEqual(parsed?.models[0].defaultReasoning, "high")
        XCTAssertEqual(parsed?.models[0].isDefault, true)
        XCTAssertEqual(parsed?.models[1].isDefault, false)
        XCTAssertEqual(parsed?.models[1].reasoning, ["off"])
        XCTAssertEqual(parsed?.models[1].defaultReasoning, "off")
        XCTAssertEqual(parsed?.warnings, ["ambiguous provider x"])
    }

    func testParseOutputRejectsNonJSON() {
        XCTAssertNil(PiModels.parseOutput("nope"))
        XCTAssertNil(PiModels.parseOutput("{}"))
    }
}

final class CodexParseTests: XCTestCase {
    func testModelFromRowMapsEffortsAndDefaults() {
        let row: [String: Any] = [
            "model": "gpt-6.1-sol", "displayName": "GPT-6.1-Sol", "isDefault": true,
            "defaultReasoningEffort": "low",
            "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "high"], "ultra"],
        ]
        let model = CodexModels.model(from: row)
        XCTAssertEqual(model?.id, "gpt-6.1-sol")
        XCTAssertEqual(model?.label, "GPT-6.1-Sol")
        XCTAssertEqual(model?.reasoning, ["low", "high", "ultra"])
        XCTAssertEqual(model?.defaultReasoning, "low")
        XCTAssertEqual(model?.isDefault, true)
    }

    func testConfiguredDefaultsOverrideCatalogRecommendation() {
        let models = [AgentModel(id: "first", defaultReasoning: "medium", isDefault: true),
                      AgentModel(id: "saved", defaultReasoning: "low")]
        let resolved = CodexModels.applying(config: ["model": "saved", "model_reasoning_effort": "high"], to: models)
        XCTAssertEqual(resolved.map(\.isDefault), [false, true])
        XCTAssertEqual(resolved.map(\.defaultReasoning), ["high", "high"])
    }

    func testUnsetConfigPreservesServerDefaults() {
        let models = [AgentModel(id: "m", defaultReasoning: "medium", isDefault: true)]
        XCTAssertEqual(CodexModels.applying(config: ["model": NSNull(), "model_reasoning_effort": NSNull()], to: models), models)
        XCTAssertEqual(CodexModels.model(from: ["model": "unknown"])?.defaultReasoning, "")
    }

    func testCustomConfiguredModelDoesNotInventCapabilities() {
        let models = CodexModels.applying(config: ["model": "custom"], to: [AgentModel(id: "m", isDefault: true)])
        XCTAssertEqual(models.map(\.isDefault), [false, true])
        XCTAssertEqual(models.last?.id, "custom")
        XCTAssertEqual(models.last?.reasoning, [])
        XCTAssertEqual(models.last?.defaultReasoning, "")
    }

    func testModelFromRowRequiresIdentity() {
        XCTAssertNil(CodexModels.model(from: ["displayName": "no id"]))
        XCTAssertEqual(CodexModels.model(from: ["id": "legacy"])?.id, "legacy")
    }
}

final class CacheTests: XCTestCase {
    private var previousHome: String?
    private var scratch = ""

    override func setUpWithError() throws {
        previousHome = ProcessInfo.processInfo.environment["HOME"]
        scratch = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("aux/agent-cache-\(UUID().uuidString)").path
        setenv("HOME", scratch, 1)
    }

    override func tearDownWithError() throws {
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        if FileManager.default.fileExists(atPath: scratch) { try FileManager.default.removeItem(atPath: scratch) }
    }

    func testOldCacheIsRejectedEvenAsStaleData() throws {
        let path = URL(fileURLWithPath: AgentCatalogStore.cachePath())
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = #"{"version":1,"entries":{"pi":{"agent":"pi","tool_path":"/fake/pi","fetched_at":0,"models":[{"id":"unresolved"}],"warning":""}}}"#
        try Data(old.utf8).write(to: path)
        XCTAssertNil(AgentCatalogStore.cachedCatalog(agent: "pi"))
        XCTAssertTrue(AgentCatalogStore.loadCache().entries.isEmpty)
    }

    func testCatalogWithoutToolReturnsWarning() async {
        let previous = AgentCatalogStore.locateTool
        AgentCatalogStore.locateTool = { _ in nil }
        defer { AgentCatalogStore.locateTool = previous }
        let catalog = await AgentCatalogStore.catalog(agent: "pi")
        XCTAssertTrue(catalog.models.isEmpty)
        XCTAssertTrue(catalog.warning.contains("not found"))
    }

    func testFreshCacheSkipsDiscovery() async {
        let previous = AgentCatalogStore.locateTool
        AgentCatalogStore.locateTool = { _ in "/fake/pi" }
        defer { AgentCatalogStore.locateTool = previous }
        let store = AgentCatalogStore.self
        // Seed a fresh entry directly.
        var file = store.loadCache()
        file.entries["pi"] = .init(
            agent: "pi", toolPath: "/fake/pi", fetchedAt: Date().timeIntervalSince1970,
            models: [AgentModel(id: "glm-5.3", provider: "zai")], warning: "")
        store.writeCache(file)
        let catalog = await store.catalog(agent: "pi")
        XCTAssertEqual(catalog.models.first?.id, "glm-5.3")
        XCTAssertTrue(catalog.warning.isEmpty)
    }

    func testFailedDiscoveryServesStaleWithWarning() async {
        let previous = AgentCatalogStore.locateTool
        AgentCatalogStore.locateTool = { _ in "/fake/pi" }
        defer { AgentCatalogStore.locateTool = previous }
        let store = AgentCatalogStore.self
        var file = store.loadCache()
        file.entries["pi"] = .init(
            agent: "pi", toolPath: "/fake/pi", fetchedAt: Date().timeIntervalSince1970 - 3600,
            models: [AgentModel(id: "glm-5.3", provider: "zai")], warning: "")
        store.writeCache(file)
        // locateTool claims pi exists but the real discovery subprocess fails on
        // the fake path; the store must fall back to the stale entry.
        let catalog = await store.catalog(agent: "pi", refresh: true)
        XCTAssertEqual(catalog.models.first?.id, "glm-5.3")
        XCTAssertTrue(catalog.warning.contains("refresh failed"), catalog.warning)
    }
}
