import SwiftUI

@MainActor
final class PickerModel: ObservableObject {
    enum Page: Hashable { case directories, repositories, worktrees, create }
    enum ViewKind: Hashable { case repos, tabs }
    private(set) var options: LaunchOptions
    private let backend: any BackendClient
    @Published var view: ViewKind = .repos
    @Published var page: Page
    @Published var query = "" { didSet { if query != oldValue && page != .create && !changingContext { scheduleQuery() } } }
    @Published var items: [PickerItem] = []
    @Published var selectedID: String?
    @Published var scrollID: String?
    @Published private(set) var refreshing = false
    @Published var targets: [String] = []
    @Published var target = ""
    @Published var repo: String?
    @Published var branches: [String] = []
    @Published var branch = "" { didSet { if branch != oldValue { schedulePreview() } } }
    @Published var base = "" { didSet { if base != oldValue { schedulePreview() } } }
    @Published var destinationRoot: String?
    @Published var destination: String?
    @Published var validationError: String?
    @Published var previewReady = false
    @Published var createdPath: String?
    @Published var loading = false
    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?
    @Published var splitMode = false
    @Published var removalCandidate: PickerItem?
    @Published var renameCandidate: PickerItem?
    @Published var renameLabel: String?
    @Published var basePickerPresented = false
    @Published var targetPickerPresented = false
    @Published var themeLoaded = false
    var onClose: (() -> Void)?
    var onFocusSearch: (() -> Void)?
    var onAdvanceFormFocus: ((Bool) -> Void)?
    private var queryTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var themeTask: Task<Void, Never>?
    private var generation = 0
    private var previewGeneration = 0
    private var closed = false
    private var createParent: Page = .worktrees
    private struct CacheKey: Hashable {
        let view: ViewKind
        let page: Page
        let repo: String?
        let query: String
    }
    private struct CachedList {
        let result: APIResult
        var selectedID: String?
        var scrollID: String?
        var target: String
    }
    private var cache: [CacheKey: CachedList] = [:]
    private var activeKey: CacheKey?
    private var viewQueries: [ViewKind: String] = [:]
    private var changingContext = false
    private var contextGeneration = 0
    @Published private(set) var contextReady = true
    private var started = false

    private var cacheKey: CacheKey {
        CacheKey(view: view, page: page, repo: page == .directories ? nil : repo, query: query)
    }

    private func saveListPosition() {
        guard let activeKey, var entry = cache[activeKey] else { return }
        entry.selectedID = selectedID
        entry.scrollID = scrollID
        entry.target = target
        cache[activeKey] = entry
    }

    // A mutation can affect both lists (for example, a worktree and its session).
    // Never allow an older in-flight response to repopulate either cache.
    private func invalidateLists() {
        generation += 1
        queryTask?.cancel()
        cache.removeAll()
        activeKey = nil
        refreshing = false
    }

    private func request(_ method: String, params: [String: APIValue]) async throws -> APIResult {
        try Task.checkCancellation()
        guard !closed, contextReady else { throw CancellationError() }
        let context = contextGeneration
        let result = try await backend.request(method, params: params)
        try Task.checkCancellation()
        guard context == contextGeneration, !closed else { throw CancellationError() }
        return result
    }

    init(options: LaunchOptions, backend: any BackendClient) {
        self.options = options
        self.backend = backend
        self.page = options.mode == "wt-create" ? .create : (options.mode == "wt" ? .worktrees : .directories)
        self.repo = options.repo
        self.loading = true
    }

    var selected: PickerItem? { items.first { $0.id == selectedID } }
    /// Resident recovery: did the shared backend connection die?
    var backendIsClosed: Bool { (backend as? ProcessBackend)?.isClosed ?? false }
    var canOpen: Bool {
        guard contextReady, !busy, !loading, selected != nil else { return false }
        if view == .tabs { return selected?.isSessionEntry == true }
        return !target.isEmpty
    }
    var canCreate: Bool { contextReady && !busy && !loading && !basePickerPresented && !targetPickerPresented && previewReady && validationError == nil && destination != nil && !branch.isEmpty && !base.isEmpty && !target.isEmpty && createdPath == nil }
    var canSubmitForm: Bool { contextReady && !basePickerPresented && (canCreate || (!busy && createdPath != nil && !target.isEmpty)) }
    var heading: String {
        switch view {
        case .tabs: return "Sessions"
        case .repos:
            switch page {
            case .directories: return "Open directory"
            case .repositories: return "Choose repository"
            case .worktrees: return "Worktrees"
            case .create: return "Create worktree"
            }
        }
    }

