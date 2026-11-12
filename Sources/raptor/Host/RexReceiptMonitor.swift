import Foundation

/// Observes the raw receipt preference only. The backend interprets receipts.
@MainActor
final class RexReceiptMonitor {
    private let url: URL
    private let debounce: TimeInterval
    private let onChange: @MainActor () -> Void
    private var worker: ReceiptPreferenceWorker?
    private var generation = 0

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.superlogical.rex.plist"),
         debounce: TimeInterval = 0.08, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit { worker?.stop() }

    func start() {
        guard worker == nil else { return }
        generation += 1
        let token = generation
        let next = ReceiptPreferenceWorker(url: url, debounce: debounce) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.worker != nil, self.generation == token else { return }
                self.onChange()
            }
        }
        worker = next
        next.start()
    }

    func stop() {
        generation += 1
        worker?.stop()
        worker = nil
    }
}

/// All mutable state and preference I/O belong to this serial queue.
private final class ReceiptPreferenceWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "raptor.rex-receipts.read", qos: .utility)
    private let url: URL
    private let debounce: TimeInterval
    private let onChange: @Sendable () -> Void
    private var watcher: FocusFileWatcher?
    private var pending: DispatchWorkItem?
    private var revision = 0
    private var stopped = false
    private var previous: NSDictionary?
    private var hasRead = false

    init(url: URL, debounce: TimeInterval, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit { watcher?.stop() }

    func start() {
        queue.async { [self] in
            guard !stopped else { return }
            // The watcher's initial event runs after observation is installed.
            // Read the baseline there and always reconcile cached rows once:
            // receipts can change after the opening backend query.
            watcher = FocusFileWatcher(url: url, onChange: { [weak self] in
                self?.scheduleRead()
            }, onError: { _ in /* Missing/unreadable preferences are nonfatal. */ })
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            revision += 1
            pending?.cancel()
            pending = nil
            watcher?.stop()
            watcher = nil
            previous = nil
        }
    }

    private func scheduleRead() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.pending?.cancel()
            self.revision += 1
            let request = self.revision
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.stopped, self.revision == request else { return }
                self.pending = nil
                let updated = self.read()
                let changed: Bool
                switch (self.previous, updated) {
                case let (previous?, updated?): changed = !previous.isEqual(updated)
                case (nil, nil): changed = false
                default: changed = true
                }
                let initial = !self.hasRead
                self.hasRead = true
                self.previous = updated
                if initial || changed { self.onChange() }
            }
            self.pending = work
            self.queue.asyncAfter(deadline: .now() + self.debounce, execute: work)
        }
    }

    private func read() -> NSDictionary? {
        guard let data = try? Data(contentsOf: url),
              let preferences = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        // A wrapper distinguishes an absent key from an unavailable plist.
        // Foundation equality compares nested plist values without interpreting
        // receipt JSON, and ignores unrelated keys and dictionary ordering.
        if let value = preferences["Workspace.programActivitySeen"] {
            return ["value": value] as NSDictionary
        }
        return [:] as NSDictionary
    }
}
