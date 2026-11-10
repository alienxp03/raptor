import Foundation
import XCTest

@testable import RaptorTheme

final class RaptorThemeTests: XCTestCase {
    private let fixtureThemes = """
    [
      {
        "id": "test-dusk",
        "name": "Test Dusk",
        "appearance": "dark",
        "source": {
          "background": "#171412",
          "foreground": "#ddd0bf",
          "cursor": "#e8a860",
          "selectionBackground": "#423528",
          "selectionForeground": "#f2e9dc",
          "ansi": ["#26201c", "#d96e56", "#a0b06a", "#e0a45c", "#8598b0", "#bd8aa2", "#92b39c", "#c2b4a3",
                   "#6e6355", "#e88a72", "#b8c786", "#efbc7c", "#a0b2c8", "#d1a5b8", "#accab4", "#f2e9dc"]
        },
        "semantic": {
          "terminalBackground": {"colorSpace": "display-p3", "red": 0.08834, "green": 0.0788, "blue": 0.0714, "alpha": 1},
          "terminalForeground": {"colorSpace": "display-p3", "red": 0.85, "green": 0.8, "blue": 0.72, "alpha": 1},
          "terminalCursor": {"colorSpace": "display-p3", "red": 0.92, "green": 0.66, "blue": 0.36, "alpha": 1},
          "terminalSelection": {"colorSpace": "display-p3", "red": 0.27, "green": 0.21, "blue": 0.16, "alpha": 1},
          "terminalSelectionForeground": {"colorSpace": "display-p3", "red": 0.94, "green": 0.9, "blue": 0.85, "alpha": 1},
          "surfaceRaised": {"colorSpace": "display-p3", "red": 0.152, "green": 0.143, "blue": 0.135, "alpha": 1},
          "accentSolid": {"colorSpace": "display-p3", "red": 0.72, "green": 0.51, "blue": 0.26, "alpha": 1},
          "terminalAnsi0": {"colorSpace": "display-p3", "red": 0.149, "green": 0.125, "blue": 0.11, "alpha": 1},
          "terminalAnsi1": {"colorSpace": "display-p3", "red": 0.85, "green": 0.43, "blue": 0.34, "alpha": 1},
          "terminalAnsi2": {"colorSpace": "display-p3", "red": 0.72, "green": 0.78, "blue": 0.53, "alpha": 1},
          "terminalAnsi3": {"colorSpace": "display-p3", "red": 0.94, "green": 0.74, "blue": 0.49, "alpha": 1},
          "terminalAnsi4": {"colorSpace": "display-p3", "red": 0.63, "green": 0.7, "blue": 0.79, "alpha": 1},
          "terminalAnsi5": {"colorSpace": "display-p3", "red": 0.83, "green": 0.54, "blue": 0.72, "alpha": 1},
          "terminalAnsi6": {"colorSpace": "display-p3", "red": 0.67, "green": 0.79, "blue": 0.71, "alpha": 1},
          "terminalAnsi7": {"colorSpace": "display-p3", "red": 0.76, "green": 0.71, "blue": 0.64, "alpha": 1},
          "terminalAnsi8": {"colorSpace": "display-p3", "red": 0.43, "green": 0.39, "blue": 0.33, "alpha": 1},
          "terminalAnsi9": {"colorSpace": "display-p3", "red": 0.91, "green": 0.54, "blue": 0.45, "alpha": 1},
          "terminalAnsi10": {"colorSpace": "display-p3", "red": 0.72, "green": 0.78, "blue": 0.53, "alpha": 1},
          "terminalAnsi11": {"colorSpace": "display-p3", "red": 0.94, "green": 0.74, "blue": 0.49, "alpha": 1},
          "terminalAnsi12": {"colorSpace": "display-p3", "red": 0.63, "green": 0.7, "blue": 0.79, "alpha": 1},
          "terminalAnsi13": {"colorSpace": "display-p3", "red": 0.82, "green": 0.65, "blue": 0.72, "alpha": 1},
          "terminalAnsi14": {"colorSpace": "display-p3", "red": 0.67, "green": 0.79, "blue": 0.71, "alpha": 1},
          "terminalAnsi15": {"colorSpace": "display-p3", "red": 0.95, "green": 0.91, "blue": 0.86, "alpha": 1}
        }
      },
      {
        "id": "test-dawn",
        "name": "Test Dawn",
        "appearance": "light",
        "source": {
          "background": "#fafafa",
          "foreground": "#333940",
          "cursor": "#4a90d9",
          "selectionBackground": "#d6e6f7",
          "selectionForeground": "#333940",
          "ansi": ["#333940", "#c94f46", "#4a9256", "#b28422", "#3d7cc9", "#8a5fb0", "#2e8fa0", "#d7dade",
                   "#757d86", "#e0655b", "#58ab66", "#c9982e", "#5292dd", "#a075c6", "#3ba6b8", "#ffffff"]
        }
      }
    ]
    """

