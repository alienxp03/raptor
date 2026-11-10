import Foundation

func clamp01(_ v: Double) -> Double {
    if v < 0 { return 0 }
    if v > 1 { return 1 }
    return v
}

/// Converts linear-light display-P3 primaries to sRGB and applies the sRGB
/// transfer function.
func p3ToSRGB(_ c: Color) -> Color {
    // Linearize display P3 (sRGB-like 2.2 gamma piecewise).
    let r = p3EOTF(c.r)
    let g = p3EOTF(c.g)
    let b = p3EOTF(c.b)
    // Display P3 -> sRGB linear matrix.
    let rr = clamp01(1.224940 * r - 0.224734 * g + 0.0 * b)
    let gg = clamp01(-0.042056 * r + 1.041858 * g + 0.0 * b)
    let bb = clamp01(-0.019638 * r - 0.078637 * g + 1.098275 * b)
    return Color(r: sRGBEncode(rr), g: sRGBEncode(gg), b: sRGBEncode(bb))
}

func p3EOTF(_ v: Double) -> Double {
    // Display P3 uses the sRGB transfer function.
    if v <= 0.04045 { return v / 12.92 }
    return pow((v + 0.055) / 1.055, 2.4)
}

func sRGBEncode(_ v: Double) -> Double {
    if v <= 0.0031308 { return v * 12.92 }
    return 1.055 * pow(v, 1 / 2.4) - 0.055
}

/// Normalizes #rrggbb, returning "" for junk.
func normalizeHex(_ value: String) -> String {
    var v = value
    if v.hasPrefix("#") { v.removeFirst() }
    guard v.count == 6, v.allSatisfy({ $0.isHexDigit }) else { return "" }
    return "#" + v.lowercased()
}

/// Parses #rrggbb into a Color, or nil.
func parseHex(_ value: String) -> Color? {
    let normalized = normalizeHex(value)
    guard !normalized.isEmpty else { return nil }
    let n = UInt32(normalized.dropFirst(), radix: 16)!
    return Color(
        r: Double((n >> 16) & 0xff) / 255,
        g: Double((n >> 8) & 0xff) / 255,
        b: Double(n & 0xff) / 255
    )
}

/// Rec. 709 luma below 0.5 counts as dark; unparsable colors read dark.
func isDarkHex(_ value: String) -> Bool {
    guard let c = parseHex(value) else { return true }
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b < 0.5
}

/// Blends two hex colors by fraction t of the second.
func mixHex(_ base: String, _ overlay: String, _ t: Double) -> String {
    guard let a = parseHex(base) else { return base }
    guard let b = parseHex(overlay) else { return base }
    return Color(
        r: a.r + (b.r - a.r) * t,
        g: a.g + (b.g - a.g) * t,
        b: a.b + (b.b - a.b) * t
    ).hex()
}

/// JSON/plist numeric bridges (NSNumber) coerced to Double.
func numberValue(_ value: Any?) -> Double? {
    guard let value else { return nil }
    if let d = value as? Double { return d }
    if let n = value as? NSNumber { return n.doubleValue }
    return nil
}

/// Reads one Rex semantic color (display-p3 floats) and converts it to sRGB.
func p3Color(_ value: Any?) -> Color? {
    guard let object = value as? [String: Any],
          let red = numberValue(object["red"]),
          let green = numberValue(object["green"]),
          let blue = numberValue(object["blue"]) else { return nil }
    return p3ToSRGB(Color(r: red, g: green, b: blue))
}

/// One source color: a hex string or a p3 color object.
func hexString(_ value: Any?) -> String {
    if let string = value as? String { return normalizeHex(string) }
    if let object = value as? [String: Any], let c = p3Color(object) { return c.hex() }
    return ""
}

/// Collects hex colors from a list, or nil when fewer than `want` survive.
func hexList(_ value: Any?, _ want: Int) -> [String]? {
    guard let items = value as? [Any] else { return nil }
    var out: [String] = []
    out.reserveCapacity(items.count)
    for item in items {
        let hex = hexString(item)
        if !hex.isEmpty { out.append(hex) }
    }
    return out.count < want ? nil : out
}
