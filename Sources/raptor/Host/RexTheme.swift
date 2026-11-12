import AppKit
import SwiftUI

// Theme palette delivered by the Go backend's `theme` method. Go resolves
// the active Rex theme from the Rex app bundle and preferences; Swift only
// paints. Fields are optional so partial payloads degrade gracefully.
struct InterfacePalettePayload: Codable, Equatable, Sendable {
    var background: String?
    var foreground: String?
    var selection: String?
    var selectionForeground: String?
    var surface: String?
}

struct ThemePayload: Codable, Equatable, Sendable {
    var name: String?
    var isDark: Bool?
    var background: String?
    var foreground: String?
    var cursor: String?
    var selection: String?
    var selectionForeground: String?
    var surface: String?
    var accent: String?
    var ansi: [String]?
    var interfaceStyle: String?
    var ui: InterfacePalettePayload?
}

// The palette both picker views paint with. Starts as the Rex-sampled dark
// fallback; the backend refreshes it with the active Rex theme while visible.
// All access rides the main actor, like the views and model that read it.
@MainActor
enum PickerPalette {
    static var isDark = true
    static var foreground = Color(red: 0.84, green: 0.79, blue: 0.72)
    static var selection = Color(red: 0.722, green: 0.510, blue: 0.259)
    static var selectionText = Color(red: 0.95, green: 0.95, blue: 0.95)
    static var background = Color(red: 0.153, green: 0.141, blue: 0.133)
    static var fieldBackground = Color(red: 0.243, green: 0.227, blue: 0.224)
    static var stroke = Color.white.opacity(0.07)
    static var selectionOpacity = 0.18
    static var usesThemeTint = true

    static func useFallback(dark: Bool) {
        isDark = dark
        selectionOpacity = dark ? 0.18 : 0.10
        usesThemeTint = true
        foreground = dark ? Color(red: 0.84, green: 0.79, blue: 0.72) : Color(red: 0.1, green: 0.1, blue: 0.1)
        if dark {
            selection = Color(red: 0.722, green: 0.510, blue: 0.259)
            selectionText = nativeLabelColor(dark: true)
            background = Color(red: 0.153, green: 0.141, blue: 0.133)
            fieldBackground = Color(red: 0.243, green: 0.227, blue: 0.224)
            stroke = Color.white.opacity(0.07)
        } else {
            selection = Color(red: 0.788, green: 0.635, blue: 0.353)
            selectionText = nativeLabelColor(dark: false)
            background = Color(red: 0.957, green: 0.953, blue: 0.945)
            fieldBackground = Color(red: 0.894, green: 0.886, blue: 0.871)
            stroke = Color.black.opacity(0.12)
        }
    }

    @discardableResult static func apply(_ payload: ThemePayload) -> Bool {
        guard let background = (payload.ui?.background ?? payload.background).flatMap(hexColor) else { return false }
        isDark = payload.isDark ?? (hexLuma(background) < 0.5)
        self.background = background
        let nativeChrome = payload.ui != nil && payload.interfaceStyle != "useTheme"
        foreground = nativeChrome ? nativeLabelColor(dark: isDark)
            : (payload.ui?.foreground ?? payload.foreground).flatMap(hexColor)
                ?? (isDark ? Color(red: 0.84, green: 0.79, blue: 0.72) : Color(red: 0.1, green: 0.1, blue: 0.1))
        selection = (payload.ui?.selection ?? payload.selection).flatMap(hexColor) ?? selectionFallback
        // Theme selection foregrounds assume an opaque fill, not our muted tint.
        // Keep labels stable and composite the tint onto the panel surface.
        selectionText = nativeLabelColor(dark: isDark)
        selectionOpacity = isDark ? 0.18 : 0.10
        usesThemeTint = payload.ui == nil || ["blendTheme", "useTheme"].contains(payload.interfaceStyle ?? "modern")
        fieldBackground = nativeChrome ? (isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.06))
            : (payload.ui?.surface ?? payload.surface).flatMap(hexColor) ?? fieldFallback(for: background)
        stroke = isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.12)
        return true
    }

    /// Rex's glass styles retain system chrome labels, not terminal text colors.
    private static func nativeLabelColor(dark: Bool) -> Color {
        var label = NSColor.labelColor
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            label = NSColor.labelColor.usingColorSpace(.sRGB) ?? label
        }
        return Color(nsColor: label)
    }

    private static var selectionFallback: Color {
        isDark ? Color(red: 0.722, green: 0.510, blue: 0.259) : Color(red: 0.788, green: 0.635, blue: 0.353)
    }

    private static func fieldFallback(for background: Color) -> Color {
        isDark ? background.overlay(with: .white, fraction: 0.12)
               : background.overlay(with: .black, fraction: 0.08)
    }
}

func hexColor(_ hex: String) -> Color? {
    let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
    return Color(red: Double((number >> 16) & 255) / 255,
                 green: Double((number >> 8) & 255) / 255,
                 blue: Double(number & 255) / 255)
}

extension Color {
    func overlay(with other: Color, fraction: Double) -> Color {
        let base = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let top = NSColor(other).usingColorSpace(.sRGB) ?? .black
        return Color(red: base.redComponent + (top.redComponent - base.redComponent) * fraction,
                     green: base.greenComponent + (top.greenComponent - base.greenComponent) * fraction,
                     blue: base.blueComponent + (top.blueComponent - base.blueComponent) * fraction)
    }

    /// WCAG contrast uses linearized sRGB, not the display-space luma below.
    func contrastRatio(with other: Color) -> Double {
        func luminance(_ color: Color) -> Double {
            let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .black
            func linear(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
                + 0.0722 * linear(rgb.blueComponent)
        }
        let a = luminance(self), b = luminance(other)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    // Rec. 709 luma in sRGB.
    var luma: Double {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    }
}

func hexLuma(_ color: Color) -> Double { color.luma }

func contrastText(for background: Color) -> Color {
    let light = Color.white
    let dark = Color(red: 0.1, green: 0.1, blue: 0.1)
    return light.contrastRatio(with: background) >= dark.contrastRatio(with: background) ? light : dark
}
