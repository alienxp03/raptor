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

    func testApplyMigratesManagedPRBindingAndPreservesUserKeys() throws {
        let path = tempDir() + "/init.lua"
        let before = "rex.bind(\"shift+cmd+p\", \"session.switch\")\n"
        let after = "rex.bind(\"cmd+b\", \"client.sidebar.toggle\")\n"
        let oldBlock = Rexconfig.block(plugin: "/old/plugin.lua", options: Options(bindings: [
            ["shift+cmd+o", "raptor"],
            ["shift+cmd+p", "raptor_pr_open"],
        ]))
        try write(path, before + oldBlock + after)
        try Rexconfig.apply(configPath: path, plugin: "/new/plugin.lua", options: Rexconfig.defaultOptions(), force: false)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(text, before + Rexconfig.block(plugin: "/new/plugin.lua", options: Rexconfig.defaultOptions()) + after)
        XCTAssertTrue(text.contains("rex.bind(\"shift+cmd+c\", \"raptor_pr_open\")"))
        XCTAssertTrue(text.contains("rex.bind(\"shift+cmd+o\", \"raptor\")"))
        XCTAssertFalse(text.contains("rex.bind(\"shift+cmd+p\", \"raptor_pr_open\")"))
    }

    func testApplyPreservesUnmanagedPRBinding() throws {
        let path = tempDir() + "/init.lua"
        let userBinding = "rex.bind(\"shift+cmd+p\", \"raptor_pr_open\")\nrex.bind(\"cmd+1\", \"session.select\")\nrex.bind(\"ctrl+cmd+2\", \"custom_action\")\n"
        try write(path, userBinding + Rexconfig.block(plugin: "/old/plugin.lua", options: Options()))
        try Rexconfig.apply(configPath: path, plugin: "/new/plugin.lua", options: Rexconfig.defaultOptions(), force: false)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(text, userBinding + Rexconfig.block(plugin: "/new/plugin.lua", options: Rexconfig.defaultOptions()))
    }

    func testApplyRefusesForeignRaptorConfig() throws {
        let path = tempDir() + "/init.lua"
        try write(path, "rex.bind(\"shift+cmd+o\", function() rex.invoke(\"raptor\") end)\n")
        XCTAssertThrowsError(try Rexconfig.apply(configPath: path, plugin: "/installed/raptor/init.lua", options: Rexconfig.defaultOptions(), force: false), "foreign raptor wiring must be refused")
        var text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(text.contains(beginMarker), "refused run must not modify the file")
        _ = try Rexconfig.apply(configPath: path, plugin: "/installed/raptor/init.lua", options: Rexconfig.defaultOptions(), force: true)
        text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.components(separatedBy: "invoke(\"raptor\")").count - 1 == 1 && text.contains(beginMarker), "force merge damaged the config: \(text)")
    }

    func testApplyTruncatedMarkersFailClosed() throws {
        let path = tempDir() + "/init.lua"
        try write(path, beginMarker + "\nbroken\n")
        XCTAssertThrowsError(try Rexconfig.apply(configPath: path, plugin: "/installed/raptor/init.lua", options: Rexconfig.defaultOptions(), force: true), "truncated markers must fail closed")
    }

    func testApplyDirectLoadAndCommentsIgnored() throws {
        let path = tempDir() + "/init.lua"
        try write(path, "-- raptor bindings live in the managed block below\n")
        _ = try Rexconfig.apply(configPath: path, plugin: "/installed/raptor/init.lua", options: Rexconfig.defaultOptions(), force: false)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains("dofile(\"/installed/raptor/init.lua\").setup{}"), "missing direct load: \(text)")
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

    func testLocatePluginPrefersInstalledCopyOverLegacyApp() throws {
        let root = tempDir()
        setenv("HOME", root, 1)
        setenv("XDG_CONFIG_HOME", root + "/config", 1)
        defer { unsetenv("HOME"); unsetenv("XDG_CONFIG_HOME") }
        let plugin = root + "/config/rex/raptor/init.lua"
        try write(plugin, "-- installed plugin")
        try write(root + "/Applications/Raptor.app/Contents/MacOS/Raptor", "legacy")
        try write(root + "/Applications/Raptor.app/Contents/Resources/rex/init.lua", "-- legacy")
        XCTAssertEqual(Rexconfig.locatePlugin(), plugin)
    }

    /// Setup is one direct load followed by ordinary named bindings.
    func testBlockOutputIsByteIdentical() {
        let want = """
        -- >>> raptor >>>
        dofile("/opt/r/share/raptor/init.lua").setup{}
        rex.bind("shift+cmd+o", "raptor")
        rex.bind("shift+cmd+c", "raptor_pr_open")
        rex.bind("shift+cmd+n", "raptor_worktree_new")
        rex.bind("ctrl+shift+n", "raptor_worktree_agent")
        rex.bind("ctrl+cmd+1", "raptor_pin_1")
        rex.bind("ctrl+cmd+2", "raptor_pin_2")
        rex.bind("ctrl+cmd+3", "raptor_pin_3")
        rex.bind("ctrl+cmd+4", "raptor_pin_4")
        rex.bind("ctrl+cmd+5", "raptor_pin_5")
        rex.bind("ctrl+cmd+6", "raptor_pin_6")
        rex.bind("ctrl+cmd+7", "raptor_pin_7")
        rex.bind("ctrl+cmd+8", "raptor_pin_8")
        rex.bind("ctrl+cmd+9", "raptor_pin_9")
        -- <<< raptor <<<

        """
        XCTAssertEqual(Rexconfig.block(plugin: "/opt/r/share/raptor/init.lua", options: Rexconfig.defaultOptions()), want)
        XCTAssertFalse(want.contains("package.path"))
        XCTAssertFalse(want.contains("package.loaded"))
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
