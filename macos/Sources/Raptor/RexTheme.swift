import AppKit
import SwiftUI

// Theme palette delivered by the Go backend's `theme` method. Go resolves
// the active Rex theme from the Rex app bundle and preferences; Swift only
// paints. Fields are optional so partial payloads degrade gracefully.
struct ThemePayload: Codable, Sendable {
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
}

// The palette both picker views paint with. Starts as the Rex-sampled dark
// fallback; the backend replaces it with the active Rex theme per invocation.
// All access rides the main actor, like the views and model that read it.
@MainActor
enum PickerPalette {
    static var isDark = true
    static var selection = Color(red: 0.722, green: 0.510, blue: 0.259)
    static var selectionText = Color(red: 0.153, green: 0.141, blue: 0.133)
    static var background = Color(red: 0.153, green: 0.141, blue: 0.133)
    static var fieldBackground = Color(red: 0.243, green: 0.227, blue: 0.224)
    static var stroke = Color.white.opacity(0.07)

    static func useFallback(dark: Bool) {
        isDark = dark
        if dark {
            selection = Color(red: 0.722, green: 0.510, blue: 0.259)
            selectionText = Color(red: 0.153, green: 0.141, blue: 0.133)
            background = Color(red: 0.153, green: 0.141, blue: 0.133)
            fieldBackground = Color(red: 0.243, green: 0.227, blue: 0.224)
            stroke = Color.white.opacity(0.07)
        } else {
            selection = Color(red: 0.788, green: 0.635, blue: 0.353)
            selectionText = Color(red: 0.145, green: 0.133, blue: 0.118)
            background = Color(red: 0.957, green: 0.953, blue: 0.945)
            fieldBackground = Color(red: 0.894, green: 0.886, blue: 0.871)
            stroke = Color.black.opacity(0.12)
        }
    }

    static func apply(_ payload: ThemePayload) {
        guard let background = payload.background.flatMap(hexColor) else { return }
        isDark = payload.isDark ?? (hexLuma(background) < 0.5)
        self.background = background
        selection = payload.selection.flatMap(hexColor) ?? selectionFallback
        selectionText = payload.selectionForeground.flatMap(hexColor)
            ?? contrastText(for: selection)
        fieldBackground = payload.surface.flatMap(hexColor) ?? fieldFallback(for: background)
        stroke = isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.12)
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

    // Rec. 709 luma in sRGB.
    var luma: Double {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    }
}

func hexLuma(_ color: Color) -> Double { color.luma }

func contrastText(for background: Color) -> Color {
    background.luma < 0.5 ? Color(red: 0.95, green: 0.94, blue: 0.92) : Color(red: 0.15, green: 0.14, blue: 0.13)
}