    func start() {
        guard !started, contextReady, !closed else { return }
        started = true
        loadTheme()
        scheduleQuery(immediate: true)
    }

    // Fetch the active Rex theme from the backend and repaint. On failure
    // the current palette stays; RaptorApplication seeds it from the system
    // appearance before any picker opens.
    private func loadTheme() {
        themeTask = Task { [weak self] in
            let result = try? await self?.backend.request("theme", params: [:])
            guard let self, !self.closed, !Task.isCancelled else { return }
            if let payload = result?.theme {
                PickerPalette.apply(payload)
            }
            self.themeLoaded = true
        }
    }
    var showsPills: Bool { page != .create && page != .repositories }


    /// Synchronous open boundary: reset origin state before the panel is shown.
    /// Only global directory results survive. The returned token owns completion.
    @discardableResult
    func prepareReconfigure(_ options: LaunchOptions) -> Int {
        saveListPosition()
        contextGeneration += 1
        contextReady = false
        changingContext = true
        generation += 1
        queryTask?.cancel()
        cache = cache.filter { $0.key.view == .repos && $0.key.page == .directories && $0.key.repo == nil }
            .mapValues { entry in
                CachedList(result: APIResult(items: entry.result.items), selectedID: entry.selectedID,
                           scrollID: entry.scrollID, target: "")
            }
        activeKey = nil
        refreshing = false
        previewGeneration += 1
        previewTask?.cancel(); operationTask?.cancel(); themeTask?.cancel()
        busy = false
        items = []; selectedID = nil; scrollID = nil
        targets = []; target = ""
        branches = []; base = ""; branch = ""
        destination = nil; destinationRoot = nil; previewReady = false; validationError = nil
        viewQueries.removeAll()
        loading = true
        self.options = options
        closed = false
        view = .repos
        page = options.mode == "wt-create" ? .create : (options.mode == "wt" ? .worktrees : .directories)
        repo = options.repo
        query = ""
        splitMode = false
        error = nil
        notice = nil
        createdPath = nil
        removalCandidate = nil
        renameCandidate = nil; renameLabel = nil
        basePickerPresented = false
        targetPickerPresented = false
        changingContext = false
        if page == .directories, let cached = cache[cacheKey] {
            activeKey = cacheKey
            items = cached.result.items ?? []
            selectedID = cached.selectedID ?? items.first?.id
            scrollID = cached.scrollID
            // Targets belong to the new origin, not the cached directory rows.
            loading = false
        }
        refreshing = true
        return contextGeneration
    }

    /// Failure leaves every action gated; cached rows remain display-only.
    func completeReconfigure(_ context: Int) async {
        guard context == contextGeneration, !closed else { return }
        let options = self.options
        do {
            _ = try await backend.request("context", params: [
                "session": .text(options.session), "block": .text(options.block),
                "client": .text(options.client), "title": .text(options.title),
            ])
            try Task.checkCancellation()
            guard context == contextGeneration, !closed else { return }
            contextReady = true
            started = true
            loadTheme()
            scheduleQuery(immediate: true)
        } catch {
            guard context == contextGeneration, !closed else { return }
            loading = false
            refreshing = false
            self.error = "Cannot set picker context. Close and reopen. \(error.localizedDescription)"
        }
    }

    func reconfigure(_ options: LaunchOptions) async {
        await completeReconfigure(prepareReconfigure(options))
    }

    func switchView(backward: Bool = false) {
        guard contextReady else { return }
        guard !busy, page != .create, page != .repositories else { return }
        saveListPosition()
        viewQueries[view] = query
        view = view == .repos ? .tabs : .repos
        changingContext = true
        query = viewQueries[view] ?? ""
        changingContext = false
        splitMode = false
        removalCandidate = nil
        error = nil
        notice = nil
        scheduleQuery(immediate: true)
        onFocusSearch?()
    }

    /// Open the row at a 1-based position (⌘1–9 / alt-1–9).
    func openNumbered(_ number: Int) {
        guard contextReady else { return }
        guard number >= 1, number <= items.count, !busy, !loading else { return }
        guard view == .tabs || page == .directories || page == .worktrees else { return }
        selectedID = items[number - 1].id
        choose()
    }

