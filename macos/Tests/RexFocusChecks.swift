import AppKit
import Foundation

private func testFailure(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(2)
}

private func require(_ condition: Bool, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) {
    if !condition { testFailure(message.isEmpty ? "Focus check failed at \(file):\(line)" : message) }
}

private actor FocusBackend: BackendClient {
    private var payloads: [[String: APIValue]] = []
    func request(_ method: String, params: [String: APIValue]) async throws -> APIResult {
        precondition(method == "sessions.visit")
        payloads.append(params)
        return APIResult()
    }
    func recorded() -> [[String: APIValue]] { payloads }
    nonisolated func close() {}
}

@MainActor
private final class FocusBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

@MainActor
struct RexFocusChecks {
    static func run() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("aux/focus-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rex.plist")
        func save(_ id: String, atomic: Bool = false) throws {
            let focus = try JSONSerialization.data(withJSONObject: ["sessionID": id])
            let data = try PropertyListSerialization.data(fromPropertyList: ["Workspace.lastFocusedSession": focus],
                                                          format: .binary, options: 0)
            try data.write(to: url, options: atomic ? .atomic : [])
        }
        func corrupt(_ value: Any) throws {
            try PropertyListSerialization.data(fromPropertyList: ["Workspace.lastFocusedSession": value],
                                               format: .xml, options: 0).write(to: url)
        }
        try save("session:full-A")
        require(try RexFocusTracker.read(url) == "session:full-A", "Decode plist Data JSON without shortening the ID")
        for bad: Any in ["not Data", Data("{}".utf8), Data("bad json".utf8), Data("{\"sessionID\":\"\"}".utf8), Data("{\"sessionID\":\"not-a-session\"}".utf8), Data("{\"sessionID\":\"session:bad id\"}".utf8)] {
            try corrupt(bad)
            do { _ = try RexFocusTracker.read(url); testFailure("Corrupt focus preference accepted") } catch {}
        }
        try Data("bad plist".utf8).write(to: url)
        do { _ = try RexFocusTracker.read(url); testFailure("Corrupt plist accepted") } catch {}
        try PropertyListSerialization.data(fromPropertyList: [:], format: .binary, options: 0).write(to: url)
        require(try RexFocusTracker.read(url) == nil, "Missing focus key is nonfatal")

        let rex = RexFocusApplication(bundleIdentifier: "com.superlogical.rex", processIdentifier: 42)
        var state = RexFocusState()
        let base = Date()
        func date(_ n: Double) -> Date { base.addingTimeInterval(n) }
        require(state.observe(sessionID: "A", application: nil, at: date(0)) == nil)
        require(state.observe(sessionID: "A", application: .init(bundleIdentifier: "other.app", processIdentifier: 42), at: date(1)) == nil)
        require(state.observe(sessionID: "A", application: .init(bundleIdentifier: "com.superlogical.rex", processIdentifier: 0), at: date(2)) == nil)
        require(state.observe(sessionID: "A", application: rex, at: date(3))?.initial == false,
                "First valid background read must consume the initial flag without emitting")
        state = RexFocusState()
        require(state.observe(sessionID: nil, application: rex, at: date(2)) == nil)
        let first = state.observe(sessionID: "A", application: rex, at: date(3))!
        require(first.initial && first.clientPID == 42)
        require(state.observe(sessionID: "A", application: rex, at: date(4)) == nil, "Duplicate writes must not emit")
        let second = state.observe(sessionID: "B", application: rex, at: date(5))!
        require(!second.initial)
        require(state.observe(sessionID: "A", application: rex, at: date(3)) == nil, "Delayed initial sample cannot undo navigation")
        require(state.observe(sessionID: "B", application: rex, at: date(6)) == nil)
        require(state.observe(sessionID: nil, application: rex, at: date(7)) == nil)
        require(state.observe(sessionID: "B", application: rex, at: date(8)) != nil, "Corruption must not suppress same-ID recovery")
        require(state.observe(sessionID: "B", application: .init(bundleIdentifier: "com.superlogical.rex", processIdentifier: 43), at: date(9))?.clientPID == 43)
        require(state.observe(sessionID: "B", application: nil, at: date(10)) == nil)
        require(state.observe(sessionID: "B", application: rex, at: date(11)) != nil, "Frontmost activation is a new observation")

