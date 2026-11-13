import XCTest
@testable import RaptorConfig

final class ConfigTests: XCTestCase {
    private func home() -> String { NSTemporaryDirectory() + "raptor-cfg-\(UUID().uuidString)" }

    private func writeConfig(_ body: String, home: String) throws {
        let dir = home + "/.config/raptor"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try body.write(toFile: dir + "/config.toml", atomically: true, encoding: .utf8)
    }

    func testLoadQuotedTargetsWithSpaces() throws {
        let h = home()
        setenv("HOME", h, 1)
        defer { setenv("HOME", String(cString: getenv("HOME")), 1) }
        for value in ["[\"tab\", \"session\", \"here\", \"pane_right\", \"pane_below\"]",
                      "['tab', 'session', 'here', 'pane_right', 'pane_below']"] {
            try writeConfig("targets = " + value + "\n", home: h)
            XCTAssertEqual(RaptorConfig.load().targets, ["tab", "session", "here", "pane_right", "pane_below"], value)
        }
    }

    func testAvailableTargets() {
        let all = ["session", "tab", "here", "pane_right", "pane_below"]
        for cfg in [RaptorConfig.default(), RaptorConfig(worktreeRoot: nil)] {
            XCTAssertEqual(cfg.availableTargets(hasBlock: true), all)
            XCTAssertEqual(cfg.availableTargets(hasBlock: false), ["session", "tab"])
        }
        let custom = RaptorConfig(targets: ["session", "pane_below", "tab", "session"])
        XCTAssertEqual(custom.availableTargets(hasBlock: true), ["session", "pane_below", "tab"])
    }

    func testLoadDefaultsWhenMissing() {
        setenv("HOME", home(), 1)
        defer { setenv("HOME", String(cString: getenv("HOME")), 1) }
        let cfg = RaptorConfig.load()
        XCTAssertEqual(cfg.enter, "session")
        XCTAssertEqual(cfg.slugLen, 24)
        XCTAssertEqual(cfg.targets, ["session", "tab", "here", "pane_right", "pane_below"])
        XCTAssertTrue(cfg.worktreeRoot.hasSuffix("/Workspace/worktrees"))
        XCTAssertTrue(cfg.pins.isEmpty)
    }

    func testExplicitTabTargetIsPreserved() throws {
        let h = home()
        let originalHome = String(cString: getenv("HOME"))
        setenv("HOME", h, 1)
        defer { setenv("HOME", originalHome, 1) }
        try writeConfig("enter = \"tab\"\n", home: h)
        XCTAssertEqual(RaptorConfig.load().enter, "tab")
    }

    func testSavePinsPreservesOtherLines() throws {
        let h = home()
        setenv("HOME", h, 1)
        defer { setenv("HOME", String(cString: getenv("HOME")), 1) }
        try writeConfig("enter = \"session\"\npins = [\"/old\"]\ntargets = [\"tab\"]\n", home: h)
        try RaptorConfig.savePins(["/new/one", "/new/two"])
        let text = try String(contentsOfFile: RaptorConfig.configPath(), encoding: .utf8)
        XCTAssertTrue(text.contains("enter = \"session\""))
        XCTAssertTrue(text.contains("targets = [\"tab\"]"))
        XCTAssertTrue(text.contains("pins = [\"/new/one\", \"/new/two\"]"))
        XCTAssertFalse(text.contains("/old"))
        XCTAssertEqual(RaptorConfig.loadPins(), ["/new/one", "/new/two"])
    }