    func togglePin() {
        guard contextReady else { return }
        guard view == .repos, page == .directories, !busy, let selected else { return }
        let path = selected.path
        perform {
            _ = try await self.request("pins.toggle", params: ["path": .text(path)])
            self.invalidateLists()
            self.scheduleQuery(immediate: true)
        }
    }

    func requestCloseEntry() {
        guard contextReady else { return }
        guard view == .tabs, !busy, let selected, selected.isSessionEntry else { return }
        removalCandidate = selected
    }

    func confirmCloseEntry() {
        guard contextReady else { return }
        guard view == .tabs, !busy, let candidate = removalCandidate, candidate.isSessionEntry else { return }
        removalCandidate = nil
        perform {
            _ = try await self.request("sessions.close", params: [
                "kind": .text(candidate.kind ?? "window"),
                "session_id": .text(candidate.sessionID ?? candidate.path),
                "window_id": .text(candidate.kind == "window" ? candidate.path : ""),
            ])
            self.invalidateLists()
            self.scheduleQuery(immediate: true)
        }
    }

    func beginRename() {
        guard contextReady else { return }
        guard view == .tabs, !busy, let selected, selected.isSessionEntry else { return }
        renameCandidate = selected
        renameLabel = selected.label ?? ""
    }

    func commitRename() {
        guard contextReady else { return }
        guard let candidate = renameCandidate, !busy, let label = renameLabel, !label.isEmpty else { return }
        renameCandidate = nil
        perform {
            _ = try await self.request("sessions.rename", params: [
                "kind": .text(candidate.kind ?? "window"),
                "session_id": .text(candidate.sessionID ?? candidate.path),
                "window_id": .text(candidate.kind == "window" ? candidate.path : ""),
                "label": .text(label),
            ])
            self.invalidateLists()
            self.scheduleQuery(immediate: true)
        }
    }

    func cancelRename() { renameCandidate = nil; renameLabel = nil }
    func close() {
        guard !closed else { return }
        closed = true
        contextGeneration += 1
        queryTask?.cancel(); previewTask?.cancel(); operationTask?.cancel(); themeTask?.cancel()
        onAdvanceFormFocus = nil; onFocusSearch = nil
        backend.close()
        onClose?()
    }

    private func scheduleQuery(immediate: Bool = false) {
        guard !closed, !changingContext, contextReady else { return }
        saveListPosition()
        generation += 1
        let token = generation
        queryTask?.cancel()
        let key = cacheKey
        let cached = page == .create ? nil : cache[key]
        activeKey = cached == nil ? nil : key
        items = cached?.result.items ?? []
        selectedID = cached?.selectedID ?? items.first?.id
        scrollID = cached?.scrollID
        if let cached {
            targets = cached.result.targets ?? []
            target = cached.target
        }
        loading = cached == nil
        refreshing = true
        splitMode = false
        error = nil
        let currentPage = page
        let currentView = view
        let currentQuery = query
        let currentRepo = repo
        queryTask = Task { [weak self] in
            guard let self else { return }
            do {
                if !immediate { try await Task.sleep(for: .milliseconds(140)) }
                try Task.checkCancellation()
                var params: [String: APIValue] = ["query": .text(currentQuery)]
                let method: String
                if currentView == .tabs {
                    method = "sessions"
                } else if currentPage == .worktrees || currentPage == .create {
                    method = "worktrees.list"
                    if let currentRepo { params["repo"] = .text(currentRepo) }
                } else {
                    method = "directories"
                    params["repos_only"] = .flag(currentPage == .repositories)
                }
                let result = try await self.request(method, params: params)
                guard !Task.isCancelled, token == self.generation, !self.closed else { return }
                if currentView == .repos, (currentPage == .worktrees || currentPage == .create), result.needsRepo == true {
                    self.repo = nil
                    self.navigate(.repositories)
                    return
                }
                let previous = self.selectedID
                self.items = currentPage == .create ? [] : (result.items ?? [])
                self.selectedID = self.items.contains { $0.id == previous } ? previous : self.items.first?.id
                if let targets = result.targets { self.targets = targets }
                if !self.targets.contains(self.target) { self.target = result.target ?? self.targets.first ?? "" }
                if currentView == .repos, currentPage == .worktrees || currentPage == .create {
                    self.repo = result.repo ?? currentRepo
                    self.destinationRoot = result.destinationRoot
                    self.branches = result.branches ?? []
                    self.base = result.baseBranch ?? self.branches.first ?? ""
                }
                if !self.items.contains(where: { $0.id == self.scrollID }) { self.scrollID = nil }
                self.loading = false
                self.refreshing = false
                if currentPage != .create {
                    let resolvedKey = self.cacheKey
                    self.activeKey = resolvedKey
                    self.cache[resolvedKey] = CachedList(result: result, selectedID: self.selectedID,
                                                        scrollID: self.scrollID, target: self.target)
                }
                if currentPage == .create { self.schedulePreview() }
            } catch {
                guard !Task.isCancelled, token == self.generation, !self.closed else { return }
                self.loading = false
                self.refreshing = false
                // A refresh failure must not discard a usable cached list.
                self.error = error.localizedDescription
            }
        }
    }

