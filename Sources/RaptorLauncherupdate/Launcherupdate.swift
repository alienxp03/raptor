import Foundation
import CryptoKit
import RaptorPaths

/// A small cross-process creation journal, not a session database. Only
/// authoritative successful creations belong here. Ported from
/// internal/launcherupdate.

public struct LauncherupdateError: Error, CustomStringConvertible {
    public var message: String
    public var description: String { message }
}

/// One authoritative session creation.
public struct Session: Codable, Equatable {
    public var id: String
    public var label: String
    public var host: String
    public var path: String
    public var local: Bool
    public var created: Date

    enum CodingKeys: String, CodingKey {
        case id, label, host, path, local, created
    }

    public init(
        id: String = "",
        label: String = "",
        host: String = "",
        local: Bool = false,
        path: String = "",
        created: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.id = id
        self.label = label
        self.host = host
        self.local = local
        self.path = path
        self.created = created
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        local = try c.decodeIfPresent(Bool.self, forKey: .local) ?? false
        let raw = try c.decodeIfPresent(String.self, forKey: .created) ?? ""
        guard let date = Launcherupdate.decodeDate(raw) else {
            throw DecodingError.dataCorruptedError(forKey: .created, in: c, debugDescription: "invalid RFC3339 time " + raw)
        }
        created = date
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(host, forKey: .host)
        try c.encode(path, forKey: .path)
        try c.encode(local, forKey: .local)
        try c.encode(Launcherupdate.encodeDate(created), forKey: .created)
    }
}

public enum Launcherupdate {
    /// Bounds recovery when a session is removed/renamed outside Raptor and no
    /// successful post-creation discovery has yet reached a warm reader.
    public static let ttl: TimeInterval = 2 * 60

    static let plainFormatter = ISO8601DateFormatter()

    static let fractionFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Go's time.Time JSON form: RFC3339Nano — fractional seconds to
    /// nanosecond precision with trailing zeros trimmed, none when zero.
    static func encodeDate(_ date: Date) -> String {
        let base = plainFormatter.string(from: date)
        var nanos = Int((date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1)) * 1_000_000_000)
        if nanos <= 0 { return base }
        if nanos >= 1_000_000_000 { nanos = 999_999_999 }
        var frac = String(nanos)
        frac = String(repeating: "0", count: 9 - frac.count) + frac
        while frac.hasSuffix("0") { frac.removeLast() }
        // Insert before the zone suffix: numeric offsets are "+HH:MM" (6),
        // UTC is "Z" (1).
        let offsetWidth = base.hasSuffix("Z") ? 1 : 6
        guard offsetWidth < base.count, let idx = base.index(base.endIndex, offsetBy: -offsetWidth, limitedBy: base.startIndex) else { return base }
        return String(base[..<idx]) + "." + frac + String(base[idx...])
    }

    static func decodeDate(_ raw: String) -> Date? {
        // RFC3339Nano input can carry up to 9 fractional digits; the strict
        // formatter handles at most 6, so trim longer fractions first.
        var normalized = raw
        if let range = normalized.range(of: #"[.]\d{7,9}"#, options: .regularExpression) {
            let digits = normalized[range].dropFirst().prefix(6)
            normalized = normalized.replacingCharacters(in: range, with: "." + digits)
        }
        return fractionFormatter.date(from: normalized) ?? plainFormatter.date(from: normalized)
    }

    static func directory() -> String {
        RaptorPaths.cacheDir() + "/launcher-creations"
    }

    /// Best effort, like the launcher cache. Atomic per-identity files avoid
    /// lost updates between CLI processes without holding locks over Rex calls.
    public static func record(_ s: Session) {
        if s.id.isEmpty || s.label.isEmpty {
            return
        }
        var s = s
        s.created = Date()
        guard let data = try? JSONEncoder().encode(s) else { return }
        let dir = directory()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let tmp = dir + "/.creation-" + UUID().uuidString
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o644]) else { return }
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let key = SHA256.hash(data: Data((s.host + "\u{00}" + s.id).utf8))
        let hex = key.map { String(format: "%02x", $0) }.joined()
        let dest = dir + "/" + hex + ".json"
        try? FileManager.default.removeItem(atPath: dest)
        try? FileManager.default.moveItem(atPath: tmp, toPath: dest)
    }

    /// Returns creations not covered by a snapshot whose scan STARTED at `at`.
    /// A later completed scan is authoritative even if a created ID is absent.
    public static func since(_ at: Date) -> [Session] {
        let dir = directory()
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var result: [Session] = []
        let now = Date()
        for entry in entries {
            if (entry as NSString).pathExtension != "json" {
                continue
            }
            guard let data = FileManager.default.contents(atPath: dir + "/" + entry),
                  let s = try? JSONDecoder().decode(Session.self, from: data) else { continue }
            if now.timeIntervalSince(s.created) > ttl {
                continue
            }
            if !s.id.isEmpty && s.created > at {
                result.append(s)
            }
        }
        return result
    }
}
