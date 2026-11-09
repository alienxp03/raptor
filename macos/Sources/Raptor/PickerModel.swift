import SwiftUI

@MainActor
final class PickerModel: ObservableObject {
    enum Page: Hashable { case directories, worktrees, create }
    enum ViewKind: Hashable, CaseIterable { case sessions, agents }
    private(set) var options: LaunchOptions
    private let backend: any BackendClient
    @Published var view: ViewKind = .sessions
    @Published var page: Page
    @Published var query = "" {
        didSet {
            if query != oldValue && page != .create && !changingContext {
                // A changed search takes fresh backend relevance, even for a revisited query.
                agentOrder.removeValue(forKey: cacheKey)
                agentGroups.removeValue(forKey: cacheKey)
                scheduleQuery(freshQuery: true)
            }
        }
    }
    @Published var items: [PickerItem] = []
    @Published private(set) var sessionHosts: [HostHeader] = []
    @Published var selectedID: String?
    @Published var scrollID: String?
    @Published private(set) var refreshing = false
    @Published var targets: [String] = []
    @Published var target = ""
    @Published var repo: String? {
        didSet {
            if repo != oldValue { suggestedBranch = nil }
        }
    }
    private(set) var suggestedBranch: String?
    private(set) var branchWasEdited = false
    private var branchDefaultApplied = false
    private var settingBranchDefault = false
    @Published var branches: [String] = []
    @Published var branch = "" {
        didSet {
            if branch != oldValue {
                if !settingBranchDefault && page == .create { branchWasEdited = true }
                schedulePreview()
            }
        }
    }
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
    @Published var basePickerPresented = false
    @Published var targetPickerPresented = false
    @Published var themeLoaded = false
    @Published private(set) var themeRevision = 0
    private var activeTheme: ThemePayload?
    // The resident host keeps its catalog process across successful navigation.
    var keepsBackendWarmOnNavigation = false
    var onClose: (() -> Void)?
    var onDismiss: (() -> Void)?
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
        var refreshedAt = Date()
        var selectedID: String?
        var scrollID: String?
        var target: String
    }
    private var cache: [CacheKey: CachedList] = [:]
    private var activeKey: CacheKey?
    private var displayedKey: CacheKey?
    // Per presentation and query. Cache stores backend order for the next open.
    private var agentOrder: [CacheKey: [String]] = [:]

    private var agentGroups: [CacheKey: [String: AgentGroup]] = [:]

    private func orderedAgents(_ rows: [PickerItem], key: CacheKey, capture: Bool = true) -> [PickerItem] {
        guard key.view == .agents else { return rows }
        if agentOrder[key] == nil, capture {
            agentOrder[key] = rows.map(\.id)
            agentGroups[key] = Dictionary(rows.map { ($0.id, $0.agentGroup) }, uniquingKeysWith: { first, _ in first })
        }
        guard let order = agentOrder[key] else { return rows }
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        // New records stay in the raw cache, not in this presentation.
        return order.compactMap { byID[$0] }
    }

    struct AgentSection: Identifiable {
        let group: AgentGroup
        let items: [PickerItem]
        var id: String { group.rawValue }
    }

    var agentSections: [AgentSection] {
        let groups = agentGroups[displayedKey ?? cacheKey] ?? [:]
        return AgentGroup.allCases.compactMap { group in
            let rows = items.filter { (groups[$0.id] ?? $0.agentGroup) == group }
            return rows.isEmpty ? nil : AgentSection(group: group, items: rows)
        }
    }

    func numberedPosition(of item: PickerItem) -> Int {
        (items.firstIndex { $0.id == item.id } ?? -1) + 1
    }
    private var viewQueries: [ViewKind: String] = [:]
    private var changingContext = false
    private var contextGeneration = 0
    private var reconfigureGeneration = 0
    private var warmReconfigure: Int?
    private var queryKey: CacheKey?
    private let cacheTTL: TimeInterval
    @Published private(set) var contextReady = true
    private var started = false
    private var presented = false
    private var eventEpoch = 0
    private var subscriptionTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var activityDirty = false

    /// AppKit visibility, not SwiftUI appearance: the resident view stays mounted.
    func setPresented(_ visible: Bool) {
        guard visible != presented, !closed else { return }
        presented = visible
        renewSubscription()
    }

    private func renewSubscription() {
        eventEpoch += 1
        let epoch = eventEpoch
        activityTask?.cancel(); activityTask = nil; activityDirty = false
        let previous = subscriptionTask
        let enabled = presented && contextReady && !closed
        subscriptionTask = Task { [weak self, backend] in
            // Serialize subscription transitions even for reentrant test actors.
            await previous?.value
            guard let self else { return }
            if enabled && (epoch != self.eventEpoch || self.closed) { return }
            do {
                let handler: (@Sendable () -> Void)?
                if enabled {
                    handler = { [weak self] in
                        Task { @MainActor [weak self] in
                            guard let self, self.eventEpoch == epoch else { return }
                            self.activityChanged()
                        }
                    }
                } else { handler = nil }
                let supported = try await backend.setChangeHandler(handler)
                guard enabled, supported, epoch == self.eventEpoch, !self.closed else { return }
                // Reconcile warm cached rows after hidden changes. A cold or
                // already refreshing list gets its snapshot after subscription.
                if !self.loading && !self.refreshing { self.activityChanged() }
            } catch {
                guard enabled, epoch == self.eventEpoch, !self.closed else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private func activityChanged() {
        guard presented, contextReady, !closed, page != .create else { return }
        activityDirty = true
        guard activityTask == nil else { return }
        let epoch = eventEpoch
        let key = cacheKey
        let token = generation
        activityTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if epoch == self.eventEpoch, token == self.generation {
                    self.activityTask = nil
                    // A new query/view owns its own snapshot, never this event.
                    self.activityDirty = false
                }
            }
            do {
                // One timer per burst, not recurring polling. Changes during a
                // request cause one follow-up, never cancel/restart that request.
                while self.activityDirty {
                    try await Task.sleep(for: .milliseconds(40))
                    if self.refreshing { await self.queryTask?.value }
                    try Task.checkCancellation()
                    guard self.presented, self.contextReady, !self.closed,
                          epoch == self.eventEpoch, token == self.generation,
                          key == self.cacheKey, self.page != .create else { return }
                    self.activityDirty = false
                    var params: [String: APIValue] = ["query": .text(key.query)]
                    let method: String
                    if key.view == .agents { method = "agents" }
                    else if key.page == .worktrees {
                        method = "worktrees.list"
                        if let repo = key.repo { params["repo"] = .text(repo) }
                    } else { method = "sessions" }
                    let result = try await self.request(method, params: params)
                    try Task.checkCancellation()
                    guard self.presented, epoch == self.eventEpoch,
                          token == self.generation, key == self.cacheKey else { return }
                    // Rows only. Do not replay target, form, popover or busy state.
                    self.items = self.orderedAgents(result.items ?? [], key: key)
                    if !self.items.contains(where: { $0.id == self.selectedID }) {
                        self.selectedID = self.items.first?.id
                    }
                    if !self.items.contains(where: { $0.id == self.scrollID }) { self.scrollID = nil }
                    if key.view == .sessions, key.page == .directories {
                        self.sessionHosts = result.hosts ?? []
                    }
                    self.cache[key] = CachedList(result: result, selectedID: self.selectedID,
                                                 scrollID: self.scrollID, target: self.target)
                    self.activeKey = key
                    self.displayedKey = key
                }
            } catch {
                // Keep a usable snapshot on refresh failure. A dead process is
                // recovered by the resident host on the next presentation.
            }
        }
    }

    private var cacheKey: CacheKey {
        if view == .agents || page == .directories {
            return CacheKey(view: view, page: .directories, repo: nil, query: query)
        }
        // Worktree pages keep their repository-scoped cache.
        return CacheKey(view: view, page: page, repo: repo, query: query)
    }

    /// "dirs" is the legacy alias for the unified Sessions launcher.
    private static func initialView(for options: LaunchOptions) -> ViewKind {
        options.mode == "agents" ? .agents : .sessions
    }

    /// A direct Agents/Sessions request must route from another visible view, not hide it.
    func shouldToggle(for options: LaunchOptions) -> Bool {
        self.options.matches(options)
            && (options.mode != "agents" || view == .agents)
            && (options.mode != "sessions" || view == .sessions)
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
        activityTask?.cancel(); activityTask = nil; activityDirty = false
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

    init(options: LaunchOptions, backend: any BackendClient, cacheTTL: TimeInterval = 30) {
        self.cacheTTL = cacheTTL
        self.options = options
        self.backend = backend
        self.view = Self.initialView(for: options)
        self.page = options.mode == "wt-create" ? .create : (options.mode == "wt" ? .worktrees : .directories)
        self.repo = options.repo
        self.loading = true
    }

    var selected: PickerItem? { items.first { $0.id == selectedID } }
    /// Resident recovery: did the shared backend connection die?
    var backendIsClosed: Bool { closed || ((backend as? ProcessBackend)?.isClosed ?? false) }
    var canOpen: Bool {
        guard contextReady, !busy, !loading, displayedKey == cacheKey else { return false }
        if view == .agents { return selected?.kind == "agent" }
        if page == .directories {
            // Launcher rows also need a target from their own origin's reply;
            // display-only cached rows across origins carry no targets.
            return !target.isEmpty && (selected?.kind == "session" || selected?.kind == "dir")
        }
        guard selected != nil else { return false }
        return !target.isEmpty
    }
    var canCreate: Bool { contextReady && !busy && !loading && !basePickerPresented && !targetPickerPresented && previewReady && validationError == nil && destination != nil && !branch.isEmpty && !base.isEmpty && !target.isEmpty && createdPath == nil }
    var canSubmitForm: Bool { contextReady && !backendIsClosed && !basePickerPresented && (canCreate || (!busy && createdPath != nil && !target.isEmpty)) }
    var heading: String {
        switch view {
        case .agents: return "Agents"
        case .sessions:
            switch page {
            case .directories: return "Sessions"
            case .worktrees: return "Worktrees"
            case .create: return "Create worktree"
            }
        }
    }

    func start() {
        guard !started, contextReady, !closed else { return }
        started = true
        scheduleQuery(immediate: true)
        loadTheme(after: queryTask)
    }

    // Fetch the active Rex theme from the backend and repaint. On failure
    // the current palette stays; RaptorApplication seeds it from the system
    // appearance before any picker opens.
    private func loadTheme(after listTask: Task<Void, Never>?) {
        guard !themeLoaded else { return }
        refreshTheme(after: listTask)
    }

    /// Global appearance refresh never gates cached rows or resets picker state.
    @discardableResult func refreshTheme(after listTask: Task<Void, Never>? = nil) -> Task<Void, Never>? {
        guard contextReady, !closed else { return nil }
        if let themeTask { return themeTask }
        let task = Task { [weak self] in
            // Never let theme discovery occupy the pipe before the initial list.
            await listTask?.value
            guard !Task.isCancelled else { return }
            let result = try? await self?.backend.request("theme", params: [:])
            guard let self else { return }
            defer { self.themeTask = nil }
            guard !self.closed, !Task.isCancelled else { return }
            if let payload = result?.theme, payload != self.activeTheme, PickerPalette.apply(payload) {
                self.activeTheme = payload
                self.themeRevision += 1
            }
            if !self.themeLoaded { self.themeLoaded = true }
        }
        themeTask = task
        return task
    }
    var showsPills: Bool { page != .create }


    /// Synchronous open boundary: reset origin state before the panel is shown.
    /// Same-origin warm lists remain usable; changed origins keep only
    /// display-only global directories. The returned token owns completion.
    @discardableResult
    func prepareReconfigure(_ options: LaunchOptions) -> Int {
        reconfigureGeneration += 1
        let token = reconfigureGeneration
        if createdPath != nil {
            // Keep the backend origin, repo, target and createParent together.
            // Reopening must neither cancel a mutation nor turn recovery into
            // another create (even when the incoming request is unrelated).
            warmReconfigure = token
            if !busy, !self.options.matches(options) {
                let warning = "Recover the created worktree in its original context, or discard recovery before opening another picker."
                if error?.hasPrefix(warning) != true {
                    error = warning + (error.map { " \($0)" } ?? "")
                }
            }
            return token
        }
        // Invalidate callbacks before any presentation/context state changes.
        eventEpoch += 1
        activityTask?.cancel(); activityTask = nil; activityDirty = false
        saveListPosition()
        agentOrder.removeAll()
        agentGroups.removeAll()
        sessionHosts = []
        let sameContext = self.options.session == options.session && self.options.block == options.block
            && self.options.client == options.client && self.options.title == options.title
            && self.options.demo == options.demo
        let launcher = CacheKey(view: .sessions, page: .directories, repo: nil, query: "")
        let agents = CacheKey(view: .agents, page: .directories, repo: nil, query: "")
        let warmAgents = options.mode == "agents" && cache[agents] != nil
        let cachedLauncher = cache[launcher]
        let warmLauncher = (options.mode == "dirs" || options.mode == "sessions")
            && !(cachedLauncher?.result.items ?? []).isEmpty
            && !(cachedLauncher?.target ?? "").isEmpty
            && cachedLauncher?.result.targets?.contains(cachedLauncher?.target ?? "") == true
        if sameContext, contextReady, !closed, !busy, warmLauncher || warmAgents {
            // The same origin needs no context RPC. Launcher opens also keep
            // any refresh already serving this key; Agents start a new order.
            warmReconfigure = token
            changingContext = true
            self.options = options
            view = Self.initialView(for: options); page = .directories; repo = options.repo
            // Every reopen starts fresh: filters clear everywhere and the
            // origin session (first row) becomes the selection once rows land.
            viewQueries.removeAll()
            query = ""
            selectedID = nil
            scrollID = nil
            // The cached launcher rows remember the previous selection; drop
            // it so the replay selects the origin session instead.
            for viewKind in ViewKind.allCases {
                let key = CacheKey(view: viewKind, page: .directories, repo: nil, query: "")
                cache[key]?.selectedID = nil
                cache[key]?.scrollID = nil
            }
            previewGeneration += 1
            previewTask?.cancel()
            suggestedBranch = nil
            branches = []; base = ""; resetBranchDefault()
            destination = nil; destinationRoot = nil; previewReady = false; validationError = nil
            createdPath = nil; splitMode = false; error = nil; notice = nil
            removalCandidate = nil
            basePickerPresented = false; targetPickerPresented = false
            changingContext = false
            // Agents take fresh newest-first order once per presentation.
            // Directory opens retain the existing no-RPC warm fast path.
            if presented { renewSubscription() }
            scheduleQuery(immediate: true, reuseFresh: !warmAgents)
            return token
        }
        warmReconfigure = nil
        if presented { renewSubscriptionForContextChange() }
        contextGeneration += 1
        contextReady = false
        changingContext = true
        generation += 1
        queryTask?.cancel()
        // Launcher rows stay as display-only globals across origins; their
        // targets belong to the previous origin and are stripped.
        cache = cache.filter { $0.key.view == .sessions && $0.key.page == .directories && $0.key.repo == nil }
            .mapValues { entry in
                CachedList(result: APIResult(items: entry.result.items), selectedID: entry.selectedID,
                           scrollID: entry.scrollID, target: "")
            }
        activeKey = nil
        displayedKey = nil
        refreshing = false
        previewGeneration += 1
        previewTask?.cancel(); operationTask?.cancel()
        busy = false
        items = []; selectedID = nil; scrollID = nil
        sessionHosts = []
        targets = []; target = ""
        suggestedBranch = nil
        branches = []; base = ""; resetBranchDefault()
        destination = nil; destinationRoot = nil; previewReady = false; validationError = nil
        viewQueries.removeAll()
        loading = true
        self.options = options
        closed = false
        view = Self.initialView(for: options)
        page = options.mode == "wt-create" ? .create : (options.mode == "wt" ? .worktrees : .directories)
        repo = options.repo
        createParent = .worktrees
        query = ""
        splitMode = false
        error = nil
        notice = nil
        createdPath = nil
        removalCandidate = nil
        basePickerPresented = false
        targetPickerPresented = false
        changingContext = false
        if page == .directories, let cached = cache[cacheKey] {
            activeKey = cacheKey
            displayedKey = cacheKey
            items = cached.result.items ?? []
            selectedID = cached.selectedID ?? items.first?.id
            scrollID = cached.scrollID
            // Targets belong to the new origin, not the cached directory rows.
            loading = false
        }
        refreshing = true
        return token
    }

    private func renewSubscriptionForContextChange() {
        // Unsubscribe before the context RPC; resubscribe after it succeeds.
        contextReady = false
        renewSubscription()
    }

    /// Failure leaves every action gated; cached rows remain display-only.
    func completeReconfigure(_ context: Int) async {
        guard context == reconfigureGeneration, !closed, warmReconfigure != context else { return }
        let options = self.options
        do {
            await subscriptionTask?.value
            guard context == reconfigureGeneration, !closed else { return }
            _ = try await backend.request("context", params: [
                "session": .text(options.session), "block": .text(options.block),
                "client": .text(options.client), "title": .text(options.title),
            ])
            try Task.checkCancellation()
            guard context == reconfigureGeneration, !closed else { return }
            contextReady = true
            if presented { renewSubscription() }
            started = true
            scheduleQuery(immediate: true)
            loadTheme(after: queryTask)
        } catch {
            guard context == reconfigureGeneration, !closed else { return }
            loading = false
            refreshing = false
            self.error = "Cannot set picker context. Close and reopen. \(error.localizedDescription)"
        }
    }

    func reconfigure(_ options: LaunchOptions) async {
        await completeReconfigure(prepareReconfigure(options))
    }

    func switchView(backward: Bool = false) {
        let views = ViewKind.allCases
        let index = views.firstIndex(of: view) ?? 0
        selectView(views[(index + (backward ? views.count - 1 : 1)) % views.count])
    }

    func selectView(_ desired: ViewKind) {
        guard contextReady, desired != view else { return }
        guard !busy, page != .create,
              removalCandidate == nil,
              !basePickerPresented, !targetPickerPresented else { return }
        saveListPosition()
        viewQueries[view] = query
        view = desired
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
        selectedID = items[number - 1].id
        choose()
    }

    func togglePin() {
        guard contextReady else { return }
        guard canOpen, view == .sessions, page == .directories, let selected, selected.kind == "dir" else { return }
        let path = selected.path
        perform {
            _ = try await self.request("pins.toggle", params: ["path": .text(path)])
            self.invalidateLists()
            self.scheduleQuery(immediate: true)
        }
    }

    /// Hide only. An issued mutation must finish in its original context.
    func dismiss() { setPresented(false); onDismiss?() }

    private func finishNavigation() {
        if keepsBackendWarmOnNavigation { dismiss() }
        else { close() }
    }

    func close() {
        guard !closed else { return }
        presented = false
        eventEpoch += 1
        activityTask?.cancel(); activityTask = nil; activityDirty = false
        closed = true
        // Successful jump/dispatch closes inside perform. Its context-bound
        // defer cannot clear busy after this generation changes.
        busy = false
        contextGeneration += 1
        queryTask?.cancel(); previewTask?.cancel(); operationTask?.cancel(); themeTask?.cancel()
        onAdvanceFormFocus = nil; onFocusSearch = nil
        backend.close()
        onClose?()
    }

    var queryDebounceMilliseconds: Int {
        view == .agents || page == .directories ? 0 : 140
    }

    private func scheduleQuery(immediate: Bool = false, reuseFresh: Bool = false, freshQuery: Bool = false) {
        guard !closed, !changingContext, contextReady else { return }
        saveListPosition()
        let key = cacheKey
        // A warm reopen must not cancel and requeue the same pipe request.
        if reuseFresh, refreshing, queryKey == key, activeKey == key { return }
        activityTask?.cancel(); activityTask = nil; activityDirty = false
        generation += 1
        let token = generation
        queryTask?.cancel()
        queryKey = nil
        let cached = page == .create ? nil : cache[key]
        // Same-context typing keeps the last snapshot on screen. Its display
        // key gates actions until rows matching the new query arrive.
        let retainRows = freshQuery && displayedKey != nil
        if let cached {
            activeKey = key
            displayedKey = key
            items = orderedAgents(cached.result.items ?? [], key: key, capture: !freshQuery)
            selectedID = cached.selectedID ?? items.first?.id
            scrollID = cached.scrollID
        } else if !retainRows {
            activeKey = nil
            displayedKey = nil
            items = []; selectedID = nil; scrollID = nil
        }
        if view == .sessions, page == .directories, !retainRows || cached != nil {
            sessionHosts = cached?.result.hosts ?? []
        }
        if let cached {
            targets = cached.result.targets ?? []
            target = cached.target
            if view == .sessions, page == .worktrees {
                suggestedBranch = cached.result.suggestedBranch
                destinationRoot = cached.result.destinationRoot
                branches = cached.result.branches ?? []
                base = cached.result.baseBranch ?? branches.first ?? ""
            }
        }
        loading = cached == nil && !retainRows
        if reuseFresh, let cached, Date().timeIntervalSince(cached.refreshedAt) < cacheTTL {
            refreshing = false
            return
        }
        queryKey = key
        refreshing = true
        splitMode = false
        error = nil
        let currentPage = page
        let currentView = view
        let currentQuery = query
        let currentRepo = repo
        let debounce = immediate ? 0 : queryDebounceMilliseconds
        queryTask = Task { [weak self] in
            guard let self else { return }
            do {
                if debounce > 0 { try await Task.sleep(for: .milliseconds(debounce)) }
                await self.subscriptionTask?.value
                try Task.checkCancellation()
                var params: [String: APIValue] = ["query": .text(currentQuery)]
                let method: String
                if currentView == .agents {
                    method = "agents"
                } else if currentPage == .worktrees || currentPage == .create {
                    method = "worktrees.list"
                    if let currentRepo { params["repo"] = .text(currentRepo) }
                } else {
                    method = "sessions"
                }
                let result = try await self.request(method, params: params)
                guard !Task.isCancelled, token == self.generation, !self.closed else { return }
                if currentView == .sessions, currentPage == .worktrees || currentPage == .create, result.needsRepo == true {
                    // No repository context: fall back to the launcher, where
                    // ⌃T on a directory row opens its worktrees.
                    self.repo = nil
                    self.navigate(.directories)
                    return
                }
                let previous = self.selectedID
                self.items = currentPage == .create ? [] : self.orderedAgents(result.items ?? [], key: key)
                self.selectedID = self.items.contains { $0.id == previous } ? previous : self.items.first?.id
                if currentView == .sessions, case .directories = currentPage {
                    self.sessionHosts = result.hosts ?? []
                }
                if let targets = result.targets { self.targets = targets }
                if !self.targets.contains(self.target) { self.target = result.target ?? self.targets.first ?? "" }
                if currentView == .sessions, currentPage == .worktrees || currentPage == .create {
                    self.repo = result.repo ?? currentRepo
                    self.destinationRoot = result.destinationRoot
                    self.branches = result.branches ?? []
                    self.suggestedBranch = result.suggestedBranch
                    if currentPage != .create || self.base.isEmpty {
                        self.base = result.baseBranch ?? self.branches.first ?? ""
                    }
                    if currentPage == .create { self.applyBranchDefault() }
                }
                if !self.items.contains(where: { $0.id == self.scrollID }) { self.scrollID = nil }
                self.loading = false
                self.refreshing = false
                if currentPage != .create {
                    let resolvedKey = self.cacheKey
                    self.activeKey = resolvedKey
                    self.displayedKey = resolvedKey
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
        if newPage == .create {
            base = ""; branches = []; createdPath = nil
            resetBranchDefault()
        }
        page = newPage
        if newPage == .create { applyBranchDefault() }
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
        guard !busy, !targets.isEmpty else { return }
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

    /// One verb, select-or-create, mirroring sesh: a session row switches to
    /// it; a directory row starts a session when the target is Session, else
    /// opens the path with the chosen target.
    /// The display label of the local host; rows without one are local.
    private static let rexLocalHostDefault = "This Mac"

    func choose() {
        guard contextReady else { return }
        guard canOpen else { return }
        guard let selected else { return }
        if view == .agents {
            guard canOpen else { return }
            jumpAgent(selected)
        } else if page == .directories {
            if selected.kind == "session" {
                jumpSession(selected)
            } else if selected.kind == "dir" {
                // Remote directories always launch a session on their host —
                // the open target only ever applies to local rows (TUI parity).
                // is_local is authoritative; absent decodes as local.
                let local = selected.isLocal ?? true
                if !local || target == "session" {
                    createSession(in: selected.host ?? Self.rexLocalHostDefault, directory: selected.path)
                } else if !target.isEmpty {
                    dispatch(path: selected.path, target: target)
                }
            }
        } else if canOpen {
            dispatch(path: selected.path, target: target)
        }
    }

    /// Enter on a session row: Rex switches to that session, then the picker closes.
    private func jumpSession(_ entry: PickerItem) {
        guard entry.kind == "session" else { return }
        perform {
            _ = try await self.request("sessions.jump", params: [
                "kind": .text("session"),
                "session_id": .text(entry.sessionID ?? entry.path),
                "host": .text(entry.host ?? ""),
            ])
            if self.options.demo {
                self.notice = "Demo only: jumped to \(entry.label ?? entry.path). No Rex call."
            } else { self.finishNavigation() }
        }
    }

    private func createSession(in host: String, directory path: String) {
        perform {
            _ = try await self.request("sessions.create", params: ["host": .text(host), "dir": .text(path)])
            if self.options.demo {
                self.notice = "Demo only: created a session on \(host) in \(PathDisplay.abbreviate(path, home: "/Users/demo")). No Rex call."
            } else { self.finishNavigation() }
        }
    }

    private func jumpAgent(_ entry: PickerItem) {
        guard let session = entry.sessionID, let window = entry.windowID, let block = entry.blockID else { return }
        perform {
            _ = try await self.request("agents.jump", params: [
                "session_id": .text(session), "window_id": .text(window), "block_id": .text(block),
            ])
            if self.options.demo {
                self.notice = "Demo only: jumped to \(entry.label ?? entry.path). No Rex call."
            } else { self.finishNavigation() }
        }
    }

    func showWorktrees() {
        guard contextReady else { return }
        guard canOpen, view == .sessions, page == .directories,
              let selected, selected.kind == "dir" else { return }
        repo = selected.path
        navigate(.worktrees)
    }

    func beginCreate() {
        guard page == .worktrees, contextReady else { return }
        guard !busy, !loading, repo != nil else { return }
        createParent = .worktrees
        saveListPosition()
        activityTask?.cancel(); activityTask = nil; activityDirty = false
        generation += 1
        queryTask?.cancel()
        refreshing = false
        activeKey = nil
        page = .create
        splitMode = false
        error = nil; notice = nil; createdPath = nil
        items = []; selectedID = nil; scrollID = nil
        resetBranchDefault()
        applyBranchDefault()
        schedulePreview()
    }

    /// Forget only the recovery UI, never remove the created worktree.
    /// Disable actions until the next request installs its own context.
    func discardCreatedRecovery() {
        guard !busy, createdPath != nil else { return }
        createdPath = nil
        previewReady = false
        destination = nil
        error = nil
        notice = nil
        contextReady = false
        dismiss()
    }

    func escape() {
        if busy || !contextReady || (createdPath != nil && notice == nil) { dismiss(); return }
        // Demo dispatch succeeded and stays visible only to show its notice.
        if createdPath != nil { createdPath = nil }
        guard removalCandidate == nil else { return }
        if basePickerPresented { basePickerPresented = false; return }
        if targetPickerPresented { targetPickerPresented = false; return }
        if splitMode { splitMode = false; return }
        if page == .directories {
            dismiss()
            return
        }
        if page == .create {
            if options.mode == "wt-create" { dismiss() } else { navigate(createParent) }
        } else if !query.isEmpty {
            query = ""
        } else if page == .worktrees {
            navigate(.directories)
        } else { dismiss() }
    }

    func split(_ direction: String) {
        guard view == .sessions, splitMode, canOpen, let selected, selected.kind != "session" else { return }
        splitMode = false
        dispatch(path: selected.path, target: direction)
    }

    func toggleSplit() {
        guard view == .sessions, canOpen, page == .directories || page == .worktrees else { return }
        if page == .directories, selected?.kind != "dir" { return }
        splitMode.toggle()
    }

    // Record even an explicit empty edit before metadata arrives.
    func editBranch(_ value: String) {
        branchWasEdited = true
        branch = value
    }

    private func resetBranchDefault() {
        settingBranchDefault = true
        branch = ""
        settingBranchDefault = false
        branchWasEdited = false
        branchDefaultApplied = false
    }

    private func applyBranchDefault() {
        guard !branchWasEdited, !branchDefaultApplied, branch.isEmpty,
              let suggestedBranch, !suggestedBranch.isEmpty else { return }
        branchDefaultApplied = true
        settingBranchDefault = true
        branch = suggestedBranch
        settingBranchDefault = false
    }

    // Never queue Enter for a pending preview.
    func submitBranch() {
        guard page == .create, canSubmitForm else { return }
        create()
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
        guard canOpen, page == .worktrees, let selected, selected.isMain == false else { return }
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

    /// The Sessions counterpart of askRemove: close a remote or local session.
    func askCloseSession() {
        guard contextReady else { return }
        guard canOpen, view == .sessions, page == .directories,
              let selected, selected.kind == "session" else { return }
        removalCandidate = selected
    }

    func confirmCloseSession(_ candidate: PickerItem) {
        guard contextReady else { return }
        guard view == .sessions, page == .directories, !busy, candidate.kind == "session" else { return }
        removalCandidate = nil
        perform {
            _ = try await self.request("sessions.close", params: [
                "kind": .text("session"),
                "session_id": .text(candidate.sessionID ?? candidate.path),
                "host": .text(candidate.host ?? ""),
            ])
            self.invalidateLists()
            self.scheduleQuery(immediate: true)
        }
    }

    func openCreated() {
        guard contextReady else { return }
        guard !busy, !backendIsClosed, let path = createdPath, !target.isEmpty else { return }
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
        } else {
            createdPath = nil // Dispatch succeeded: no recovery remains to preserve.
            finishNavigation()
        }
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
