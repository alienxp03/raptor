import Foundation
import RaptorWorktree

/// Go-compatible JSON value tree with ordered object keys, so encoded results
/// keep the Go struct field order and maps keep Go's sorted-key order.
enum JS {
    case null
    case bool(Bool)
    case int(Int64)
    case string(String)
    case raw(String) // pre-encoded JSON, embedded verbatim
    case array([JS])
    case object([(String, JS)])

    /// Go map encoding: keys sorted (request params, unordered payloads).
    static func object(_ dict: [String: JS]) -> JS {
        .object(dict.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
    }

    /// encoding/json-compatible encoding: compact, HTML-safe escaping.
    func encode() -> String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let n): return String(n)
        case .string(let s): return JS.escapeGo(s)
        case .raw(let s): return s
        case .array(let items): return "[" + items.map { $0.encode() }.joined(separator: ",") + "]"
        case .object(let fields):
            return "{" + fields.map { JS.escapeGo($0.0) + ":" + $0.1.encode() }.joined(separator: ",") + "}"
        }
    }

    /// Go's encoding/json string escaping, including the HTML-safe set.
    static func escapeGo(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "<": out += "\\u003c"
            case ">": out += "\\u003e"
            case "&": out += "\\u0026"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// Encodes any Encodable with Go-compactly (no spaces). Used for dependency
/// types whose Codable conformance already mirrors the Go JSON tags.
func encodedJSONString<T: Encodable>(_ value: T) -> String {
    let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
}

// MARK: - minimal JSON parser (request envelopes, params, cache files)

indirect enum JSONValue {
    case object([(String, JSONNode)])
    case array([JSONNode])
    case string(String)
    case number(String) // raw literal; int-ness decided by the literal's shape
    case bool(Bool)
    case null

    var kindName: String {
        switch self {
        case .object: return "object"
        case .array: return "array"
        case .string: return "string"
        case .number: return "number"
        case .bool: return "bool"
        case .null: return "null"
        }
    }

    /// Field lookup for decoded objects.
    func field(_ key: String) -> JSONNode? {
        guard case .object(let fields) = self else { return nil }
        for (k, v) in fields where k == key { return v }
        return nil
    }
}

/// One parsed value plus its exact source byte range (for RawMessage params).
struct JSONNode {
    var value: JSONValue
    var start: Int
    var end: Int
}

struct JSONParseError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

struct JSONParser {
    let bytes: [UInt8]
    var i = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    init(_ text: String) { self.bytes = Array(text.utf8) }

    mutating func parseTop() throws -> JSONNode {
        skipSpace()
        let node = try parseValue()
        skipSpace()
        if i != bytes.count {
            throw JSONParseError(message: "invalid character after top-level value")
        }
        return node
    }

    mutating func skipSpace() {
        while i < bytes.count {
            switch bytes[i] {
            case 0x20, 0x09, 0x0A, 0x0D: i += 1
            default: return
            }
        }
    }

    mutating func parseValue() throws -> JSONNode {
        skipSpace()
        guard i < bytes.count else { throw JSONParseError(message: "unexpected end of JSON input") }
        let start = i
        switch bytes[i] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""):
            let s = try parseString()
            return JSONNode(value: .string(s), start: start, end: i)
        case UInt8(ascii: "t"):
            try expect("true")
            return JSONNode(value: .bool(true), start: start, end: i)
        case UInt8(ascii: "f"):
            try expect("false")
            return JSONNode(value: .bool(false), start: start, end: i)
        case UInt8(ascii: "n"):
            try expect("null")
            return JSONNode(value: .null, start: start, end: i)
        default:
            return try parseNumber()
        }
    }

    mutating func expect(_ word: String) throws {
        for c in word.utf8 {
            guard i < bytes.count, bytes[i] == c else {
                throw JSONParseError(message: "invalid JSON literal")
            }
            i += 1
        }
    }

    mutating func parseObject() throws -> JSONNode {
        let start = i
        i += 1 // '{'
        var fields: [(String, JSONNode)] = []
        skipSpace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") {
            i += 1
            return JSONNode(value: .object(fields), start: start, end: i)
        }
        while true {
            skipSpace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else {
                throw JSONParseError(message: "invalid object key")
            }
            let key = try parseString()
            skipSpace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else {
                throw JSONParseError(message: "missing colon in object")
            }
            i += 1
            let value = try parseValue()
            fields.append((key, value))
            skipSpace()
            guard i < bytes.count else { throw JSONParseError(message: "unterminated object") }
            if bytes[i] == UInt8(ascii: ",") {
                i += 1
                continue
            }
            if bytes[i] == UInt8(ascii: "}") {
                i += 1
                return JSONNode(value: .object(fields), start: start, end: i)
            }
            throw JSONParseError(message: "invalid object separator")
        }
    }

    mutating func parseArray() throws -> JSONNode {
        let start = i
        i += 1 // '['
        var items: [JSONNode] = []
        skipSpace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") {
            i += 1
            return JSONNode(value: .array(items), start: start, end: i)
        }
        while true {
            let value = try parseValue()
            items.append(value)
            skipSpace()
            guard i < bytes.count else { throw JSONParseError(message: "unterminated array") }
            if bytes[i] == UInt8(ascii: ",") {
                i += 1
                continue
            }
            if bytes[i] == UInt8(ascii: "]") {
                i += 1
                return JSONNode(value: .array(items), start: start, end: i)
            }
            throw JSONParseError(message: "invalid array separator")
        }
    }

    mutating func parseString() throws -> String {
        i += 1 // opening quote
        var out = ""
        while i < bytes.count {
            let c = bytes[i]
            if c == UInt8(ascii: "\"") {
                i += 1
                return out
            }
            if c == UInt8(ascii: "\\") {
                i += 1
                guard i < bytes.count else { break }
                let esc = bytes[i]
                i += 1
                switch esc {
                case UInt8(ascii: "\""): out.append("\"")
                case UInt8(ascii: "\\"): out.append("\\")
                case UInt8(ascii: "/"): out.append("/")
                case UInt8(ascii: "b"): out.unicodeScalars.append(UnicodeScalar(0x08))
                case UInt8(ascii: "f"): out.unicodeScalars.append(UnicodeScalar(0x0C))
                case UInt8(ascii: "n"): out.append("\n")
                case UInt8(ascii: "r"): out.append("\r")
                case UInt8(ascii: "t"): out.append("\t")
                case UInt8(ascii: "u"):
                    guard let scalar = try parseUnicodeEscape() else {
                        throw JSONParseError(message: "invalid unicode escape")
                    }
                    out.unicodeScalars.append(scalar)
                default:
                    throw JSONParseError(message: "invalid escape")
                }
                continue
            }
            if c < 0x20 {
                throw JSONParseError(message: "invalid control character in string")
            }
            // Copy raw UTF-8 bytes verbatim.
            var utf8 = [c]
            i += 1
            while i < bytes.count, bytes[i] & 0xC0 == 0x80 {
                utf8.append(bytes[i])
                i += 1
            }
            out += String(decoding: utf8, as: UTF8.self)
        }
        throw JSONParseError(message: "unterminated string")
    }

    mutating func parseUnicodeEscape() throws -> Unicode.Scalar? {
        func hex4(_ at: Int) throws -> Int {
            guard at + 4 <= bytes.count else { throw JSONParseError(message: "short unicode escape") }
            var value = 0
            for j in at..<(at + 4) {
                let c = bytes[j]
                let d: Int
                switch c {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): d = Int(c - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): d = Int(c - UInt8(ascii: "a")) + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): d = Int(c - UInt8(ascii: "A")) + 10
                default: throw JSONParseError(message: "invalid unicode escape digit")
                }
                value = value * 16 + d
            }
            return value
        }
        let first = try hex4(i)
        i += 4
        if first >= 0xD800 && first <= 0xDBFF, i + 1 < bytes.count,
            bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
            let second = try hex4(i + 2)
            if second >= 0xDC00 && second <= 0xDFFF {
                i += 6
                let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                return Unicode.Scalar(combined)
            }
        }
        return Unicode.Scalar(first)
    }

    mutating func parseNumber() throws -> JSONNode {
        let start = i
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
        var digits = 0
        while i < bytes.count, bytes[i] >= UInt8(ascii: "0"), bytes[i] <= UInt8(ascii: "9") {
            i += 1
            digits += 1
        }
        guard digits > 0 else { throw JSONParseError(message: "invalid number") }
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            i += 1
            var frac = 0
            while i < bytes.count, bytes[i] >= UInt8(ascii: "0"), bytes[i] <= UInt8(ascii: "9") {
                i += 1
                frac += 1
            }
            guard frac > 0 else { throw JSONParseError(message: "invalid number fraction") }
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            i += 1
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            var exp = 0
            while i < bytes.count, bytes[i] >= UInt8(ascii: "0"), bytes[i] <= UInt8(ascii: "9") {
                i += 1
                exp += 1
            }
            guard exp > 0 else { throw JSONParseError(message: "invalid number exponent") }
        }
        let literal = String(decoding: bytes[start..<i], as: UTF8.self)
        return JSONNode(value: .number(literal), start: start, end: i)
    }
}

