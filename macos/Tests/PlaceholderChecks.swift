import AppKit
import SwiftUI

/// Contrast regression checks run by NativeChecks.
struct PlaceholderChecks {
    @MainActor static func run() {
        defer { PickerPalette.useFallback(dark: true) }
        // Deliberately oppose the app appearance to the picker theme.
        for dark in [false, true] {
            NSAppearance(named: dark ? .aqua : .darkAqua)?.performAsCurrentDrawingAppearance {
                PickerPalette.useFallback(dark: dark)
                check("fallback dark=\(dark)")
                for style in ["modern", "blendTheme", "useTheme"] {
                    let payload = ThemePayload(
                        isDark: dark,
                        background: dark ? "#202020" : "#fafafa",
                        foreground: dark ? "#eeeeee" : "#202020",
                        surface: dark ? "#3e3a39" : "#dedbd5",
                        interfaceStyle: style,
                        ui: InterfacePalettePayload(
                            background: dark ? "#202020" : "#fafafa",
                            foreground: dark ? "#eeeeee" : "#202020",
                            surface: dark ? "#3e3a39" : "#dedbd5"))
                    precondition(PickerPalette.apply(payload))
                    check("\(style) dark=\(dark)")
                }
                // A theme with illegible foreground must still have readable prompts.
                PickerPalette.foreground = PickerPalette.fieldBackground
                check("low-contrast theme dark=\(dark)")
                checkRenderedPlaceholder(dark: dark)
            }
        }
        print("PASS: opaque search placeholders meet 4.5:1 contrast in light/dark Rex themes")
    }

    @MainActor private static func checkRenderedPlaceholder(dark: Bool) {
        // Exercise the actual overlay, not just its chosen color. Oppose the
        // system appearance and simulate disabled fields as well as enabled ones.
        PickerPalette.useFallback(dark: dark)
        for enabled in [false, true] {
            for empty in [false, true] {
                let view = Color.clear.frame(width: 300, height: 32)
                    .pickerPlaceholder("Search sessions and directories…", when: empty)
                    .font(.system(size: PickerStyle.rowFontSize))
                    .disabled(!enabled)
                    .background(dark ? Color.black : Color.white)
                    .environment(\.colorScheme, dark ? .light : .dark)
                let renderer = ImageRenderer(content: view)
                guard let image = renderer.cgImage else { preconditionFailure("Placeholder did not render") }
                let bitmap = NSBitmapImageRep(cgImage: image)
                var ink = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                        let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                        if dark ? brightness > 0.5 : brightness < 0.5 { ink += 1 }
                    }
                }
                precondition(empty ? ink > 100 : ink == 0,
                             "Placeholder visibility/contrast failed: dark=\(dark), enabled=\(enabled), empty=\(empty)")
            }
        }
    }

    @MainActor private static func check(_ context: String) {
        let surface = PickerStyle.background.overlay(
            with: PickerStyle.fieldBackground,
            fraction: NSColor(PickerStyle.fieldBackground).alphaComponent)
        let placeholder = PickerStyle.placeholderText
        precondition(NSColor(placeholder).alphaComponent == 1, "Translucent placeholder: \(context)")
        precondition(placeholder.contrastRatio(with: surface) >= 4.5,
                     "Unreadable search placeholder: \(context)")
    }
}