    private func navigate(_ newPage: Page) {
        generation += 1
        previewGeneration += 1
        queryTask?.cancel(); previewTask?.cancel()
        saveListPosition()
        activeKey = nil
        page = newPage
        items = []; selectedID = nil; scrollID = nil; splitMode = false
        error = nil; notice = nil
        changingContext = true
        query = ""
        changingContext = false
        scheduleQuery(immediate: true)
        if newPage != .create { onFocusSearch?() }
    }

    func move(_ delta: Int) {
        guard contextReady else { return }
        guard !loading, !busy, !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == selectedID } ?? 0
        selectedID = items[min(max(index + delta, 0), items.count - 1)].id
        scrollID = selectedID
    }

    func cycleTarget(backward: Bool) {
        guard contextReady else { return }
        guard !busy, page != .repositories, !targets.isEmpty else { return }
        let index = targets.firstIndex(of: target) ?? 0
        target = targets[(index + (backward ? targets.count - 1 : 1)) % targets.count]
    }

    func advanceFormFocus(backward: Bool) { if contextReady { onAdvanceFormFocus?(backward) } }

    func searchBaseBranches(_ query: String) async throws -> [String] {
        guard contextReady, !closed, let repo else { throw APIError.message("Choose a repository first.") }
        let result = try await request("worktrees.branches", params: ["repo": .text(repo), "query": .text(query)])
        let matches = result.branches ?? []
        if query.isEmpty { branches = matches }
        return matches
    }

    func choose() {
        guard contextReady else { return }
        guard !busy, !loading, let selected else { return }
        if view == .tabs {
            jump(selected)
        } else if page == .repositories {
            repo = selected.path
            navigate(options.mode == "wt-create" ? .create : .worktrees)
        } else if canOpen {
            dispatch(path: selected.path, target: target)
        }
    }

    private func jump(_ entry: PickerItem) {
        perform {
            _ = try await self.request("sessions.jump", params: [
                "kind": .text(entry.kind ?? "window"),
                "session_id": .text(entry.sessionID ?? entry.path),
                "window_id": .text(entry.kind == "window" ? entry.path : ""),
            ])
            if self.options.demo {
                self.notice = "Demo only: jumped to \(entry.label ?? entry.path). No Rex call."
            } else { self.close() }
        }
    }

    func showWorktrees() {
        guard contextReady else { return }
        guard !busy, !loading, page == .directories else { return }
        repo = selected?.path
        navigate(.worktrees)
    }

    func beginCreate() {
        guard contextReady else { return }
        guard !busy, !loading else { return }
        if page == .directories {
            guard let selected else { return }
            createParent = .directories
            repo = selected.path
            branch = ""
            navigate(.create)
            return
        }
        guard page == .worktrees, repo != nil else { return }
        createParent = .worktrees
        saveListPosition()
        generation += 1
        queryTask?.cancel()
        refreshing = false
        activeKey = nil
        page = .create
        splitMode = false
        error = nil; notice = nil; createdPath = nil
        branch = ""
        schedulePreview()
    }

    func escape() {
        if !contextReady { close(); return }
        guard removalCandidate == nil, !busy else { return }
        if renameCandidate != nil { cancelRename(); return }
        if basePickerPresented { basePickerPresented = false; return }
        if targetPickerPresented { targetPickerPresented = false; return }
        if splitMode { splitMode = false; return }
        if view == .tabs {
            if !query.isEmpty { query = "" } else { switchView() }
            return
        }
        if page == .create {
            if options.mode == "wt-create" { close() } else { navigate(createParent) }
        } else if !query.isEmpty {
            query = ""
        } else if page == .worktrees || page == .repositories {
            navigate(.directories)
        } else { close() }
    }

    func split(_ direction: String) {
        guard splitMode, canOpen, page != .repositories, let selected else { return }
        splitMode = false
        dispatch(path: selected.path, target: direction)
    }

    func toggleSplit() {
        guard canOpen, page == .directories || page == .worktrees else { return }
        splitMode.toggle()
    }

    private func schedulePreview() {
        guard contextReady, page == .create, !closed, createdPath == nil else { return }
        previewGeneration += 1
        let token = previewGeneration
        previewTask?.cancel()
        previewReady = false
        destination = nil; validationError = nil
        guard !loading, let repo, !branch.isEmpty, !base.isEmpty else { return }
        let branch = branch, base = base
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(180))
                try Task.checkCancellation()
                let result = try await self.request("worktrees.preview", params: ["repo": .text(repo), "branch": .text(branch), "base": .text(base)])
                guard !Task.isCancelled, token == self.previewGeneration, self.page == .create, !self.closed else { return }
                self.destination = result.path
                self.validationError = result.validationError.flatMap { $0.isEmpty ? nil : $0 }
                self.previewReady = true
                self.error = nil
            } catch {
                guard !Task.isCancelled, token == self.previewGeneration, !self.closed else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func create() {
        guard contextReady else { return }
        guard !basePickerPresented else { return }
        if createdPath != nil { openCreated(); return }
        guard canCreate, let repo else { return }
        let params: [String: APIValue] = ["repo": .text(repo), "branch": .text(branch), "base": .text(base)]
        let target = target
        perform {
            let result = try await self.request("worktrees.create", params: params)
            guard let path = result.path, !path.isEmpty else { throw APIError.message("Backend returned no worktree path.") }
            self.invalidateLists()
            // Commit this state before opening. A failed dispatch must never
            // turn the retry button into a second create request.
            self.createdPath = path
            do { try await self.openPath(path, target: target) }
            catch { throw APIError.message("Worktree created, but opening failed. \(error.localizedDescription)") }
        }
    }

    func askRemove() {
        guard contextReady else { return }
        guard !busy, !loading, page == .worktrees, let selected, selected.isMain == false else { return }
        removalCandidate = selected
    }

    func confirmRemove(_ candidate: PickerItem) {
        guard contextReady else { return }
        guard let repo, !busy, page == .worktrees, candidate.isMain == false else { return }
        removalCandidate = nil
        perform {
            _ = try await self.request("worktrees.remove", params: ["repo": .text(repo), "path": .text(candidate.path)])
            self.invalidateLists()
            self.scheduleQuery(immediate: true)
        }
    }

    func openCreated() {
        guard contextReady else { return }
        guard !busy, let path = createdPath, !target.isEmpty else { return }
        dispatch(path: path, target: target)
    }

    private func dispatch(path: String, target: String) {
        perform { try await self.openPath(path, target: target) }
    }

    private func openPath(_ path: String, target: String) async throws {
        _ = try await request("dispatch", params: ["target": .text(target), "path": .text(path)])
        invalidateLists()
        if options.demo {
            notice = "Demo only: opened \(PathDisplay.abbreviate(path, home: "/Users/demo")) → \(Self.targetLabel(target)). No Rex call."
        } else { close() }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard contextReady, !busy, !closed else { return }
        let context = contextGeneration
        busy = true; error = nil; splitMode = false
        operationTask = Task { [weak self] in
            guard let self, context == self.contextGeneration, !Task.isCancelled, !self.closed else { return }
            defer { if context == self.contextGeneration { self.busy = false } }
            do { try await operation() }
            catch { if context == self.contextGeneration, !self.closed { self.error = error.localizedDescription } }
        }
    }

    static func targetLabel(_ target: String) -> String {
        switch target {
        case "tab": return "New tab"
        case "session": return "Session"
        case "here": return "cd here"
        case "pane_right": return "Split right"
        case "pane_below": return "Split below"
        default: return target
        }
    }
}
