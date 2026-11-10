import Foundation

/// Thrown for every resolution failure; callers fall back to their built-in
/// palettes. Stands in for Go's wrapped ErrUnavailable sentinel.
public enum ThemeError: Error, CustomStringConvertible {
    /// No Rex theme could be resolved; `reason` carries what followed the
    /// "rex theme unavailable" prefix in the Go error text.
    case unavailable(String)

    public var description: String {
        switch self {
        case .unavailable(let reason):
            return "rex theme unavailable: " + reason
        }
    }

    /// True when the error came from theme resolution, like Go's
    /// errors.Is(err, ErrUnavailable).
    public static func isUnavailable(_ error: Error) -> Bool {
        error is ThemeError
    }
}

/// One sRGB color with components in 0..1.
struct Color {
    var r: Double
    var g: Double
    var b: Double

    /// Renders the color as #rrggbb.
    func hex() -> String {
        func to(_ v: Double) -> Int { Int((clamp01(v) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", to(r), to(g), to(b))
    }
}

/// UIPalette holds native UI roles, separate from the terminal palette.
public struct UIPalette: Codable, Equatable {
    public var background: String
    public var foreground: String
    public var selection: String
    public var selectionForeground: String
    public var surface: String

    public init(
        background: String,
        foreground: String,
        selection: String,
        selectionForeground: String,
        surface: String
    ) {
        self.background = background
        self.foreground = foreground
        self.selection = selection
        self.selectionForeground = selectionForeground
        self.surface = surface
    }
}

/// Theme is the resolved Rex palette in sRGB. Hex strings feed lipgloss and
/// the native-app protocol; ANSI holds the terminal palette, indices 0-15.
/// JSON keys match the Go struct tags exactly: the native app consumes this
/// payload verbatim over the `theme` api method (interfaceStyle is omitted
/// when empty, ui when absent, like Go's omitempty).
public struct Theme: Codable, Equatable {
    public var name: String
    public var isDark: Bool
    public var background: String
    public var foreground: String
    public var cursor: String
    public var selection: String
    public var selectionForeground: String
    public var surface: String
    public var accent: String
    public var ansi: [String]
    public var interfaceStyle: String
    public var ui: UIPalette?

    public init(
        name: String,
        isDark: Bool,
        background: String,
        foreground: String,
        cursor: String,
        selection: String,
        selectionForeground: String,
        surface: String,
        accent: String,
        ansi: [String],
        interfaceStyle: String = "",
        ui: UIPalette? = nil
    ) {
        self.name = name
        self.isDark = isDark
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selection = selection
        self.selectionForeground = selectionForeground
        self.surface = surface
        self.accent = accent
        self.ansi = ansi
        self.interfaceStyle = interfaceStyle
        self.ui = ui
    }

    enum CodingKeys: String, CodingKey {
        case name, isDark, background, foreground, cursor, selection
        case selectionForeground, surface, accent, ansi, interfaceStyle, ui
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        isDark = try c.decode(Bool.self, forKey: .isDark)
        background = try c.decode(String.self, forKey: .background)
        foreground = try c.decode(String.self, forKey: .foreground)
        cursor = try c.decode(String.self, forKey: .cursor)
        selection = try c.decode(String.self, forKey: .selection)
        selectionForeground = try c.decode(String.self, forKey: .selectionForeground)
        surface = try c.decode(String.self, forKey: .surface)
        accent = try c.decode(String.self, forKey: .accent)
        ansi = try c.decode([String].self, forKey: .ansi)
        interfaceStyle = try c.decodeIfPresent(String.self, forKey: .interfaceStyle) ?? ""
        ui = try c.decodeIfPresent(UIPalette.self, forKey: .ui)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Field order matches the Go struct declaration.
        try c.encode(name, forKey: .name)
        try c.encode(isDark, forKey: .isDark)
        try c.encode(background, forKey: .background)
        try c.encode(foreground, forKey: .foreground)
        try c.encode(cursor, forKey: .cursor)
        try c.encode(selection, forKey: .selection)
        try c.encode(selectionForeground, forKey: .selectionForeground)
        try c.encode(surface, forKey: .surface)
        try c.encode(accent, forKey: .accent)
        try c.encode(ansi, forKey: .ansi)
        if !interfaceStyle.isEmpty {
            try c.encode(interfaceStyle, forKey: .interfaceStyle)
        }
        try c.encodeIfPresent(ui, forKey: .ui)
    }
}

/// api `theme` payload: the resolved palette for the native picker, or an
/// error message when resolution is disabled or fails.
public enum ThemePayload {
    case theme(Theme)
    case error(String)

    /// JSON bytes exactly as the Go backend produced them.
    public func jsonData() -> Data {
        switch self {
        case .theme(let theme):
            return (try? JSONEncoder().encode(theme)) ?? Data("{}".utf8)
        case .error(let message):
            return (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
        }
    }
}
