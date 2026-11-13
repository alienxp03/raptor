import Foundation
import RaptorAgent
import RaptorConfig
import RaptorRex
import XCTest
@testable import RaptorAPI

final class AgentCatalogMethodTests: APITestCase {
    func testCatalogWithoutToolWarnsAndStaysEmpty() async throws {
        let home = makeTempDir()
        env.set("HOME", home)
        let original = AgentCatalogStore.locateTool
        AgentCatalogStore.locateTool = { _ in nil }
        env.addTeardown { AgentCatalogStore.locateTool = original }
        let call = makeClient(self, Handler(ctx: Ctx(), cfg: .default()))
        let body = call("agents.catalog", .object(["agent": .string("pi")])) { result in
            let dict = try jsonDict(result)
            XCTAssertEqual(dict["agent"] as? String, "pi")
            XCTAssertEqual((dict["agent_models"] as? [Any])?.count, 0)
            let warning = dict["agent_warning"] as? String ?? ""
            XCTAssertTrue(warning.contains("not found"), warning)
        }
        XCTAssertEqual(body, "")
        // The warning path must not poison the cache for a later good run.
        XCTAssertNil(AgentCatalogStore.cachedCatalog(agent: "pi"))
    }

    func testCatalogRejectsUnknownAgent() throws {
        let call = makeClient(self, Handler(ctx: Ctx(), cfg: .default()))
        _ = call("agents.catalog", .object(["agent": .string("claude")])) { _ in }
    }

    func testSaveAgentWritesAndReloadsConfig() throws {
        let home = makeTempDir()
        let dir = home + "/.config/raptor"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "enter = \"tab\"\n".write(toFile: dir + "/config.toml", atomically: true, encoding: .utf8)
        env.set("HOME", home)
        let call = makeClient(self, Handler(ctx: Ctx(), cfg: .default()))
        let body = call("config.saveAgent", .object([
            "agent": .string("pi"),
            "agent_provider": .string("zai"),
            "agent_model": .string("glm-5.3"),
            "agent_reasoning": .string("max"),
        ])) { result in
            XCTAssertEqual(try jsonDict(result).keys.sorted(), [])
        }
        XCTAssertEqual(body, "")
        let cfg = RaptorConfig.load()
        XCTAssertEqual(cfg.agent, "pi")
        XCTAssertEqual(cfg.agentModel, "glm-5.3")
        XCTAssertEqual(cfg.agentReasoning, "max")
        // Unrelated lines survive untouched.
        let source = try String(contentsOfFile: dir + "/config.toml", encoding: .utf8)
        XCTAssertTrue(source.contains("enter = \"tab\""), source)
        XCTAssertTrue(source.contains("agent_model = \"glm-5.3\""), source)
    }
}
