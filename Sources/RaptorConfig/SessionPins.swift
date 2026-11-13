import Foundation

/// A session ID is unique only within its host. Store the launcher's host verbatim.
public struct SessionPin: Codable, Hashable {
    public var sessionID: String
    public var host: String
    public var slot: Int?
    // Only a missing key is legacy. Explicitly unslotted pins must not be promoted.
    fileprivate var needsSlot = false

    public init(sessionID: String, host: String, slot: Int? = nil) {
        self.sessionID = sessionID
        self.host = host
        self.slot = slot.flatMap { (1...9).contains($0) ? $0 : nil }
    }

    private enum CodingKeys: String, CodingKey { case sessionID, host, slot }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        host = try c.decode(String.self, forKey: .host)
        needsSlot = !c.contains(.slot)
        let value = try? c.decode(Int.self, forKey: .slot)
        slot = value.flatMap { (1...9).contains($0) ? $0 : nil }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(host, forKey: .host)
        try c.encode(slot.flatMap { (1...9).contains($0) ? $0 : nil } ?? 0, forKey: .slot)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sessionID == rhs.sessionID && lhs.host == rhs.host
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(sessionID)
        hasher.combine(host)
    }
}

public extension RaptorConfig {
    private static var sessionPinsPath: String {
        (configPath() as NSString).deletingLastPathComponent + "/session-pins.json"
    }

    static func loadSessionPins() -> [SessionPin] {
        guard let data = FileManager.default.contents(atPath: sessionPinsPath),
              let pins = try? JSONDecoder().decode([SessionPin].self, from: data) else { return [] }
        var seen = Set<SessionPin>()
        var normalized = pins.filter { seen.insert($0).inserted }
        var used = Set<Int>()
        // Preserve existing assignments first; first persisted owner wins conflicts.
        for i in normalized.indices {
            if let slot = normalized[i].slot, !used.insert(slot).inserted {
                normalized[i].slot = nil
            }
        }
        for i in normalized.indices where normalized[i].needsSlot {
            let slot = (1...9).first { !used.contains($0) }
            normalized[i].slot = slot
            normalized[i].needsSlot = false
            if let slot { used.insert(slot) }
        }
        return normalized
    }

    /// Does not change legacy directory pins or other config settings.
    @discardableResult
    static func toggleSessionPin(sessionID: String, host: String) throws -> Bool {
        let pin = SessionPin(sessionID: sessionID, host: host)
        var pins = loadSessionPins()
        let found = pins.contains(pin)
        pins.removeAll { $0 == pin }
        if !found {
            let used = Set(pins.compactMap(\.slot))
            pins.append(SessionPin(sessionID: sessionID, host: host,
                                   slot: (1...9).first { !used.contains($0) }))
        }
        let path = sessionPinsPath
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try JSONEncoder().encode(pins).write(to: URL(fileURLWithPath: path), options: .atomic)
        return !found
    }
}
