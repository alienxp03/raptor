import Foundation

/// Native report identity. Keep the protocol timestamp: Date conversion can lose
/// the millisecond identity used by the Rex client's receipts.
public struct CompletionSource: Codable, Equatable {
    public var block: String
    public var record: String
    public var state: String
    public var updatedAt: String

    public init(block: String, record: String = "", state: String, updatedAt: String) {
        self.block = block
        self.record = record
        self.state = state
        self.updatedAt = updatedAt
    }
}

/// Read-only client receipts. No focus inference and no Raptor unread ledger.
public struct CompletionReceipts {
    private struct Key: Hashable {
        var block: String
        var record: String
        var milliseconds: Int64
    }
    private var seen: Set<Key> = []
    private var alerted: Set<Key> = []
    private var available = false

    public init(preferences: [String: Any]?) {
        guard let ledger = preferences?["Workspace.programActivitySeen"] as? [String: Any] else { return }
        func parse(_ name: String) -> Set<Key>? {
            guard let value = ledger[name] else { return [] }
            guard let rows = value as? [[String: Any]] else { return nil }
            var keys = Set<Key>()
            for row in rows {
                guard let block = row["block"] as? String, let record = row["record"] as? String,
                      let date = row["date"] as? Date,
                      let milliseconds = Self.milliseconds(date) else { return nil }
                keys.insert(Key(block: block, record: record, milliseconds: milliseconds))
            }
            return keys
        }
        guard let seen = parse("receipts"), let alerted = parse("alerted") else { return }
        self.seen = seen
        self.alerted = alerted
        available = true
    }

    public static func loadLocalPreferences() -> [String: Any]? {
        // Read the local client's domain only, including for remote reports.
        #if os(macOS)
        return loadPreferences(from: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.superlogical.rex.plist"))
        #else
        return nil
        #endif
    }

    /// Use the same persisted snapshot as the native file observer. A cached
    /// preferences-daemon value must not survive a missing or corrupt file.
    static func loadPreferences(from url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let preferences = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        guard let value = preferences["Workspace.programActivitySeen"] else { return [:] }
        return ["Workspace.programActivitySeen": value]
    }

    public func unread(_ source: CompletionSource) -> Bool {
        guard available, !source.block.isEmpty, source.state == "done" || source.state == "idle" else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = source.updatedAt.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let date = formatter.date(from: source.updatedAt), let milliseconds = Self.milliseconds(date) else { return false }
        let key = Key(block: source.block, record: source.record, milliseconds: milliseconds)
        return !seen.contains(key) && (source.state == "done" || alerted.contains(key))
    }

    public func unread(_ sources: [CompletionSource]) -> Bool {
        sources.contains(where: unread)
    }

    private static func milliseconds(_ date: Date) -> Int64? {
        let value = (date.timeIntervalSince1970 * 1000).rounded()
        guard value.isFinite, value > Double(Int64.min), value < Double(Int64.max) else { return nil }
        return Int64(value)
    }
}