        try save("session:full-A")
        let center = NotificationCenter()
        let application = FocusBox<RexFocusApplication?>(rex)
        var emissions: [RexFocusObservation] = []
        let available = FocusBox(false)
        let tracker = RexFocusTracker(url: url, center: center, frontmost: { application.value }) { observation in
            guard available.value else { return false }
            emissions.append(observation)
            return true
        }
        tracker.start()
        defer { tracker.stop() }
        try await Task.sleep(for: .milliseconds(150))
        require(emissions.isEmpty)
        available.value = true
        tracker.retryDelivery()
        try await wait { emissions.count == 1 }
        require(emissions[0].initial)
        for _ in 0..<4 { try save("session:full-A", atomic: true) }
        try await Task.sleep(for: .milliseconds(150))
        require(emissions.count == 1, "Atomic duplicate writes must not send requests")
        try save("session:full-B", atomic: true)
        try await wait { emissions.count == 2 }
        require(emissions.last?.sessionID == "session:full-B" && emissions.last?.initial == false)
        try FileManager.default.removeItem(at: url)
        try await Task.sleep(for: .milliseconds(150))
        try save("session:full-B")
        try await wait { emissions.count == 3 }
        try corrupt(Data("invalid".utf8))
        try await Task.sleep(for: .milliseconds(150))
        try save("session:full-B", atomic: true)
        try await wait { emissions.count == 4 }
        application.value = .init(bundleIdentifier: "other.app", processIdentifier: 42)
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        try save("session:full-C", atomic: true)
        try await Task.sleep(for: .milliseconds(100))
        require(emissions.count == 4, "Background Rex must not emit")
        application.value = rex
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        try await wait { emissions.count == 5 }
        require(emissions.last?.sessionID == "session:full-C")
        tracker.stop()
        try save("session:full-D", atomic: true)
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        require(emissions.count == 5, "Stopped tracker must cancel observers and file delivery")

        // A replacement model can become available before the old backend's
        // failed ACK returns. Do not lose that retry or change its timestamp.
        let held = FocusBox<CheckedContinuation<Bool, Never>?>(nil)
        let attempts = FocusBox<[RexFocusObservation]>([])
        let recovering = RexFocusTracker(url: url, center: center, frontmost: { rex }) { observation in
            attempts.value.append(observation)
            if attempts.value.count == 1 {
                return await withCheckedContinuation { held.value = $0 }
            }
            return true
        }
        recovering.start()
        try await wait { held.value != nil }
        recovering.retryDelivery()
        held.value?.resume(returning: false); held.value = nil
        try await wait { attempts.value.count == 2 }
        require(attempts.value[0] == attempts.value[1], "Retry must keep the original initial flag/time")
        recovering.stop()

        try save("session:queue-A", atomic: true)
        let slowAck = FocusBox<CheckedContinuation<Bool, Never>?>(nil)
        let delivered = FocusBox<[RexFocusObservation]>([])
        let queued = RexFocusTracker(url: url, center: center, frontmost: { rex }) { observation in
            delivered.value.append(observation)
            if delivered.value.count == 1 {
                return await withCheckedContinuation { slowAck.value = $0 }
            }
            return true
        }
        queued.start()
        try await wait { slowAck.value != nil }
        try save("session:queue-B", atomic: true)
        try await Task.sleep(for: .milliseconds(150))
        try save("session:queue-C", atomic: true)
        try await Task.sleep(for: .milliseconds(150))
        slowAck.value?.resume(returning: true); slowAck.value = nil
        try await wait { delivered.value.count == 3 }
        require(delivered.value.map(\.sessionID) == ["session:queue-A", "session:queue-B", "session:queue-C"],
                "A slow backend must not lose distinct focus visits")
        queued.stop()

        let backend = FocusBackend()
        let model = PickerModel(options: try LaunchOptions(arguments: []), backend: backend)
        // Hidden, never started, and context-changing: this is not a UI request.
        _ = model.prepareReconfigure(try LaunchOptions(arguments: ["--session", "different"]))
        require(!model.contextReady)
        let accepted = await model.observeRexFocus(first)
        require(accepted, "Hidden focus delivery must bypass context-ready guards")
        let payloads = await backend.recorded()
        require(payloads.count == 1)
        let data = try JSONEncoder().encode(payloads[0])
        let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        require(payload["session_id"] as? String == "A" && payload["client_pid"] as? String == "42")
        require(payload["initial"] as? Bool == true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        require(formatter.date(from: payload["observed_at"] as! String)! <= first.observedAt,
                "Encoding must not round an observation into the future")
        let fractional = RexFocusObservation(sessionID: "session:time", clientPID: 42,
                                              observedAt: Date(timeIntervalSince1970: 1700000000.1239), initial: false)
        if case let .text(encoded) = fractional.params["observed_at"] {
            require(formatter.date(from: encoded)! <= fractional.observedAt)
        } else { testFailure("Missing observation timestamp") }
        require(model.items.isEmpty, "Focus delivery must not mutate visible rows")
        model.close()
        let closedAccepted = await model.observeRexFocus(second)
        require(!closedAccepted)
        let finalPayloads = await backend.recorded()
        require(finalPayloads.count == 1, "Closed models must not send")
        print("Rex focus checks passed")
    }

    private static func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        testFailure("Timed out waiting for focus observation")
    }
}
