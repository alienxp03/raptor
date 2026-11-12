import Darwin
import Foundation

@MainActor
@main
struct RexReceiptChecks {
    private static func require(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(2)
        }
    }

    private static func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    private static func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        require(false, "Timed out waiting for receipt change")
    }

    static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("aux/receipt-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rex.plist")
        func save(_ value: Any?, unrelated: String = "dark", atomic: Bool = false,
                  format: PropertyListSerialization.PropertyListFormat = .binary) throws {
            var preferences: [String: Any] = ["Workspace.appearance": unrelated]
            preferences["Workspace.programActivitySeen"] = value
            try PropertyListSerialization.data(fromPropertyList: preferences, format: format, options: 0)
                .write(to: url, options: atomic ? .atomic : [])
        }
        func receipt() throws -> Data? {
            let preferences = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: url), format: nil) as? [String: Any]
            return preferences?["Workspace.programActivitySeen"] as? Data
        }
        let first = Data("{\"session:A\":1}".utf8)
        let second = Data("{\"session:A\":2}".utf8)

        // Deterministic opening race: the opening query sees first; the write
        // completes before monitor startup, so its baseline can only see second.
        // No later file event can repair the stale opening rows.
        try save(first)
        var cachedRowsReceipt = try receipt()
        require(cachedRowsReceipt == first, "Opening query must see the old receipt")
        try save(second)
        var reconciliations = 0
        let opening = RexReceiptMonitor(url: url) {
            reconciliations += 1
            cachedRowsReceipt = try? receipt()
        }
        opening.start()
        try await wait { reconciliations == 1 }
        try await settle()
        require(reconciliations == 1 && cachedRowsReceipt == second,
                "Startup must reconcile a change between opening query and baseline")
        opening.stop()

        try save(first)
        var deliveries = 0
        let monitor = RexReceiptMonitor(url: url) { deliveries += 1 }
        monitor.start()
        monitor.start()
        defer { monitor.stop() }
        try await wait { deliveries == 1 }
        try await settle()
        require(deliveries == 1, "Startup must emit exactly once; start must be idempotent")
        try save(first, unrelated: "light", atomic: true, format: .xml)
        try await settle()
        require(deliveries == 1, "Unrelated preferences and plist encoding must not emit")
        try save(second, atomic: true)
        try await wait { deliveries == 2 }
        try save(second)
        try await settle()
        require(deliveries == 2, "Same receipt value must not emit")
        // The monitor treats the key as an opaque plist value, not receipt JSON.
        try save(["B": 2, "A": 1], atomic: true)
        try await wait { deliveries == 3 }
        try save(["A": 1, "B": 2], atomic: true, format: .xml)
        try await settle()
        require(deliveries == 3, "Dictionary order must not count as a change")
        try save(nil, atomic: true)
        try await wait { deliveries == 4 }
        try save(nil, unrelated: "other")
        try await settle()
        require(deliveries == 4, "Absent key is stable")

        try Data("malformed plist".utf8).write(to: url)
        try await wait { deliveries == 5 }
        try PropertyListSerialization.data(fromPropertyList: ["not a dictionary"], format: .binary, options: 0)
            .write(to: url, options: .atomic)
        try await settle()
        try FileManager.default.removeItem(at: url)
        try await settle()
        require(deliveries == 5, "Repeated errors and deletion while unavailable must not emit")
        try save(nil, atomic: true)
        try await wait { deliveries == 6 }
        try await settle()
        require(deliveries == 6, "Recovery with unchanged absent key must emit once")
        try FileManager.default.removeItem(at: url)
        try await wait { deliveries == 7 }
        try Data("still unavailable".utf8).write(to: url, options: .atomic)
        try await settle()
        require(deliveries == 7, "Deletion must emit once; subsequent corruption must not emit")
        try save(first, atomic: true)
        try await wait { deliveries == 8 }
        try save(first, atomic: true)
        try await settle()
        require(deliveries == 8, "Recovery with changed key must emit once")

        // Writes separated by less than the debounce window form one update.
        for index in 0..<8 {
            try save(Data("burst-\(index)".utf8), atomic: true)
            try await Task.sleep(for: .milliseconds(10))
        }
        try await wait { deliveries == 9 }
        try await settle()
        require(deliveries == 9, "Write burst must coalesce")
        try save(Data("burst-7".utf8), atomic: true)
        try await settle()
        require(deliveries == 9, "Coalescing must retain the final value")

        try save(second, atomic: true)
        monitor.stop()
        monitor.stop()
        try await settle()
        require(deliveries == 9, "Stop must cancel a pending debounce")
        try save(first, atomic: true)
        try await settle()
        require(deliveries == 9, "Stopped monitor must not deliver file events")
        monitor.start()
        try await wait { deliveries == 10 }
        try await settle()
        require(deliveries == 10, "Restart must reconcile its fresh baseline once")
        // Block main delivery while the background reader completes. Stop then
        // restart must reject even a callback already queued for the old run.
        try save(second, atomic: true)
        blockMainDelivery()
        monitor.stop()
        monitor.start()
        try await wait { deliveries == 11 }
        try await settle()
        require(deliveries == 11, "Restart must emit once and reject old-generation delivery")
        try save(first, atomic: true)
        try await wait { deliveries == 12 }
        monitor.stop()
        try await settle()

        // Missing parent directories are watched through the nearest ancestor.
        let missing = root.appendingPathComponent("missing/preferences/rex.plist")
        var recovered = 0
        var temporary: RexReceiptMonitor? = RexReceiptMonitor(url: missing) { recovered += 1 }
        weak var weakMonitor = temporary
        temporary?.start()
        try await wait { recovered == 1 }
        try await settle()
        require(recovered == 1, "Unavailable startup must reconcile exactly once")
        try FileManager.default.createDirectory(at: missing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bad".utf8).write(to: missing)
        try await settle()
        require(recovered == 1, "Malformed initial preferences must not repeat unavailable delivery")
        let valid = try Data(contentsOf: url)
        try valid.write(to: missing, options: .atomic)
        try await wait { recovered == 2 }
        let watchedFDs = descriptorCount()
        temporary = nil
        require(weakMonitor == nil, "Monitor must not be retained by file callbacks")
        weakMonitor = nil
        try await settle()
        require(descriptorCount() < watchedFDs, "Deinit must close file observations")
        try Data("bad again".utf8).write(to: missing, options: .atomic)
        try await settle()
        require(recovered == 2, "Deinit must prevent subsequent delivery")
        print("Rex receipt checks passed")
    }

    private static func blockMainDelivery() { usleep(300_000) }

    private static func descriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
    }
}