    private let basePrefs = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>Workspace.darkThemeID</key><string>test-dusk</string>
    <key>Workspace.lightThemeID</key><string>test-dawn</string>
    </dict></plist>
    """

    // MARK: - Helpers

    /// Installs a fake Rex app bundle and preference export.
    private func fixture(prefsPlist: String, customJSON: String) throws -> RaptorTheme.Options {
        let app = NSTemporaryDirectory() + "raptor-theme-\(UUID().uuidString)"
        let dir = app + "/Contents/Resources/SuperUI_SuperDesignTokens.bundle/Contents/Resources"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try fixtureThemes.write(toFile: dir + "/themes.json", atomically: true, encoding: .utf8)
        var prefs = prefsPlist
        if !customJSON.isEmpty {
            prefs = replaceFirst(prefs, "</dict>",
                                 "<key>Workspace.customThemes</key><data>" + customJSON + "</data></dict>")
        }
        let plist = prefs
        return RaptorTheme.Options(
            rexApp: app,
            defaultsOutput: { Data(plist.utf8) },
            systemIsDark: { true }
        )
    }

    /// First-occurrence literal replacement, like strings.Replace(s, old, new, 1).
    private func replaceFirst(_ source: String, _ target: String, _ replacement: String) -> String {
        guard let range = source.range(of: target) else { return source }
        return source.replacingCharacters(in: range, with: replacement)
    }

    /// Wraps JSON text as a plist <data> payload (base64).
    private func customLabel(_ json: String) -> String {
        Data(json.utf8).base64EncodedString()
    }

    private func assertUnavailable(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(ThemeError.isUnavailable(error), "want ErrUnavailable, got \(error)", file: file, line: line)
    }

    private func assertNoUIJSON(_ th: Theme, file: StaticString = #filePath, line: UInt = #line) {
        guard let data = try? JSONEncoder().encode(th),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("theme does not marshal: \(th)", file: file, line: line)
            return
        }
        XCTAssertNil(th.ui, file: file, line: line)
        XCTAssertNil(fields["ui"], "unexpected UI palette: \(String(data: data, encoding: .utf8) ?? "")", file: file, line: line)
    }

    // MARK: - Tests

    func testResolveDarkViaSystemAppearance() throws {
        let th = try RaptorTheme.resolve(try fixture(prefsPlist: basePrefs, customJSON: ""))
        XCTAssertEqual(th.interfaceStyle, "modern")
        XCTAssertEqual(th.name, "Test Dusk")
        XCTAssertTrue(th.isDark)
        XCTAssertEqual(th.background, "#171412")
        XCTAssertEqual(th.surface, "#272422")
        XCTAssertEqual(th.ansi.count, 16)
        XCTAssertTrue(th.ansi[9].hasPrefix("#"))
        XCTAssertFalse(th.selectionForeground.isEmpty)
        XCTAssertFalse(th.accent.isEmpty)
    }

    func testResolveSelectsLightWhenSystemLight() throws {
        var opts = try fixture(prefsPlist: basePrefs, customJSON: "")
        opts.systemIsDark = { false }
        let th = try RaptorTheme.resolve(opts)
        // test-dawn has no semantic block: resolution must fall back to source.
        XCTAssertEqual(th.name, "Test Dawn")
        XCTAssertFalse(th.isDark)
        XCTAssertEqual(th.background, "#fafafa")
        XCTAssertEqual(th.ansi[15], "#ffffff")
    }

    func testResolveAppearanceOverridesSystem() throws {
        let prefs = replaceFirst(basePrefs, "<dict>", "<dict><key>Workspace.appearance</key><string>light</string>")
        let th = try RaptorTheme.resolve(try fixture(prefsPlist: prefs, customJSON: ""))
        XCTAssertEqual(th.name, "Test Dawn")
    }

    func testResolveInterfaceStyles() throws {
        for style in ["modern", "classic", "blendTheme", "useTheme", "unknown"] {
            let prefs = replaceFirst(basePrefs, "<dict>",
                                     "<dict><key>Workspace.appearance</key><string>dark</string>" +
                                         "<key>Workspace.interfaceStyle</key><string>" + style + "</string>")
            let opts = try fixture(prefsPlist: prefs, customJSON: "")
            if style == "unknown" {
                do {
                    _ = try RaptorTheme.resolve(opts)
                    XCTFail("want ErrUnavailable for \(style)")
                } catch {
                    assertUnavailable(error)
                }
                continue
            }
            let th = try RaptorTheme.resolve(opts)
            XCTAssertEqual(th.interfaceStyle, style, style)
            XCTAssertEqual(th.name, "Test Dusk", style)
            XCTAssertTrue(th.isDark, style)
            XCTAssertEqual(th.background, "#171412", style)
            XCTAssertEqual(th.surface, "#272422", style)
        }
    }

    func testResolveRefreshesPreferences() throws {
        var opts = try fixture(prefsPlist: basePrefs, customJSON: "")
        var prefs = basePrefs
        opts.defaultsOutput = { Data(prefs.utf8) }
        for id in ["test-dusk", "test-dawn", "no-such-theme", "test-dusk"] {
            prefs = replaceFirst(basePrefs, "test-dusk", id)
            if id == "no-such-theme" {
                do {
                    _ = try RaptorTheme.resolve(opts)
                    XCTFail("want ErrUnavailable, got success")
                } catch {
                    assertUnavailable(error)
                }
                continue
            }
            let th = try RaptorTheme.resolve(opts)
            let want = id == "test-dawn" ? "Test Dawn" : "Test Dusk"
            XCTAssertEqual(th.name, want, id)
        }
        prefs = replaceFirst(basePrefs, "<dict>",
                             "<dict><key>Workspace.interfaceStyle</key><string>unknown</string>")
        do {
            _ = try RaptorTheme.resolve(opts)
            XCTFail("want ErrUnavailable after style change")
        } catch {
            assertUnavailable(error)
        }
    }

    func testResolveRefreshesSystemAppearance() throws {
        var opts = try fixture(prefsPlist: basePrefs, customJSON: "")
        var dark = true
        opts.systemIsDark = { dark }
        for value in [true, false, true] {
            dark = value
            let th = try RaptorTheme.resolve(opts)
            let want = dark ? "Test Dusk" : "Test Dawn"
            XCTAssertEqual(th.name, want)
            XCTAssertEqual(th.isDark, dark)
        }
    }

    func testResolveRefreshesThemeCatalog() throws {
        let opts = try fixture(prefsPlist: basePrefs, customJSON: "")
        let catalogPath = (opts.rexApp as NSString).appendingPathComponent(RaptorTheme.tokensRelPath)
        for value in ["0.08834", "0.98834", "0.08834"] {
            let catalog = replaceFirst(fixtureThemes, "0.08834", value)
            try catalog.write(toFile: catalogPath, atomically: true, encoding: .utf8)
            let th = try RaptorTheme.resolve(opts)
            let want = value == "0.98834" ? p3ToSRGB(Color(r: 0.98834, g: 0.0788, b: 0.0714)).hex() : "#171412"
            XCTAssertEqual(th.background, want, value)
        }
        try FileManager.default.removeItem(atPath: catalogPath)
        do {
            _ = try RaptorTheme.resolve(opts)
            XCTFail("want ErrUnavailable after catalog removal")
        } catch {
            assertUnavailable(error)
        }
    }

    func testResolveMissingTheme() throws {
        let prefs = replaceFirst(basePrefs, "test-dusk", "no-such-theme")
        let opts = try fixture(prefsPlist: prefs, customJSON: "")
        do {
            _ = try RaptorTheme.resolve(opts)
            XCTFail("want ErrUnavailable")
        } catch {
            assertUnavailable(error)
        }
    }

    func testResolveCustomTheme() throws {
        let custom = """
        [{"id": "test-dusk", "name": "My Custom", "palette": {"ansi": ["#101010", "#ff5555", "#50fa7b", "#f1fa8d", "#bd93f9", "#ff79c6", "#8be9fd", "#bfbfbf", "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a8ffff", "#ffffff", "#extra"], "background": "#101010", "foreground": "#eeeeee", "cursor": "#ff8800", "selectionBackground": "#333333", "selectionForeground": "#ffffff"}}]
        """
        for style in ["modern", "classic", "blendTheme", "useTheme"] {
            let prefs = replaceFirst(basePrefs, "<dict>",
                                     "<dict><key>Workspace.interfaceStyle</key><string>" + style + "</string>")
            let th = try RaptorTheme.resolve(try fixture(prefsPlist: prefs, customJSON: customLabel(custom)))
            XCTAssertEqual(th.interfaceStyle, style, style)
            XCTAssertNil(th.ui, style)
            assertNoUIJSON(th)
        }
        let th = try RaptorTheme.resolve(try fixture(prefsPlist: basePrefs, customJSON: customLabel(custom)))
        XCTAssertEqual(th.name, "My Custom")
        XCTAssertEqual(th.background, "#101010")
        XCTAssertEqual(th.selection, "#333333")
        XCTAssertEqual(th.selectionForeground, "#ffffff")
        XCTAssertNotEqual(th.surface, th.background)
    }

    func testResolveLegacyOmitsUI() throws {
        for dark in [true, false] {
            var opts = try fixture(prefsPlist: basePrefs, customJSON: "")
            opts.systemIsDark = { dark }
            let th = try RaptorTheme.resolve(opts)
            assertNoUIJSON(th)
        }
    }

    func testResolveUIPalette() throws {
        for missing in ["", "surfaceRaised", "content", "selectionForeground", "controlOnOverlay"] {
            var entries = try JSONSerialization.jsonObject(with: Data(fixtureThemes.utf8), options: .mutableContainers) as! [[String: Any]]
            var semantic = entries[0]["semantic"] as! [String: Any]
            func color(_ r: Double, _ g: Double, _ b: Double) -> [String: Any] {
                ["red": r, "green": g, "blue": b, "colorSpace": "display-p3"]
            }
            semantic["content"] = color(0.7, 0.72, 0.69)
            semantic["selectionForeground"] = color(0.1, 0.13, 0.09)
            semantic["controlOnOverlay"] = color(0.2, 0.23, 0.19)
            if !missing.isEmpty {
                semantic.removeValue(forKey: missing)
            }
            entries[0]["semantic"] = semantic
            let opts = try fixture(prefsPlist: basePrefs, customJSON: "")
            func resolveCatalog() throws -> Theme {
                let data = try JSONSerialization.data(withJSONObject: entries)
                try data.write(to: URL(fileURLWithPath: (opts.rexApp as NSString).appendingPathComponent(RaptorTheme.tokensRelPath)))
                return try RaptorTheme.resolve(opts)
            }
            let terminal = try resolveCatalog()
            assertNoUIJSON(terminal)
            semantic["selection"] = color(0.72, 0.8, 0.67)
            entries[0]["semantic"] = semantic
            let th = try resolveCatalog()
            var want = UIPalette(
                background: terminal.surface,
                foreground: terminal.foreground,
                selection: p3ToSRGB(Color(r: 0.72, g: 0.8, b: 0.67)).hex(),
                selectionForeground: terminal.background,
                surface: terminal.surface
            )
            if missing != "content" {
                want.foreground = p3ToSRGB(Color(r: 0.7, g: 0.72, b: 0.69)).hex()
            }
            if missing != "selectionForeground" {
                want.selectionForeground = p3ToSRGB(Color(r: 0.1, g: 0.13, b: 0.09)).hex()
            }
            if missing != "controlOnOverlay" {
                want.surface = p3ToSRGB(Color(r: 0.2, g: 0.23, b: 0.19)).hex()
            }
            XCTAssertEqual(th.ui, want, "missing=\(missing)")
            XCTAssertNotEqual(th.ui?.selection, th.selection, "UI and terminal roles must differ: missing=\(missing)")
            XCTAssertNotEqual(th.ui?.selectionForeground, th.selectionForeground, "UI and terminal roles must differ: missing=\(missing)")
            XCTAssertNotEqual(th.ui?.background, th.background, "UI and terminal roles must differ: missing=\(missing)")
            let data = try JSONEncoder().encode(th)
            let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertEqual(payload["interfaceStyle"] as? String, "modern", "missing=\(missing)")
            XCTAssertEqual(payload["ui"] as? [String: String], [
                "background": want.background, "foreground": want.foreground,
                "selection": want.selection, "selectionForeground": want.selectionForeground,
                "surface": want.surface,
            ], String(data: data, encoding: .utf8) ?? "")
            var withoutUI = th
            withoutUI.ui = nil
            XCTAssertEqual(withoutUI, terminal, "UI tokens changed terminal palette: missing=\(missing)")
        }
    }

    func testHexHelpers() {
        XCTAssertEqual(normalizeHex("#ABCDEF"), "#abcdef")
        XCTAssertEqual(normalizeHex("xyz"), "")
        XCTAssertTrue(isDarkHex("#171412"))
        XCTAssertFalse(isDarkHex("#fafafa"))
        // Mid blend of black and white must be a mid gray.
        let got = mixHex("#000000", "#ffffff", 0.5)
        XCTAssertTrue(got == "#808080" || got == "#7f7f7f", "mixHex: \(got)")
        let c = parseHex("#B88242")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.hex(), "#b88242")
    }
}
