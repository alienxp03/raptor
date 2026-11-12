import Foundation

/// A session ID is unique only within its host. Store the launcher's host verbatim.
public struct SessionPin: Codable, Hashable {
    public var sessionID: String
    public var host: String

    public init(sessionID: String, host: String) {
        self.sessionID = sessionID
        self.host = host
    }
}

public extension RaptorConfig {
    private static var sessionPinsPath: String {
        (configPath() as NSString).deletingLastPathComponent + "/session-pins.json"
    }

    static func loadSessionPins() -> [SessionPin] {
        guard let data = FileManager.default.contents(atPath: sessionPinsPath),
              let pins = try? JSONDecoder().decode([SessionPin].self, from: data) else { return [] }
        return pins
    }

    /// Does not change legacy directory pins or other config settings.
    @discardableResult
    static func toggleSessionPin(sessionID: String, host: String) throws -> Bool {
        let pin = SessionPin(sessionID: sessionID, host: host)
        var pins = loadSessionPins()
        let found = pins.contains(pin)
        pins.removeAll { $0 == pin }
        if !found { pins.append(pin) }
        let path = sessionPinsPath
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try JSONEncoder().encode(pins).write(to: URL(fileURLWithPath: path), options: .atomic)
        return !found
    }
}