    func testSessionPinsPersistWithHostIdentityAndPreserveDirectoryConfig() throws {
        let h = home()
        let originalHome = String(cString: getenv("HOME"))
        setenv("HOME", h, 1)
        defer {
            setenv("HOME", originalHome, 1)
            try? FileManager.default.removeItem(atPath: h)
        }
        let config = "enter = \"tab\"\npins = [\"/project\"]\n"
        try writeConfig(config, home: h)
        XCTAssertTrue(RaptorConfig.loadSessionPins().isEmpty)
        let host = "host,with\"quotes\\and-unicode-猫"
        XCTAssertTrue(try RaptorConfig.toggleSessionPin(sessionID: "session:1", host: host))
        XCTAssertTrue(try RaptorConfig.toggleSessionPin(sessionID: "session:1", host: "other"))
        XCTAssertEqual(RaptorConfig.loadSessionPins(), [
            SessionPin(sessionID: "session:1", host: host),
            SessionPin(sessionID: "session:1", host: "other"),
        ])
        XCTAssertFalse(try RaptorConfig.toggleSessionPin(sessionID: "session:1", host: host))
        XCTAssertEqual(RaptorConfig.loadSessionPins(), [SessionPin(sessionID: "session:1", host: "other")])
        XCTAssertEqual(RaptorConfig.loadPins(), ["/project"])
        XCTAssertEqual(try String(contentsOfFile: RaptorConfig.configPath(), encoding: .utf8), config)
        try RaptorConfig.savePins(["/new"])
        XCTAssertEqual(RaptorConfig.loadSessionPins(), [SessionPin(sessionID: "session:1", host: "other")])
    }

    func testTogglePinAddsAndRemoves() throws {
        let h = home()
        setenv("HOME", h, 1)
        defer { setenv("HOME", String(cString: getenv("HOME")), 1) }
        XCTAssertTrue(try RaptorConfig.togglePin("/tmp/proj"))
        XCTAssertEqual(RaptorConfig.loadPins(), ["/tmp/proj"])
        XCTAssertFalse(try RaptorConfig.togglePin("/tmp/proj"))
        XCTAssertTrue(RaptorConfig.loadPins().isEmpty)
    }

    private func writeAgentConfig(_ body: String, home: String) throws {
        try writeConfig(body, home: home)
    }

    func testSaveAgentAppendsAndRewritesTargetedLines() throws {
        let h = home()
        let originalHome = String(cString: getenv("HOME"))
        setenv("HOME", h, 1)
        defer { setenv("HOME", originalHome, 1) }
        try writeAgentConfig("enter = \"tab\"\n\npins = []\n", home: h)
        try RaptorConfig.saveAgent(agent: "pi", model: "glm-5.3", reasoning: "max")
        let cfg = RaptorConfig.load()
        XCTAssertEqual(cfg.agent, "pi")
        XCTAssertEqual(cfg.agentModel, "glm-5.3")
        XCTAssertEqual(cfg.agentReasoning, "max")
        // Rewrites update only the three agent lines.
        try RaptorConfig.saveAgent(agent: "codex", model: "gpt-6-luna", reasoning: "high")
        let updated = RaptorConfig.load()
        XCTAssertEqual(updated.agent, "codex")
        XCTAssertEqual(updated.agentModel, "gpt-6-luna")
        XCTAssertEqual(updated.agentReasoning, "high")
        let source = try String(contentsOfFile: RaptorConfig.configPath(), encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "agent =").count - 1, 1, source)
        XCTAssertTrue(source.contains("pins = []"), source)
        XCTAssertTrue(source.contains("enter = \"tab\""), source)
    }

    func testSaveAgentRemovesClearedDefaults() throws {
        let h = home()
        let originalHome = String(cString: getenv("HOME"))
        setenv("HOME", h, 1)
        defer { setenv("HOME", originalHome, 1) }
        try writeAgentConfig("agent = \"pi\"\nagent_model = \"glm-5.3\"\n", home: h)
        try RaptorConfig.saveAgent(agent: "none", model: "", reasoning: "")
        let source = try String(contentsOfFile: RaptorConfig.configPath(), encoding: .utf8)
        XCTAssertTrue(source.contains("agent = \"none\""), source)
        XCTAssertFalse(source.contains("agent_model"), source)
        XCTAssertFalse(source.contains("agent_reasoning"), source)
        let cfg = RaptorConfig.load()
        XCTAssertEqual(cfg.agent, "none") // explicit no-launch default persists
        XCTAssertEqual(cfg.agentModel, "")
    }

    func testAgentChoicesExcludeNoneAndDuplicates() {
        var cfg = RaptorConfig(agents: ["pi", "none", "", "codex", "pi"])
        XCTAssertEqual(cfg.agentChoices(), ["pi", "codex"])
        cfg = RaptorConfig(agents: [])
        XCTAssertEqual(cfg.agentChoices(), ["pi", "codex"])
    }
}
