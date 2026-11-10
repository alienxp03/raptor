import Foundation
import RaptorRex
import RaptorTheme
import XCTest
@testable import RaptorAPI

final class ThemeTests: APITestCase {
    func testThemeResponseEnvelope() throws {
        env.set("RAPTOR_THEME", "")
        try fakeTool(env, "defaults", """
        printf '%s' '<plist version="1.0"><dict>
        <key>Workspace.appearance</key><string>dark</string>
        <key>Workspace.interfaceStyle</key><string>blendTheme</string>
        <key>Workspace.darkThemeID</key><string>wire-forest</string>
        </dict></plist>'
        """)
        let app = makeTempDir()
        env.set("RAPTOR_REX_APP", app)
        let path = app + "/Contents/Resources/SuperUI_SuperDesignTokens.bundle/Contents/Resources/themes.json"
        try FileManager.default.createDirectory(atPath: dirName(path), withIntermediateDirectories: true)
        let palette: [String: Any] = [
            "background": "#102030", "foreground": "#e0e0e0", "cursor": "#aabbcc",
            "selectionBackground": "#456789", "selectionForeground": "#ddeeff",
            "ansi": String(repeating: "#112233 ", count: 16).split(separator: " ").map(String.init),
        ]
        func gray(_ value: Double) -> [String: Any] {
            ["colorSpace": "display-p3", "red": value, "green": value, "blue": value, "alpha": 1]
        }
        let semantic: [String: Any] = [
            "surfaceRaised": gray(0.2), "content": gray(0.9), "selection": gray(0.75),
            "selectionForeground": gray(0.1), "controlOnOverlay": gray(0.3),
        ]
        let catalog: [[String: Any]] = [["id": "wire-forest", "name": "Wire Forest", "source": palette, "semantic": semantic]]
        let catalogData = try JSONSerialization.data(withJSONObject: catalog)
        try catalogData.write(to: URL(fileURLWithPath: path))

        let output = DataOutput()
        let h = Handler(ctx: Ctx(), cfg: .default())
        try h.serve(input: DataInput("{\"id\":1,\"method\":\"theme\",\"params\":{}}"), output: output)
        let response = decodeWire(output.text.trimmingCharacters(in: .whitespacesAndNewlines))
        if response.id != 1 || !(response.error ?? "").isEmpty {
            XCTFail("native API requires result.theme, got \(output.text)")
        }
        let dict = try jsonDict(response.result ?? "{}")
        guard let themeDict = dict["theme"] as? [String: Any] else {
            XCTFail("native API requires result.theme, got \(output.text)")
            return
        }
        let ui = themeDict["ui"] as? [String: Any]
        if ui == nil
            || ui?["background"] as? String != "#333333"
            || ui?["selection"] as? String != "#bfbfbf"
            || ui?["selectionForeground"] as? String != "#1a191a"
            || themeDict["interfaceStyle"] as? String != "blendTheme" {
            XCTFail("missing native UI roles: \(themeDict)")
        }
        if themeDict["name"] as? String != "Wire Forest"
            || themeDict["background"] as? String != "#102030"
            || themeDict["selection"] as? String != "#456789"
            || themeDict["selectionForeground"] as? String != "#ddeeff"
            || (themeDict["ansi"] as? [String])?.count != 16 {
            XCTFail("unexpected wire palette: \(themeDict)")
        }
    }
}
