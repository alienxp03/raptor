import Foundation
import XCTest
@testable import RaptorAgent

/// Execute the production helper with real installed Pi settings/resolver/clamp
/// code, but fixture models/auth/scope. No sessions, extensions, or user settings.
final class PiDefaultsTests: XCTestCase {
    private func discover(settings: [String: Any] = [:], scoped: [[String: Any]]? = nil,
                          includeSDKDefault: Bool = false) throws -> [AgentModel] {
        guard let pi = AgentCatalogStore.locateTool("pi"), let node = PiModels.locateNode(),
              let sdk = PiModels.packageRoot(piPath: pi) else {
            throw XCTSkip("requires installed Pi SDK and node")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("aux/pi-defaults-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws {
            let file = root.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        func json(_ value: Any) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
        }
        let models: [[String: Any]] = [
            ["id": "first", "provider": "fixture", "reasoning": true],
            ["id": "saved", "provider": "fixture", "reasoning": true],
            ["id": "saved", "provider": "other", "reasoning": true],
            ["id": "plain", "provider": "fixture", "reasoning": false],
        ]
        var config = settings
        if scoped != nil { config["enabledModels"] = ["fixture/*"] }
        try write("settings.json", try json(config))
        // Untrusted project settings must not change the global default.
        try write(".pi/settings.json", #"{"defaultModel":"first","defaultThinkingLevel":"low"}"#)
        try write("package.json", #"{"name":"@earendil-works/pi-coding-agent","type":"module","main":"index.js"}"#)
        try write("index.js", """
        export { SettingsManager } from \(try json(sdk + "/dist/index.js"));
        export const getAgentDir = () => \(try json(root.path));
        const models = \(try json(models));
        if (\(includeSDKDefault)) {
          const { defaultModelPerProvider } = await import(\(try json(sdk + "/dist/core/model-resolver.js")));
          models.push({ id: defaultModelPerProvider.openai, provider: "openai", reasoning: true });
        }
        const scoped = \(try json(scoped ?? []));
        export const ModelRuntime = { create: async () => ({
          getAvailable: async () => models,
          getAvailableSnapshot: () => models,
          getModel: (provider, id) => models.find(m => m.provider === provider && m.id === id),
          hasConfiguredAuth: () => true,
        }) };
        export const resolveModelScopeWithDiagnostics = async () => ({
          scopedModels: scoped.map(e => ({ model: models.find(m => m.id === e.id && m.provider === e.provider), thinkingLevel: e.thinkingLevel })),
          diagnostics: [],
        });
        """)
        for (destination, source) in [
            ("dist/core/defaults.js", sdk + "/dist/core/defaults.js"),
            ("dist/core/model-resolver.js", sdk + "/dist/core/model-resolver.js"),
            ("node_modules/@earendil-works/pi-ai/dist/compat.js", sdk + "/node_modules/@earendil-works/pi-ai/dist/compat.js"),
        ] {
            let link = root.appendingPathComponent(destination)
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: source)
        }
        try write("helper.mjs", PiModels.script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [root.appendingPathComponent("helper.mjs").path, root.path]
        process.currentDirectoryURL = root
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, stderr)
        return try XCTUnwrap(PiModels.parseOutput(String(decoding: data, as: UTF8.self))).models
    }

    func testSavedDefaultIsNotFirstAndUsesProviderQualifiedOverride() throws {
        let models = try discover(settings: [
            "defaultProvider": "fixture", "defaultModel": "saved", "defaultThinkingLevel": "high",
            "modelThinkingLevels": ["fixture/saved": "low"],
        ])
        XCTAssertEqual(models.filter(\.isDefault).map { $0.provider + "/" + $0.id }, ["fixture/saved"])
        XCTAssertEqual(models.map(\.defaultReasoning), ["high", "low", "high", "off"])
    }

    func testSDKSelectsProviderDefaultRatherThanFirstCatalogModel() throws {
        let models = try discover(settings: ["defaultProvider": "fixture", "defaultModel": "missing"],
                                  includeSDKDefault: true)
        XCTAssertEqual(models.filter(\.isDefault).count, 1)
        XCTAssertEqual(models.last?.isDefault, true)
        XCTAssertEqual(models.last?.provider, "openai")
        XCTAssertEqual(models.first?.isDefault, false)
    }

    func testSDKFallbackThinkingAndCapabilityClamp() throws {
        let models = try discover(settings: ["defaultProvider": "fixture", "defaultModel": "saved"])
        XCTAssertEqual(models.map(\.defaultReasoning), ["medium", "medium", "medium", "off"])
        let clamped = try discover(settings: ["defaultThinkingLevel": "max"])
        XCTAssertEqual(clamped.map(\.defaultReasoning), ["high", "high", "high", "off"])
    }

    func testScopedThinkingOverridesSettingsAndSavedModelWinsWithinScope() throws {
        let models = try discover(settings: [
            "defaultProvider": "fixture", "defaultModel": "saved", "defaultThinkingLevel": "high",
            "modelThinkingLevels": ["fixture/saved": "low"],
        ], scoped: [
            ["id": "first", "provider": "fixture", "thinkingLevel": "off"],
            ["id": "saved", "provider": "fixture", "thinkingLevel": "max"],
        ])
        XCTAssertEqual(models.map(\.isDefault), [false, true])
        XCTAssertEqual(models.map(\.defaultReasoning), ["off", "high"])
    }

    func testScopedModelWithoutExplicitLevelUsesPerModelSetting() throws {
        let models = try discover(settings: [
            "defaultThinkingLevel": "high", "modelThinkingLevels": ["fixture/saved": "low"],
        ], scoped: [["id": "saved", "provider": "fixture"]])
        XCTAssertEqual(models.first?.defaultReasoning, "low")
        XCTAssertEqual(models.first?.isDefault, true)
    }

    func testSavedModelOutsideScopeUsesPiScopeRuleNotUnscopedCatalogOrder() throws {
        let models = try discover(settings: ["defaultProvider": "fixture", "defaultModel": "saved"],
            scoped: [["id": "plain", "provider": "fixture"], ["id": "first", "provider": "fixture"]])
        XCTAssertEqual(models.filter(\.isDefault).map(\.id), ["plain"])
        XCTAssertEqual(models.map(\.defaultReasoning), ["off", "medium"])
    }
}
