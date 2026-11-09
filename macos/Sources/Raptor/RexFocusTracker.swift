import AppKit
import Foundation

struct RexFocusApplication: Equatable, Sendable {
    let bundleIdentifier: String?
    let processIdentifier: Int32
}

struct RexFocusObservation: Equatable, Sendable {
    let sessionID: String
    let clientPID: Int32
    let observedAt: Date
    let initial: Bool

    var params: [String: APIValue] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // ISO8601DateFormatter rounds to milliseconds. Round down first so
        // serialization cannot turn a valid sample into a future timestamp.
        let encodedDate = Date(timeIntervalSince1970: floor(observedAt.timeIntervalSince1970 * 1000) / 1000)
        return ["session_id": .text(sessionID), "client_pid": .text(String(clientPID)),
                "observed_at": .text(formatter.string(from: encodedDate)), "initial": .flag(initial)]
    }
}

/// Invalid samples reset deduplication, never the backend's stored history.
struct RexFocusState {
    private var lastApplication: RexFocusApplication?
    private var lastSession: String?
    private var lastSample: Date?
    private var hasRead = false

    mutating func observe(sessionID: String?, application: RexFocusApplication?, at date: Date) -> RexFocusObservation? {
        guard lastSample.map({ date > $0 }) ?? true else { return nil }
        lastSample = date
        let validMetadata = sessionID.map { !$0.isEmpty } ?? false
        let initial = !hasRead
        if validMetadata { hasRead = true }
        guard let sessionID, validMetadata, let application,
              application.bundleIdentifier == "com.superlogical.rex", application.processIdentifier > 0 else {
            lastApplication = nil; lastSession = nil
            return nil
        }
        guard lastApplication != application || lastSession != sessionID else { return nil }
        lastApplication = application; lastSession = sessionID
        let observation = RexFocusObservation(sessionID: sessionID, clientPID: application.processIdentifier,
                                              observedAt: date, initial: initial)
        return observation
    }
}

/// NotificationCenter supports removal from any thread, including deinit.
private final class FocusActivationObserver: @unchecked Sendable {
    let center: NotificationCenter
    let token: NSObjectProtocol
    init(center: NotificationCenter, handler: @escaping @Sendable (Notification) -> Void) {
        self.center = center
        token = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                   object: nil, queue: .main, using: handler)
    }
    deinit { center.removeObserver(token) }
}

/// Temporary private-preference adapter. No polling, UserDefaults or catalog events.
@MainActor
final class RexFocusTracker {
    typealias Emit = @MainActor (RexFocusObservation) async -> Bool
    private let url: URL
    private let frontmost: @MainActor () -> RexFocusApplication?
    private let center: NotificationCenter
    private let emit: Emit
    private let reader = DispatchQueue(label: "raptor.rex-focus.read", qos: .utility)
    private var watcher: FocusFileWatcher?
    private var activationObserver: FocusActivationObserver?
    private var state = RexFocusState()
    private var generation = 0
    private var revision = 0
    private var latestRead: Date?
    private var pending: [RexFocusObservation] = []
    private let pendingLimit = 32
    private var delivery: Task<Void, Never>?
    private var deliveryRetryRequested = false

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.superlogical.rex.plist"),
         center: NotificationCenter = NSWorkspace.shared.notificationCenter,
         frontmost: @escaping @MainActor () -> RexFocusApplication? = {
             NSWorkspace.shared.frontmostApplication.map {
                 RexFocusApplication(bundleIdentifier: $0.bundleIdentifier, processIdentifier: $0.processIdentifier)
             }
         }, emit: @escaping Emit) {
        self.url = url; self.center = center; self.frontmost = frontmost; self.emit = emit
    }

    deinit {
        watcher?.stop()
        delivery?.cancel()
    }

    func start() {
        guard watcher == nil else { return }
        generation += 1
        let token = generation
        watcher = FocusFileWatcher(url: url, onChange: { [weak self] in
            let date = Date()
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.refresh(at: date)
            }
        }, onError: { _ in /* Missing/unreadable preferences are nonfatal. */ })
        activationObserver = FocusActivationObserver(center: center) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(at: Date()) }
        }
    }

    private func refresh(at date: Date) {
        guard latestRead.map({ date > $0 }) ?? true else { return }
        latestRead = date
        revision += 1
        let request = revision, token = generation, application = frontmost(), url = url
        reader.async { [weak self] in
            let sessionID = try? Self.read(url)
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.revision == request,
                      self.frontmost() == application else { return }
                if let observation = self.state.observe(sessionID: sessionID, application: application, at: date) {
                    // Preserve distinct focus transitions while the backend is
                    // busy. Only overload drops old observations, not normal A→B→C.
                    if self.pending.count == self.pendingLimit { self.pending.removeFirst() }
                    self.pending.append(observation)
                    self.retryDelivery()
                }
            }
        }
    }

    /// Call when the current model becomes available. Retain the original time,
    /// so a delayed initial observation cannot replace a newer confirmed visit.
    func retryDelivery() {
        guard watcher != nil, !pending.isEmpty else { return }
        if delivery != nil {
            deliveryRetryRequested = true
            return
        }
        let token = generation
        delivery = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.delivery = nil } }
            while let observation = self.pending.first, !Task.isCancelled, self.generation == token {
                self.deliveryRetryRequested = false
                let accepted = await self.emit(observation)
                guard !Task.isCancelled, self.generation == token else { return }
                if accepted {
                    if let index = self.pending.firstIndex(of: observation) { self.pending.remove(at: index) }
                } else if !self.deliveryRetryRequested { return }
            }
        }
    }

    func stop() {
        generation += 1; revision += 1
        watcher?.stop(); watcher = nil
        activationObserver = nil
        delivery?.cancel(); delivery = nil
        deliveryRetryRequested = false
        pending = []
        latestRead = nil
        state = RexFocusState()
    }

    nonisolated static func read(_ url: URL) throws -> String? {
        let data = try Data(contentsOf: url)
        guard let preferences = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        guard let value = preferences["Workspace.lastFocusedSession"] else { return nil }
        guard let value = value as? Data else { throw CocoaError(.propertyListReadCorrupt) }
        struct Focus: Decodable { let sessionID: String }
        let focus = try JSONDecoder().decode(Focus.self, from: value)
        guard focus.sessionID.hasPrefix("session:"), focus.sessionID.count > 8, focus.sessionID.count <= 256,
              !focus.sessionID.contains(where: { $0.isWhitespace || $0.isNewline }),
              !focus.sessionID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return focus.sessionID
    }
}
