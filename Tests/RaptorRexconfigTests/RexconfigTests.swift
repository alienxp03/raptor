import XCTest
@testable import RaptorRexconfig

final class RexconfigTests: XCTestCase {
    private func tempDir() -> String {
        NSTemporaryDirectory() + "raptor-rexconfig-\(UUID().uuidString)"
    }

    private func write(_ path: String, _ content: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func testApplyCreatesAndStaysIdempotent() throws {
        let path = tempDir() + "/rex/init.lua"
        var created = try Rexconfig.apply(configPath: path, plugin: "/opt/r/share/raptor/init.lua", options: Rexconfig.defaultOptions(), force: false)
        XCTAssertTrue(created)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        for want in [beginMarker, "dofile(\"/opt/r/share/raptor/init.lua\")", "rex.bind(\"shift+cmd+o\", \"raptor\")", endMarker] {
            XCTAssertTrue(text.contains(want), "missing \(want) in \(text)")
        }
        created = try Rexconfig.apply(configPath: path, plugin: "/opt/r/share/raptor/init.lua", options: Rexconfig.defaultOptions(), force: false)
        XCTAssertFalse(created, "reapply must edit in place")
        let text2 = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(text, text2, "idempotent rerun changed the file")
    }

    func testApplyReplacesManagedBlockAndTrailingContent() throws {
        let path = tempDir() + "/init.lua"
        try write(path, "rex.bind(\"cmd+k\", \"pane.send_key\")\n" + beginMarker + "\nold-stuff\nrequire(\"raptor\").setup{}\n" + endMarker + "\nrex.bind(\"cmd+b\", \"client.sidebar.toggle\")\n")
        _ = try Rexconfig.apply(configPath: path, plugin: "/new/plugin.lua", options: Options(), force: false)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(text.contains("old-stuff"), "managed block not replaced: \(text)")
        XCTAssertTrue(text.contains("cmd+k") && text.contains("cmd+b") && text.contains("/new/plugin.lua"), "surrounding config damaged: \(text)")
    }

    func testApplyRefusesForeignRaptorConfig() throws {
        let path = tempDir() + "/init.lua"
        try write(path, "rex.bind(\"shift+cmd+o\", function() rex.invoke(\"raptor\") end)\n")
        XCTAssertThrowsError(try Rexconfig.apply(configPath: path, plugin: "", options: Rexconfig.defaultOptions(), force: false), "foreign raptor wiring must be refused")
        var text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(text.contains(beginMarker), "refused run must not modify the file")
        _ = try Rexconfig.apply(configPath: path, plugin: "", options: Rexconfig.defaultOptions(), force: true)
        text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.components(separatedBy: "invoke(\"raptor\")").count - 1 == 1 && text.contains(beginMarker), "force merge damaged the config: \(text)")
    }

    func testApplyTruncatedMarkersFailClosed() throws {
        let path = tempDir() + "/init.lua"
        try write(path, beginMarker + "\nbroken\n")
        XCTAssertThrowsError(try Rexconfig.apply(configPath: path, plugin: "", options: Rexconfig.defaultOptions(), force: true), "truncated markers must fail closed")
    }

    func testApplyRequireFallbackAndCommentsIgnored() throws {
        let path = tempDir() + "/init.lua"
        try write(path, "-- raptor bindings live in the managed block below\n")
        _ = try Rexconfig.apply(configPath: path, plugin: "", options: Rexconfig.defaultOptions(), force: false)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains("require(\"raptor\")"), "missing plugin fallback: \(text)")
    }

    func testConfigPathEnv() {
        setenv("REX_CONFIG", "/custom/rex.lua", 1)
        defer { unsetenv("REX_CONFIG") }
        XCTAssertEqual(Rexconfig.configPath(), "/custom/rex.lua")
        unsetenv("REX_CONFIG")
        setenv("XDG_CONFIG_HOME", "/xdg", 1)
        defer { unsetenv("XDG_CONFIG_HOME") }
        XCTAssertEqual(Rexconfig.configPath(), "/xdg/rex/init.lua")
    }

    func testLocatePluginFindsAppBundle() throws {
        let root = tempDir()
        let app = root + "/Applications/Raptor.app"
        try write(app + "/Contents/MacOS/Raptor", "binary")
        try write(app + "/Contents/Resources/rex/init.lua", "-- plugin")
        setenv("HOME", root, 1)
        defer { unsetenv("HOME") }
        setenv("HOMEBREW_PREFIX", "", 1)
        defer { unsetenv("HOMEBREW_PREFIX") }
        setenv("REX_CONFIG", root + "/rex.lua", 1)
        defer { unsetenv("REX_CONFIG") }
        setenv("XDG_CONFIG_HOME", root + "/config", 1)
        defer { unsetenv("XDG_CONFIG_HOME") }
        XCTAssertEqual(Rexconfig.locatePlugin(), app + "/Contents/Resources/rex/init.lua")
    }

    /// Byte-identical managed block output, matching Go's Block() for the
    /// same input.
    func testBlockOutputIsByteIdentical() {
        let want = """
        -- >>> raptor >>>
        local raptor = dofile("/opt/r/share/raptor/init.lua")
        raptor.setup{}
        rex.bind("shift+cmd+o", "raptor")
        rex.bind("shift+cmd+n", "raptor_worktree_new")
        rex.bind("ctrl+shift+n", "raptor_worktree_agent")
        -- <<< raptor <<<

        """
        XCTAssertEqual(Rexconfig.block(plugin: "/opt/r/share/raptor/init.lua", options: Rexconfig.defaultOptions()), want)
        XCTAssertEqual(
            Rexconfig.block(plugin: "", options: Rexconfig.defaultOptions()),
            "-- >>> raptor >>>\nlocal raptor = require(\"raptor\")\nraptor.setup{}\nrex.bind(\"shift+cmd+o\", \"raptor\")\nrex.bind(\"shift+cmd+n\", \"raptor_worktree_new\")\nrex.bind(\"ctrl+shift+n\", \"raptor_worktree_agent\")\n-- <<< raptor <<<\n"
        )
    }
}

func testStabilizeOptRewritesCellarPaths() {
    XCTAssertEqual(Rexconfig.stabilizeOpt("/opt/homebrew/Cellar/raptor/HEAD-1234/share/raptor/init.lua"),
                   "/opt/homebrew/opt/raptor/share/raptor/init.lua")
    XCTAssertEqual(Rexconfig.stabilizeOpt("/opt/homebrew/Cellar/raptor/0.1.0/libexec/Raptor.app/Contents/Resources/rex/init.lua"),
                   "/opt/homebrew/opt/raptor/libexec/Raptor.app/Contents/Resources/rex/init.lua")
    XCTAssertEqual(Rexconfig.stabilizeOpt("/usr/local/Cellar/raptor/1.2.3/share/raptor/init.lua"),
                   "/usr/local/opt/raptor/share/raptor/init.lua")
    XCTAssertEqual(Rexconfig.stabilizeOpt("/Users/x/.local/bin/raptor"), "/Users/x/.local/bin/raptor")
    XCTAssertEqual(Rexconfig.stabilizeOpt("/opt/homebrew/Cellar/raptor/"), "/opt/homebrew/Cellar/raptor/")
}