/// Go-like typed field decoding for request params. Missing keys and nulls
/// decode as zero values; wrong types raise encoding/json-style errors.
enum Params {
    static func typeError(_ value: JSONValue, _ key: String, _ goType: String) -> MessageError {
        MessageError("json: cannot unmarshal \(value.kindName) into Go struct field .\(key) of type \(goType)")
    }

    static func string(_ obj: JSONValue, _ key: String) throws -> String {
        guard let node = obj.field(key) else { return "" }
        let v = node.value
        if case .null = v { return "" }
        guard case .string(let s) = v else { throw typeError(v, key, "string") }
        return s
    }

    static func bool(_ obj: JSONValue, _ key: String) throws -> Bool {
        guard let node = obj.field(key) else { return false }
        let v = node.value
        if case .null = v { return false }
        guard case .bool(let b) = v else { throw typeError(v, key, "bool") }
        return b
    }
}

// MARK: - RFC3339 (Go time.Parse(time.RFC3339Nano)) helpers

/// Parses Go's RFC3339(Nano) form. Returns nil for malformed input.
func parseRFC3339(_ raw: String) -> Date? {
    // ^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})$
    let chars = Array(raw.unicodeScalars)
    func digits(_ i: Int, _ n: Int) -> Int? {
        guard i + n <= chars.count else { return nil }
        var value = 0
        for j in i..<(i + n) {
            let c = chars[j]
            guard c.value >= 48, c.value <= 57 else { return nil }
            value = value * 10 + Int(c.value - 48)
        }
        return value
    }
    guard chars.count >= 20 else { return nil }
    guard let year = digits(0, 4), chars[4] == "-", let month = digits(5, 2), chars[7] == "-",
        let day = digits(8, 2), chars[10] == "T" || chars[10] == "t",
        let hour = digits(11, 2), chars[13] == ":",
        let minute = digits(14, 2), chars[16] == ":",
        let second = digits(17, 2) else { return nil }
    guard month >= 1, month <= 12, day >= 1, day <= 31, hour <= 23, minute <= 59, second <= 60 else { return nil }
    var i = 19
    var fraction = 0.0
    if i < chars.count, chars[i] == "." {
        i += 1
        let start = i
        while i < chars.count, chars[i].value >= 48, chars[i].value <= 57 {
            i += 1
        }
        guard i > start else { return nil }
        var scale = 0.1
        for j in start..<i {
            fraction += Double(chars[j].value - 48) * scale
            scale /= 10
        }
    }
    guard i < chars.count else { return nil }
    var offsetSeconds = 0
    switch chars[i] {
    case "Z", "z":
        i += 1
    case "+", "-":
        let sign = chars[i] == "-" ? -1 : 1
        guard let oh = digits(i + 1, 2), chars[i + 3] == ":", let om = digits(i + 4, 2) else { return nil }
        offsetSeconds = sign * (oh * 3600 + om * 60)
        i += 6
    default:
        return nil
    }
    guard i == chars.count else { return nil }
    func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }
    let clampedSecond = second == 60 ? 59 : second
    let daySeconds = daysFromCivil(year, month, day) * 86400
        + hour * 3600 + minute * 60 + clampedSecond - offsetSeconds
    let leapAdjustment: Double = second == 60 ? 1 : 0
    return Date(timeIntervalSince1970: Double(daySeconds) + fraction + leapAdjustment)
}

/// Formats like Go's RFC3339Nano: fractional seconds with trailing zeros trimmed.
func formatRFC3339Nano(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    var out = formatter.string(from: date)
    let seconds = floor(date.timeIntervalSince1970)
    let fraction = date.timeIntervalSince1970 - seconds
    if fraction > 0 {
        var digits = String(format: "%.9f", fraction)
        digits.removeFirst(2) // "0."
        while digits.hasSuffix("0") {
            digits.removeLast()
        }
        if !digits.isEmpty {
            out += "." + digits
        }
    }
    return out + "Z"
}

/// Stable sort (Go's sort.SliceStable keeps equal elements in input order).
func stableSort<T>(_ data: [T], _ less: (T, T) -> Bool) -> [T] {
    guard data.count > 1 else { return data }
    let mid = data.count / 2
    let left = stableSort(Array(data[..<mid]), less)
    let right = stableSort(Array(data[mid...]), less)
    var out: [T] = []
    out.reserveCapacity(data.count)
    var i = 0, j = 0
    while i < left.count && j < right.count {
        if less(right[j], left[i]) {
            out.append(right[j])
            j += 1
        } else {
            out.append(left[i])
            i += 1
        }
    }
    out.append(contentsOf: left[i...])
    out.append(contentsOf: right[j...])
    return out
}
