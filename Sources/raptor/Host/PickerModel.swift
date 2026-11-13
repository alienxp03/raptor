import SwiftUI
import AppKit

@MainActor
final class PickerModel: ObservableObject {
    enum Page: Hashable { case directories, worktrees, create, pr }
    var isForm: Bool { page == .create || page == .pr }
    @Published var shortcutsPresented = false
    @Published var shortcutsQuery = "" {
        didSet {
            if shortcutsQuery != oldValue { selectedShortcutID = shortcuts.first?.id }
        }
    }
    @Published var selectedShortcutID: String?

    func moveShortcut(_ delta: Int) {
        let entries = shortcuts
        guard !entries.isEmpty else { selectedShortcutID = nil; return }
        let index = entries.firstIndex { $0.id == selectedShortcutID } ?? 0
        selectedShortcutID = entries[min(max(index + delta, 0), entries.count - 1)].id
    }

    struct Shortcut: Identifiable {
        let title: String
        let keys: String
        let group: String
        let keywords: String
        var id: String { title }
    }

    var shortcuts: [Shortcut] {
        var entries: [Shortcut] = [
            .init(title: "Show shortcuts", keys: "⌘/", group: "General", keywords: "help command cmd / question ? outside text fields"),
            .init(title: "Go back or dismiss", keys: "Esc", group: "General", keywords: "escape cancel close"),
            .init(title: "Hide picker", keys: "⌘Q", group: "General", keywords: "command cmd quit"),
            .init(title: "Move down", keys: "⌃J", group: "Navigation", keywords: "arrow down ctrl control j next"),
            .init(title: "Move up", keys: "⌃K", group: "Navigation", keywords: "arrow up ctrl control k previous"),
            .init(title: "Open selected result", keys: "↵", group: "Navigation", keywords: "enter return choose"),
            .init(title: "Open numbered result", keys: "⌘1–9", group: "Navigation", keywords: "command cmd number jump"),
            .init(title: "Show sessions", keys: "⇧⌘S", group: "Sessions", keywords: "shift command cmd s view"),
            .init(title: "Rename session", keys: "⌃R", group: "Sessions", keywords: "ctrl control r name"),
            .init(title: "Close session", keys: "⌃X", group: "Sessions", keywords: "ctrl control x stop"),
            .init(title: "Review worktrees for deletion", keys: "⇧⌘X", group: "Sessions", keywords: "shift command cmd x remove delete branch repo"),
            .init(title: "Pin or unpin row", keys: "⇧⌘P", group: "Actions", keywords: "shift command cmd p session directory favourite"),
            .init(title: "Checkout pull request", keys: "⇧⌘C", group: "Actions", keywords: "shift command cmd c pr github clone checkout"),
            .init(title: "Next open target", keys: "⌃O", group: "Actions", keywords: "ctrl control o tab window destination"),
            .init(title: "Previous open target", keys: "⌃⇧O", group: "Actions", keywords: "ctrl control shift o tab window destination"),
            .init(title: "Toggle split mode", keys: "⌃P", group: "Actions", keywords: "ctrl control p pane cancel")
        ]
        if splitMode {
            entries += [
                .init(title: "Split below", keys: "j  ↓", group: "Split", keywords: "pane down arrow"),
                .init(title: "Split right", keys: "l  →", group: "Split", keywords: "pane arrow")
            ]
        }
        if isForm {
            entries += [
                .init(title: "Show agent fields", keys: "⌃⌥O", group: "Forms", keywords: "ctrl control option o agent model reasoning worktree pi codex"),
                .init(title: "Next field", keys: "Tab", group: "Forms", keywords: "focus editing"),
                .init(title: "Previous field", keys: "⇧Tab", group: "Forms", keywords: "shift focus editing"),
                .init(title: "Submit form", keys: "⌘↵", group: "Forms", keywords: "command cmd enter return create worktree pull request")
            ]
        }
        if sessionDeletion != nil {
            entries.append(.init(title: "Offer force delete", keys: "⇧⌘X", group: "Confirmation", keywords: "shift command cmd x force remove"))
        }
        if renameCandidate != nil || hasSessionAction {
            entries.append(.init(title: "Confirm rename or session action", keys: "↵", group: "Confirmation", keywords: "enter return close delete"))
        }
        let terms = shortcutsQuery.lowercased().split(whereSeparator: { $0.isWhitespace })
        return entries.filter { entry in
            let text = "\(entry.title) \(entry.keys) \(entry.group) \(entry.keywords)".lowercased()
            let words = text.split { !$0.isLetter && !$0.isNumber }
            return terms.allSatisfy { term in
                term.count == 1 && term.first?.isLetter == true ? words.contains(term) : text.contains(term)
            }
        }
    }

    func toggleShortcuts() {
        guard !busy, renameCandidate == nil, !hasSessionAction, removalCandidate == nil,
              !basePickerPresented, !targetPickerPresented, !prCommitConfirmationPresented else { return }
        shortcutsQuery = ""
        selectedShortcutID = shortcuts.first?.id
        shortcutsPresented.toggle()
    }
    @Published var prInput = "" {
        didSet {
            if prInput != oldValue {
                if let canonical = Self.normalizedPullRequestURL(prInput), canonical != prInput {
                    prInput = canonical
                }
                resolvePullRequest()
            }
        }
    }
    @Published private(set) var pullRequest: APIResult?
    @Published private(set) var prStage: String?
    @Published var prCommitConfirmationPresented = false
    private var prCheckoutCommit = false
    private var prCommitConfirmationInput: String?
    private var prGeneration = 0
    private var prTask: Task<Void, Never>?
    private let pullRequestClipboard: () -> String?
    private var prReturn: (page: Page, view: ViewKind, repo: String?, query: String, selected: String?, scroll: String?, targets: [String], target: String, items: [PickerItem])?
    enum ViewKind: Hashable, CaseIterable { case sessions, agents }
    private(set) var options: LaunchOptions
    private var backend: any BackendClient
    @Published var view: ViewKind = .sessions
    @Published var page: Page
    @Published var query = "" {
        didSet {
            if query != oldValue && !isForm && !changingContext {
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
    @Published private(set) var listPresentation = 0
    @Published private(set) var refreshing = false
    @Published var targets: [String] = []
    @Published var target = ""
    // Agent launch controls (worktree form). Collapsed until ⌃⇧O or the
    // summary row opens them; selections ride the create/dispatch request.
    @Published var agentControlsShown = false
    @Published private(set) var agentChoices: [String] = ["pi", "codex"]
    @Published private(set) var agent = "none"
    @Published private(set) var agentProvider = ""
    @Published private(set) var agentModel = ""
    @Published private(set) var agentReasoning = "" // "" or "default": tool default
    @Published private(set) var agentCatalogs: [String: [AgentModelPayload]] = [:]
    @Published private(set) var agentCatalogLoading = false
    @Published private(set) var agentCatalogWarning: String?
    private var agentCatalogsRequested = Set<String>()
    private var agentDefaultsApplied = false
    private var createdLaunch: (agent: String, provider: String, model: String, reasoning: String)?
    @Published var repo: String? {
        didSet {
            if repo != oldValue {
                suggestedBranch = nil
                if page == .pr { resolvePullRequest() }
            }
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
    struct SessionDeletion {
        enum Phase { case loading, review, preparing, confirm, deleting, failed, forceOffered, forceConfirm }
        let id = UUID()
        let candidate: PickerItem
        var phase: Phase = .loading
        var plan: APIResult?
        var error: String?
        var selectedPaths: Set<String> = []
        var deletedPaths: Set<String> = []
        var closeSessionConfirmed = false
        var checkingPath: String?
        var checkStartedAt: Date?
        var preparationSelection: Set<String>?
    }
    @Published private(set) var sessionDeletion: SessionDeletion?
    private var deletionPreviewTask: Task<Void, Never>?
    private var pendingSessionRemoval: (context: Int, item: PickerItem)?
    var sessionCloseCandidate: PickerItem? {
        view == .sessions && page == .directories ? removalCandidate : nil
    }
    var hasSessionAction: Bool { sessionCloseCandidate != nil || sessionDeletion != nil }
    @Published var renameCandidate: PickerItem?
    @Published var renameLabel = ""
    private var pendingRename: (context: Int, item: PickerItem, label: String)?
    @Published var basePickerPresented = false
    @Published var agentPickerPresented = false
    @Published var agentModelPickerPresented = false
    @Published var agentReasoningPickerPresented = false
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
    private var pinning = false
    // Only a confirmed manual pin change may animate the list or its glyph.
    @Published private(set) var pinAnimationID: String?
    @Published private(set) var pinAnimationRevision = 0
    @Published private(set) var pinChangeRevision = 0
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
    private struct FormContext: Hashable {
        let session: String
        let block: String
        let client: String
        let title: String
        let repo: String?
    }
    private var formMetadata: [FormContext: APIResult] = [:]
    // Cached resolved repos are display-only until the invocation's original
    // hint is resolved again: the pane may have changed directory.
    private var formRequestRepo: String?
    private var activeKey: CacheKey?
    private var displayedKey: CacheKey?
    // Per presentation and query. Cache stores backend order for the next open.
    private var agentOrder: [CacheKey: [String]] = [:]

    private var agentGroups: [CacheKey: [String: AgentGroup]] = [:]

    private func orderedAgents(_ rows: [PickerItem], key: CacheKey, capture: Bool = true) -> [PickerItem] {
        let visibleRows = rows.filter { row in
            guard let pendingSessionRemoval, pendingSessionRemoval.context == contextGeneration else { return true }
            return row.id != pendingSessionRemoval.item.id || row.host != pendingSessionRemoval.item.host
        }
        let rows: [PickerItem] = if let pendingRename, pendingRename.context == contextGeneration {
            renamedRows(visibleRows, candidate: pendingRename.item, label: pendingRename.label, sessionLabel: pendingRename.label)
        } else { visibleRows }
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
    private var reopenedSelection: (generation: Int, id: String?)?
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
        if !visible {
            // Rex can acknowledge a result while this resident picker is hidden.
            // Keep rows for instant reopen, but revalidate their unread flags.
            for key in cache.keys where cache[key]?.result.items?.contains(where: { $0.unreadDone == true }) == true {
                cache[key]?.refreshedAt = .distantPast
            }
        }
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

    /// Receipt writes are local client changes, not Rex server status events.
    /// Re-read the backend's cached rows; never scan or mark a result as seen here.
    func readReceiptsChanged() {
        guard !closed else { return }
        for key in cache.keys { cache[key]?.refreshedAt = .distantPast }
        guard presented, contextReady else { return }
        activityChanged()
    }

    private func activityChanged() {
        guard presented, contextReady, !closed, !isForm, !pinning, renameCandidate == nil,
              pendingRename?.context != contextGeneration, pendingSessionRemoval?.context != contextGeneration,
              !hasSessionAction, Self.pullRequestLink(query) == nil else { return }
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
                          key == self.cacheKey, !self.isForm else { return }
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
                        self.selectedID = self.preferredSelection(in: result, query: key.query)
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

    /// Legacy agents/wt modes are normalized by LaunchOptions.
    private static func initialView(for options: LaunchOptions) -> ViewKind { .sessions }

    func shouldToggle(for options: LaunchOptions) -> Bool {
        self.options.matches(options) && (options.mode != "sessions" || view == .sessions)
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
        formMetadata.removeAll()
        activeKey = nil
        refreshing = false
    }

    /// A completed mutation already knows its resource IDs. Publish its backend
    /// snapshot before hiding, rather than replaying a pre-creation cached list.
    private func acceptLauncherMutation(_ result: APIResult) {
        let key = CacheKey(view: .sessions, page: .directories, repo: nil, query: "")
        let prior = cache[key]?.result
        invalidateLists()
        guard let rows = result.launcherItems, !rows.isEmpty else { return }
        let snapshot = APIResult(items: rows, hosts: prior?.hosts, targets: prior?.targets, target: prior?.target)
        // Display immediately, but revalidate origin-bound targets on reopening.
        // The backend's write-through cache makes that a fast in-memory read.
        cache[key] = CachedList(result: snapshot, refreshedAt: .distantPast,
                                selectedID: nil, scrollID: nil, target: "")
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

    init(options: LaunchOptions, backend: any BackendClient, cacheTTL: TimeInterval = 30,
         pullRequestClipboard: @escaping () -> String? = { nil }) {
        self.pullRequestClipboard = pullRequestClipboard
        self.cacheTTL = cacheTTL
        self.options = options
        self.backend = backend
        self.view = Self.initialView(for: options)
        self.page = options.mode == "pr" ? .pr : (options.mode == "wt-create" ? .create : .directories)
        self.repo = options.repo
        self.formRequestRepo = options.repo
        self.loading = true
    }

    /// Focus belongs to the native app, not the panel's current Rex context.
    /// No list/cache mutation: the backend captures MRU on presentation.
    func observeRexFocus(_ observation: RexFocusObservation) async -> Bool {
        guard !backendIsClosed, !options.demo, !Task.isCancelled else { return false }
        do {
            _ = try await backend.request("sessions.visit", params: observation.params)
            return !backendIsClosed
        } catch {
            // A closed/crashed backend is recovered on the next open. Never
            // surface private preference failures in the picker.
            return false
        }
    }

    var selected: PickerItem? { items.first { $0.id == selectedID } }
    /// Resident recovery: did the shared backend connection die?
    var backendIsClosed: Bool { closed || ((backend as? ProcessBackend)?.isClosed ?? false) }
    var canOpen: Bool {
        guard renameCandidate == nil, !hasSessionAction else { return false }
        if selected?.kind == "pr", !isForm {
            return contextReady && !busy && !loading && Self.pullRequestLink(query) != nil
                && selected?.path == query.trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
            case .pr: return "Checkout pull request"
            }
        }
    }

    func start() {
        guard !started, contextReady, !closed else { return }
        started = true
        prefillPullRequestFromClipboard()
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
    var showsPills: Bool { false }

    /// Current-session selection also applies to cached and legacy replies.
    /// Search results retain their backend rank.
    static func preferredSelection(in result: APIResult, query: String = "", currentSession: String = "") -> String? {
        if query.isEmpty {
            if !currentSession.isEmpty {
                // Cached active flags belong to the previous presentation.
                if let current = result.items?.first(where: {
                    $0.kind == "session" && ($0.sessionID == currentSession || $0.path == currentSession)
                }) { return current.id }
            } else if let current = result.items?.first(where: { $0.kind == "session" && $0.active == true }) {
                return current.id
            }
        }
        return result.items?.first?.id
    }

    private func preferredSelection(in result: APIResult, query: String = "") -> String? {
        Self.preferredSelection(in: result, query: query, currentSession: options.session)
    }


    /// Synchronous open boundary: reset origin state before the panel is shown.
    /// Same-origin warm lists remain usable; changed origins keep only
    /// display-only global directories. The returned token owns completion.
    @discardableResult
    func prepareReconfigure(_ options: LaunchOptions) -> Int {
        reconfigureGeneration += 1
        let token = reconfigureGeneration
        if createdPath != nil || (page == .pr && busy) || (busy && (sessionDeletion != nil || pendingSessionRemoval != nil)) {
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
        // A resident view keeps its physical scroll offset even when scrollID
        // becomes nil. Recreate the list viewport for each normal open.
        listPresentation += 1
        // Invalidate callbacks before any presentation/context state changes.
        eventEpoch += 1
        activityTask?.cancel(); activityTask = nil; activityDirty = false
        saveListPosition()
        agentOrder.removeAll()
        agentGroups.removeAll()
        sessionHosts = []
        let previousTargets = targets
        let previousTarget = target
        let sameContext = self.options.session == options.session && self.options.block == options.block
            && self.options.client == options.client && self.options.title == options.title
            && self.options.demo == options.demo
        let launcher = CacheKey(view: .sessions, page: .directories, repo: nil, query: "")
        let cachedLauncher = cache[launcher]
        let warmLauncher = (options.mode == "dirs" || options.mode == "sessions")
            && !(cachedLauncher?.result.items ?? []).isEmpty
            && !(cachedLauncher?.target ?? "").isEmpty
            && cachedLauncher?.result.targets?.contains(cachedLauncher?.target ?? "") == true
        if sameContext, contextReady, !closed, !busy, warmLauncher {
            // The same origin needs no context RPC. Keep an existing refresh.
            warmReconfigure = token
            changingContext = true
            self.options = options
            view = Self.initialView(for: options); page = .directories; repo = options.repo
            // Every reopen clears filters and selects the current session.
            viewQueries.removeAll()
            query = ""
            selectedID = nil
            scrollID = nil
            // Discard manual selection before replaying the preferred default.
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
            cancelRenameSession()
            cancelDeleteSession()
            basePickerPresented = false; targetPickerPresented = false
            changingContext = false
            // Launcher opens retain the existing no-RPC warm fast path.
            if presented { renewSubscription() }
            scheduleQuery(immediate: true, reuseFresh: true, freshQuery: true)
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
                CachedList(result: APIResult(items: entry.result.items), selectedID: nil,
                           scrollID: nil, target: "")
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
        page = options.mode == "pr" ? .pr : (options.mode == "wt-create" ? .create : .directories)
        prGeneration += 1; prTask?.cancel()
        pullRequest = nil; prInput = ""; prStage = nil; prReturn = nil
        prCommitConfirmationPresented = false; prCheckoutCommit = false
        repo = options.repo
        formRequestRepo = options.repo
        if page == .create {
            if sameContext { targets = previousTargets; target = previousTarget }
            agentControlsShown = false
            agentDefaultsApplied = false
            agentCatalogWarning = nil
            createdLaunch = nil
            restoreFormMetadata()
        }
        createParent = .worktrees
        query = ""
        splitMode = false
        error = nil
        notice = nil
        createdPath = nil
        removalCandidate = nil
        cancelRenameSession()
        cancelDeleteSession()
        basePickerPresented = false
        targetPickerPresented = false
        changingContext = false
        if page == .directories, let cached = cache[cacheKey] {
            activeKey = cacheKey
            displayedKey = cacheKey
            items = cached.result.items ?? []
            selectedID = preferredSelection(in: cached.result, query: query)
            scrollID = nil
            // Targets belong to the new origin, not the cached directory rows.
            loading = false
        }
        prefillPullRequestFromClipboard()
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
            scheduleQuery(immediate: true, freshQuery: page == .directories)
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
        guard !busy, !isForm,
              removalCandidate == nil, renameCandidate == nil, sessionDeletion == nil,
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
        guard number >= 1, number <= items.count, !busy, !loading, renameCandidate == nil, !hasSessionAction else { return }
        selectedID = items[number - 1].id
        choose()
    }

    var canPin: Bool {
        guard canOpen, view == .sessions, page == .directories, !splitMode,
              !basePickerPresented, !targetPickerPresented, !prCommitConfirmationPresented,
              removalCandidate == nil, let selected else { return false }
        if selected.kind == "session" { return selected.sessionID?.isEmpty == false && selected.host?.isEmpty == false }
        return selected.kind == "dir" && selected.isLocal != false
    }

    func togglePin() {
        guard canPin, let selected else { return }
        let params: [String: APIValue]
        if selected.kind == "session", let sessionID = selected.sessionID, let host = selected.host {
            params = ["session_id": .text(sessionID), "host": .text(host)]
        } else {
            params = ["path": .text(selected.path)]
        }
        let key = cacheKey
        perform {
            self.pinning = true
            self.invalidateLists()
            self.cacheSessionSnapshot()
            let token = self.generation
            defer { self.pinning = false }
            // Keep the old rows mounted until the backend supplies the new order.
            let pin = try await self.request("pins.toggle", params: params)
            guard key == self.cacheKey, token == self.generation else { return }
            self.cache[key]?.refreshedAt = .distantPast
            self.refreshing = true
            defer { if token == self.generation { self.refreshing = false } }
            let result: APIResult
            do {
                result = try await self.request("sessions", params: ["query": .text(key.query)])
            } catch {
                guard key == self.cacheKey, token == self.generation else { throw error }
                // The mutation is durable even if its subsequent list read fails.
                // Publish its confirmed flag, but leave ordering to the backend.
                if let pinned = pin.pinned, let index = self.items.firstIndex(where: { $0.id == selected.id }) {
                    self.items[index].isPinned = pinned
                    // The toggle response confirms membership, not its newly
                    // allocated shortcut slot. Never display an old assignment.
                    self.items[index].pinSlot = nil
                    self.cacheSessionSnapshot()
                    self.cache[key]?.refreshedAt = .distantPast
                }
                // Reconcile with one read-only refresh; never replay the toggle.
                self.pinning = false
                self.activityChanged()
                throw APIError.message("Pin saved, but refreshing failed. \(error.localizedDescription)")
            }
            guard key == self.cacheKey, token == self.generation else { return }
            let rows = result.items ?? []
            let animate = self.presented && PickerStyle.animatesPinChanges(
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                previous: self.items, updated: rows)
            var transaction = Transaction(animation: animate ? .easeInOut(duration: PickerStyle.pinReorderDuration) : nil)
            transaction[PinChangeTransactionKey.self] = animate
            withTransaction(transaction) {
                self.pinAnimationID = animate ? selected.id : nil
                if animate { self.pinAnimationRevision += 1 }
                self.pinChangeRevision += 1
                self.items = rows
            }
            // Follow the same row, never the row now occupying its old index.
            self.selectedID = rows.contains { $0.id == selected.id } ? selected.id
                : self.preferredSelection(in: result, query: key.query)
            if !rows.contains(where: { $0.id == self.scrollID }) { self.scrollID = nil }
            self.sessionHosts = result.hosts ?? []
            self.displayedKey = key
            self.cacheSessionSnapshot()
        }
    }

    /// Outside clicks cancel transient UI, not any operation already issued.
    func dismissForOutsideClick() {
        basePickerPresented = false
        targetPickerPresented = false
        cancelPullRequestCommitCheckout()
        removalCandidate = nil
        cancelRenameSession()
        if !busy { cancelDeleteSession() }
        dismiss()
    }

    /// Hide only. An issued mutation must finish in its original context.
    func dismiss() { shortcutsPresented = false; setPresented(false); onDismiss?() }

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
        deletionPreviewTask?.cancel()
        prGeneration += 1; prTask?.cancel()
        onAdvanceFormFocus = nil; onFocusSearch = nil
        backend.close()
        onClose?()
    }

    var queryDebounceMilliseconds: Int {
        view == .agents || page == .directories ? 0 : 140
    }

    private func scheduleQuery(immediate: Bool = false, reuseFresh: Bool = false, freshQuery: Bool = false) {
        guard !closed, !changingContext, contextReady else { return }
        if page == .pr {
            targets = ["session", "tab"]; target = "session"
            loading = false; refreshing = false
            resolvePullRequest()
            return
        }
        if let link = Self.pullRequestLink(query) {
            generation += 1; queryTask?.cancel()
            activityTask?.cancel(); activityTask = nil; activityDirty = false
            let item = PickerItem(path: query.trimmingCharacters(in: .whitespacesAndNewlines), label: "Open PR #\(link.number) — \(link.repo)", kind: "pr")
            items = [item]; selectedID = item.id; scrollID = nil
            loading = false; refreshing = false; error = nil
            return
        }
        saveListPosition()
        let key = cacheKey
        // A warm reopen must not cancel and requeue the same pipe request.
        if reuseFresh, refreshing, queryKey == key, activeKey == key {
            selectedID = preferredSelection(in: cache[key]?.result ?? APIResult(items: items), query: query)
            reopenedSelection = (generation, selectedID)
            return
        }
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
            selectedID = freshQuery ? preferredSelection(in: cached.result, query: query)
                : (cached.selectedID ?? preferredSelection(in: cached.result, query: query))
            scrollID = freshQuery ? nil : cached.scrollID
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
        let currentRepo = currentPage == .create ? formRequestRepo : repo
        let initialBase = base
        let initialSelection = selectedID
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
                    method = currentPage == .create ? "worktrees.form" : "worktrees.list"
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
                let reopenedDefault = self.reopenedSelection.map { $0.generation == token && $0.id == previous } ?? false
                let preserve = !reopenedDefault && !(freshQuery && previous == initialSelection)
                    && self.items.contains { $0.id == previous }
                self.reopenedSelection = nil
                self.selectedID = preserve ? previous : self.preferredSelection(in: result, query: currentQuery)
                if currentView == .sessions, case .directories = currentPage {
                    self.sessionHosts = result.hosts ?? []
                }
                if let targets = result.targets { self.targets = targets }
                if !self.targets.contains(self.target) { self.target = result.target ?? self.targets.first ?? "" }
                if currentView == .sessions, currentPage == .worktrees || currentPage == .create {
                    if currentPage == .create, let resolved = result.repo, let displayed = self.repo, resolved != displayed {
                        self.base = ""
                        if !self.branchWasEdited { self.resetBranchDefault() }
                    }
                    self.repo = result.repo ?? currentRepo
                    self.destinationRoot = result.destinationRoot
                    self.branches = result.branches ?? []
                    self.suggestedBranch = result.suggestedBranch
                    if currentPage != .create || self.base.isEmpty || self.base == initialBase {
                        self.base = result.baseBranch ?? self.branches.first ?? ""
                    }
                    if currentPage == .create {
                        self.applyBranchDefault()
                        self.applyAgentDefaults(result)
                    }
                    self.rememberFormMetadata(result, requestedRepo: currentRepo)
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
                if currentPage == .create { self.schedulePreview(immediate: true) }
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
        guard !loading, !busy, !items.isEmpty, renameCandidate == nil, !hasSessionAction else { return }
        let index = items.firstIndex { $0.id == selectedID } ?? 0
        selectedID = items[min(max(index + delta, 0), items.count - 1)].id
        // The view reveals selection with minimal scrolling. scrollID tracks
        // the viewport, not the keyboard selection.
    }

    func cycleTarget(backward: Bool) {
        guard contextReady else { return }
        guard !busy, !targets.isEmpty, renameCandidate == nil, !hasSessionAction else { return }
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
        if selected.kind == "pr" { beginPullRequest(input: selected.path); return }
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
            let result = try await self.request("sessions.create", params: ["host": .text(host), "dir": .text(path)])
            self.acceptLauncherMutation(result)
            if let message = result.error, !message.isEmpty { throw APIError.message(message) }
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
        formRequestRepo = repo
        splitMode = false
        error = nil; notice = nil; createdPath = nil
        items = []; selectedID = nil; scrollID = nil
        resetBranchDefault()
        applyBranchDefault()
        schedulePreview(immediate: true)
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
        if shortcutsPresented { shortcutsPresented = false; return }
        if sessionCloseCandidate != nil { removalCandidate = nil; return }
        if sessionDeletion != nil {
            if busy { dismiss() } else { cancelDeleteSession() }
            return
        }
        if renameCandidate != nil { cancelRenameSession(); return }
        if prCommitConfirmationPresented { cancelPullRequestCommitCheckout(); return }
        if busy || !contextReady || (createdPath != nil && notice == nil) { dismiss(); return }
        if page == .pr {
            if targetPickerPresented { targetPickerPresented = false; return }
            returnFromPullRequest()
            return
        }
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

    private func formContext(repo: String?) -> FormContext {
        FormContext(session: options.session, block: options.block, client: options.client,
                    title: options.title, repo: repo)
    }

    private func rememberFormMetadata(_ result: APIResult, requestedRepo: String?) {
        if formMetadata.count >= 32 { formMetadata.removeAll() }
        let metadata = APIResult(targets: result.targets, target: result.target, repo: result.repo,
                                 destinationRoot: result.destinationRoot, branches: result.branches,
                                 baseBranch: result.baseBranch, suggestedBranch: result.suggestedBranch,
                                 agent: result.agent, agentModel: result.agentModel,
                                 agentReasoning: result.agentReasoning, agents: result.agents)
        formMetadata[formContext(repo: requestedRepo)] = metadata
        if let repo = result.repo { formMetadata[formContext(repo: repo)] = metadata }
    }

    private func restoreFormMetadata() {
        guard let cached = formMetadata[formContext(repo: formRequestRepo)] else { return }
        repo = cached.repo ?? repo
        branches = cached.branches ?? []
        base = cached.baseBranch ?? branches.first ?? ""
        suggestedBranch = cached.suggestedBranch
        destinationRoot = cached.destinationRoot
        targets = cached.targets ?? targets
        if !targets.contains(target) { target = cached.target ?? targets.first ?? "" }
        applyAgentDefaults(cached)
        applyBranchDefault()
        // Never restore validation: Create still requires a fresh preview.
    }

    // Config defaults apply once per form open; later refreshes never clobber
    // an in-progress selection.
    private func applyAgentDefaults(_ result: APIResult) {
        if let choices = result.agents, !choices.isEmpty { agentChoices = choices }
        guard !agentDefaultsApplied else { return }
        let configured = result.agent.flatMap { $0.isEmpty ? nil : $0 } ?? "none"
        agent = configured
        agentModel = result.agentModel ?? ""
        agentProvider = Self.providerPartition(agentModel).provider
        agentModel = Self.providerPartition(agentModel).id
        agentReasoning = result.agentReasoning ?? ""
        if configured != "none" {
            ensureAgentCatalog(for: configured)
        }
        agentDefaultsApplied = true
    }

    /// Config may store "provider/id"; split once so flags stay separate.
    static func providerPartition(_ value: String) -> (provider: String, id: String) {
        guard let slash = value.firstIndex(of: "/") else { return ("", value) }
        let provider = String(value[value.startIndex..<slash])
        let id = String(value[value.index(after: slash)...])
        if provider.isEmpty || id.isEmpty { return ("", value) }
        return (provider, id)
    }

    // MARK: Agent launch controls

    /// ⌃⌥O or the summary row: reveal/hide the agent, model, and reasoning fields.
    func toggleAgentControls() {
        guard page == .create, createdPath == nil, contextReady, !busy,
              !basePickerPresented, !agentPickerPresented, !agentModelPickerPresented, !agentReasoningPickerPresented else { return }
        agentControlsShown.toggle()
        if agentControlsShown { ensureAgentCatalog(for: agent) }
    }

    var hasPopover: Bool {
        basePickerPresented || targetPickerPresented || agentPickerPresented
            || agentModelPickerPresented || agentReasoningPickerPresented
    }

    func closeAgentPopovers() {
        agentPickerPresented = false
        agentModelPickerPresented = false
        agentReasoningPickerPresented = false
    }

    var agentCatalogModels: [AgentModelPayload] { agentCatalogs[agent] ?? [] }

    func agentDisplayName(_ name: String) -> String {
        switch name {
        case "none": return "No agent"
        case "pi": return "Pi"
        case "codex": return "Codex"
        default: return name.isEmpty ? "No agent" : name.capitalized
        }
    }

    var agentDisplayLabel: String { agentDisplayName(agent) }

    /// Model button title: selected label, discovery state, or tool default.
    var selectedModelLabel: String {
        guard agent != "none" else { return "—" }
        if let selected = agentCatalogModels.first(where: { $0.id == agentModel }) {
            return selected.displayLabel
        }
        if agentModel.isEmpty {
            return agentCatalogLoading && agentCatalogModels.isEmpty ? "Discovering models…" : "Agent default"
        }
        return agentModel
    }

    var agentSummary: String {
        guard agent != "none" else { return "No agent" }
        var parts = [agent]
        if let selected = agentCatalogModels.first(where: { $0.id == agentModel }) {
            parts.append(selected.displayLabel)
        } else if !agentModel.isEmpty {
            parts.append(agentModel)
        }
        if let reasoning = agentReasoningDetail { parts.append(reasoning) }
        return parts.joined(separator: " · ")
    }

    private var agentReasoningDetail: String? {
        agentReasoning.isEmpty || agentReasoning == agentReasoningDefault ? nil : agentReasoning
    }

    /// Reasoning options for the selected model; "default" first.
    var agentReasoningChoices: [String] {
        let levels = agentCatalogModels.first(where: { $0.id == agentModel })?.reasoning ?? []
        return [agentReasoningDefault] + levels
    }

    func selectAgent(_ choice: String) {
        guard page == .create, createdPath == nil, choice == "none" || agentChoices.contains(choice) || choice == agent else { return }
        agent = choice
        agentProvider = ""
        agentModel = ""
        agentReasoning = ""
        ensureAgentCatalog(for: choice)
    }

    func selectAgentModel(_ model: AgentModelPayload) {
        agent = agent == "none" ? "pi" : agent
        agentModel = model.id
        agentProvider = model.provider ?? ""
        agentReasoning = model.defaultReasoning.flatMap { $0.isEmpty ? nil : $0 } ?? ""
    }

    func selectAgentReasoning(_ level: String) {
        agentReasoning = level
    }

    /// Persists the current selections as config defaults (explicit Save).
    func saveAgentDefaults() {
        guard page == .create, contextReady, !busy else { return }
        let agent = agent, provider = agentProvider, model = agentModel, reasoning = agentReasoning
        // Pi models need their provider on reload; store the qualified id.
        let stored = agent == "pi" && !provider.isEmpty ? provider + "/" + model : model
        perform {
            _ = try await self.request("config.saveAgent", params: [
                "agent": .text(agent), "agent_provider": .text(provider),
                "agent_model": .text(stored), "agent_reasoning": .text(reasoning),
            ])
            self.notice = "Saved agent defaults"
        }
    }

    /// Discovery is cached by the backend; requests dedupe per agent.
    private func ensureAgentCatalog(for agent: String) {
        guard page == .create else { return }
        guard agent != "none", !agent.isEmpty else {
            agentCatalogWarning = nil
            return
        }
        guard agentCatalogs[agent] == nil, !agentCatalogsRequested.contains(agent) else { return }
        agentCatalogsRequested.insert(agent)
        agentCatalogLoading = true
        agentCatalogWarning = nil
        perform {
            defer { self.agentCatalogLoading = false }
            do {
                let result = try await self.request("agents.catalog", params: ["agent": .text(agent)])
                let models = result.agentModels ?? []
                self.agentCatalogs[agent] = models
                self.agentCatalogWarning = result.agentWarning.flatMap { $0.isEmpty ? nil : $0 }
                if self.agent == agent, self.agentControlsShown {
                    self.applyCatalogDefaults(models)
                }
            } catch {
                self.agentCatalogsRequested.remove(agent)
                self.agentCatalogWarning = error.localizedDescription
            }
        }
    }

    private func applyCatalogDefaults(_ models: [AgentModelPayload]) {
        guard !models.isEmpty else { return }
        if let selected = models.first(where: { $0.id == agentModel }) {
            agentProvider = selected.provider ?? agentProvider
            return
        }
        let chosen = models.first(where: { $0.isDefault == true }) ?? models.first
        guard let chosen else { return }
        agentModel = chosen.id
        agentProvider = chosen.provider ?? ""
        agentReasoning = chosen.defaultReasoning.flatMap { $0.isEmpty ? nil : $0 } ?? ""
    }

    // Never queue Enter for a pending preview.
    func submitBranch() {
        guard page == .create, canSubmitForm else { return }
        create()
    }

    private func schedulePreview(immediate: Bool = false) {
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
                if !immediate { try await Task.sleep(for: .milliseconds(180)) }
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
        var params: [String: APIValue] = ["repo": .text(repo), "branch": .text(branch), "base": .text(base)]
        if agent != "none" {
            params["agent"] = .text(agent)
            params["agent_provider"] = .text(agentProvider)
            params["agent_model"] = .text(agentModel)
            params["agent_reasoning"] = .text(agentReasoning)
        }
        let target = target
        perform {
            let result = try await self.request("worktrees.create", params: params)
            guard let path = result.path, !path.isEmpty else { throw APIError.message("Backend returned no worktree path.") }
            self.invalidateLists()
            // Commit this state before opening. A failed dispatch must never
            // turn the retry button into a second create request.
            self.createdPath = path
            if self.agent != "none" {
                self.createdLaunch = (self.agent, self.agentProvider, self.agentModel, self.agentReasoning)
            }
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

    func beginRenameSession() {
        guard contextReady, canOpen, view == .sessions, page == .directories,
              removalCandidate == nil, renameCandidate == nil, sessionDeletion == nil,
              let selected, selected.kind == "session" else { return }
        // Keep the editing row mounted, even when a live refresh removes it.
        generation += 1
        queryTask?.cancel()
        activityTask?.cancel(); activityTask = nil; activityDirty = false
        refreshing = false
        renameLabel = selected.label ?? ""
        renameCandidate = selected
        splitMode = false
    }

    var canRenameSession: Bool {
        contextReady && !busy && renameCandidate != nil
            && !renameLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func cancelRenameSession() {
        renameCandidate = nil
        renameLabel = ""
    }

    private func renamedRows(_ rows: [PickerItem], candidate: PickerItem, label: String?, sessionLabel: String?) -> [PickerItem] {
        rows.map { row in
            guard row.host == candidate.host else { return row }
            var row = row
            if row.id == candidate.id && row.kind == "session" { row.label = label }
            if let sessionID = candidate.sessionID, row.sessionID == sessionID { row.sessionLabel = sessionLabel }
            return row
        }
    }

    private func publishSessionName(_ candidate: PickerItem, label: String?, sessionLabel: String?) {
        items = renamedRows(items, candidate: candidate, label: label, sessionLabel: sessionLabel)
        // Keep the visible snapshot during revalidation. Clearing it here would
        // replace the instant rename with an empty list and a loading state.
        cacheSessionSnapshot()
    }

    private func cacheSessionSnapshot() {
        let snapshot = APIResult(items: items, hosts: sessionHosts, targets: targets, target: target)
        cache[cacheKey] = CachedList(result: snapshot, selectedID: selectedID, scrollID: scrollID, target: target)
        activeKey = cacheKey
    }

    func confirmRenameSession() {
        guard canRenameSession, let candidate = renameCandidate else { return }
        let label = renameLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = contextGeneration
        cancelRenameSession()
        invalidateLists()
        selectedID = candidate.id
        pendingRename = (context, candidate, label)
        publishSessionName(candidate, label: label, sessionLabel: label)
        perform {
            do {
                _ = try await self.request("sessions.rename", params: [
                    "kind": .text("session"),
                    "session_id": .text(candidate.sessionID ?? candidate.path),
                    "host": .text(candidate.host ?? ""),
                    "label": .text(label),
                ])
            } catch {
                guard context == self.contextGeneration, !self.closed else { throw error }
                self.pendingRename = nil
                self.invalidateLists()
                self.publishSessionName(candidate, label: candidate.label, sessionLabel: candidate.sessionLabel)
                throw error
            }
            // The confirmed name is already visible and cached. Live updates
            // reconcile later; another list request can still contain old rows.
            self.pendingRename = nil
        }
    }

    /// The Sessions counterpart of askRemove: close a remote or local session.
    func askCloseSession() {
        guard contextReady else { return }
        guard canOpen, view == .sessions, page == .directories,
              let selected, selected.kind == "session" else { return }
        pauseSessionUpdates()
        removalCandidate = selected
    }

    private func pauseSessionUpdates() {
        generation += 1
        queryTask?.cancel()
        activityTask?.cancel(); activityTask = nil; activityDirty = false
        refreshing = false
    }

    private func removeSessionRow(_ candidate: PickerItem, worktreePath: String? = nil, animated: Bool = false) {
        let previous = items
        let index = previous.firstIndex { $0.id == candidate.id && $0.host == candidate.host } ?? 0
        let updated = previous.filter { item in
            !(item.host == candidate.host && (item.id == candidate.id
                || (item.kind == "dir" && item.path == worktreePath)))
        }
        let animate = animated && PickerStyle.animatesSessionRemoval(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            visible: presented, candidate: candidate, previous: previous, updated: updated)
        invalidateLists()
        // Match Pin's explicit transaction: only this manual close animates.
        // Background refreshes and failure rollback remain immediate.
        let transaction = Transaction(animation: animate ? .easeInOut(duration: PickerStyle.sessionRemovalDuration) : nil)
        withTransaction(transaction) {
            items = updated
            if !items.contains(where: { $0.id == selectedID }) {
                selectedID = items.isEmpty ? nil : items[min(index, items.count - 1)].id
            }
            cacheSessionSnapshot()
        }
    }

    func confirmCloseSession(_ candidate: PickerItem) {
        guard contextReady else { return }
        guard view == .sessions, page == .directories, !busy, candidate.kind == "session",
              sessionCloseCandidate?.id == candidate.id else { return }
        let context = contextGeneration
        let index = items.firstIndex { $0.id == candidate.id && $0.host == candidate.host } ?? 0
        removalCandidate = nil
        pendingSessionRemoval = (context, candidate)
        removeSessionRow(candidate, animated: true)
        perform {
            do {
                _ = try await self.request("sessions.close", params: [
                    "kind": .text("session"),
                    "session_id": .text(candidate.sessionID ?? candidate.path),
                    "host": .text(candidate.host ?? ""),
                ])
            } catch {
                guard context == self.contextGeneration, !self.closed else { throw error }
                self.pendingSessionRemoval = nil
                self.invalidateLists()
                self.items.insert(candidate, at: min(index, self.items.count))
                self.selectedID = candidate.id
                self.cacheSessionSnapshot()
                throw error
            }
            self.pendingSessionRemoval = nil
        }
    }

    func beginDeleteSession() {
        guard contextReady, canOpen, view == .sessions, page == .directories,
              let selected, selected.kind == "session" else { return }
        pauseSessionUpdates()
        let deletion = SessionDeletion(candidate: selected)
        sessionDeletion = deletion
        let context = contextGeneration
        deletionPreviewTask?.cancel()
        deletionPreviewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.request("sessions.delete.preview", params: [
                    "kind": .text("session"), "session_id": .text(selected.sessionID ?? selected.path),
                    "host": .text(selected.host ?? ""), "review_worktrees": .flag(true),
                    "discover_only": .flag(true),
                ])
                guard !Task.isCancelled, context == self.contextGeneration, self.sessionDeletion?.id == deletion.id else { return }
                if let error = result.error, !error.isEmpty { throw APIError.message(error) }
                try self.acceptDeletionReview(result)
                await self.checkDeletionWorktrees(context: context, id: deletion.id)
            } catch {
                guard !Task.isCancelled, context == self.contextGeneration,
                      self.sessionDeletion?.id == deletion.id else { return }
                self.sessionDeletion?.error = error.localizedDescription
                self.sessionDeletion?.phase = .failed
            }
        }
    }

    private func acceptDeletionReview(_ result: APIResult) throws {
        guard let token = result.deleteToken, !token.isEmpty, let worktrees = result.worktrees,
              Set(worktrees.map(\.path)).count == worktrees.count,
              sessionDeletion?.plan?.deleteToken == nil || sessionDeletion?.plan?.deleteToken == token else {
            throw APIError.message("Backend returned no valid worktree review.")
        }
        let previous = Set((sessionDeletion?.plan?.worktrees ?? []).filter(\.deletable).map(\.path))
        let ready = Set(worktrees.filter(\.deletable).map(\.path))
        sessionDeletion?.selectedPaths.formIntersection(ready)
        sessionDeletion?.selectedPaths.formUnion(ready.subtracting(previous))
        sessionDeletion?.plan = result
        if worktrees.contains(where: { !$0.isChecked }) { sessionDeletion?.phase = .loading }
        else { sessionDeletion?.phase = worktrees.contains(where: { $0.deletable && !$0.isPrepared }) ? .review : .confirm }
    }

    private func checkDeletionWorktrees(context: Int, id: UUID, firstPath: String? = nil) async {
        var preferred = firstPath
        while !Task.isCancelled, context == contextGeneration, let deletion = sessionDeletion, deletion.id == id {
            let preferredRow = preferred.flatMap { path in deletion.plan?.worktrees?.first { $0.path == path && !$0.isChecked } }
            preferred = nil
            guard let row = preferredRow ?? deletion.plan?.worktrees?.first(where: { !$0.isChecked }), let token = deletion.plan?.deleteToken else {
                sessionDeletion?.checkingPath = nil
                sessionDeletion?.checkStartedAt = nil
                return
            }
            sessionDeletion?.checkingPath = row.path
            sessionDeletion?.checkStartedAt = Date()
            do {
                let result = try await request("sessions.delete.check", params: [
                    "kind": .text("session"), "session_id": .text(deletion.candidate.sessionID ?? deletion.candidate.path),
                    "host": .text(deletion.candidate.host ?? ""), "review_worktrees": .flag(true),
                    "delete_token": .text(token), "path": .text(row.path), "metadata_only": .flag(true),
                ])
                guard !Task.isCancelled, context == contextGeneration, sessionDeletion?.id == id else { return }
                if let error = result.error, !error.isEmpty {
                    sessionDeletion?.error = error
                    sessionDeletion?.phase = .failed
                    sessionDeletion?.checkingPath = nil
                    return
                }
                try acceptDeletionReview(result)
                // A successful check must resolve or finish its requested row.
                let before = deletion.plan?.worktrees?.filter { !$0.isChecked }.count ?? 0
                let remaining = result.worktrees?.filter { !$0.isChecked }.count ?? before
                guard remaining < before,
                      result.worktrees?.contains(where: { $0.path == row.path && !$0.isChecked }) != true else {
                    throw APIError.message("Worktree check did not finish. Retry this check.")
                }
            } catch {
                guard !Task.isCancelled, context == contextGeneration, sessionDeletion?.id == id else { return }
                if backendIsClosed {
                    sessionDeletion?.error = "Connection lost. Refresh the review to check paths again. \(error.localizedDescription)"
                    sessionDeletion?.phase = .failed
                } else if let index = sessionDeletion?.plan?.worktrees?.firstIndex(where: { $0.path == row.path }) {
                    sessionDeletion?.plan?.worktrees?[index].error = error.localizedDescription
                } else {
                    sessionDeletion?.error = error.localizedDescription
                    sessionDeletion?.phase = .failed
                }
                sessionDeletion?.checkingPath = nil
                return
            }
        }
    }

    var canPrepareSessionDeletion: Bool {
        guard contextReady, !backendIsClosed, !busy, let deletion = sessionDeletion,
              deletion.phase == .review, deletion.checkingPath == nil, deletion.preparationSelection == nil,
              deletion.plan?.worktrees?.allSatisfy(\.isChecked) == true, !deletion.selectedPaths.isEmpty else { return false }
        let eligible = Set((deletion.plan?.worktrees ?? []).filter(\.deletable).map(\.path))
        return deletion.selectedPaths.isSubset(of: eligible)
    }

    func prepareSessionDeletion() {
        guard canPrepareSessionDeletion, let deletion = sessionDeletion else { return }
        sessionDeletion?.preparationSelection = deletion.selectedPaths
        sessionDeletion?.phase = .preparing
        let context = contextGeneration
        deletionPreviewTask?.cancel()
        deletionPreviewTask = Task { [weak self] in await self?.prepareDeletionWorktrees(context: context, id: deletion.id) }
    }

    private func prepareDeletionWorktrees(context: Int, id: UUID, firstPath: String? = nil) async {
        var preferred = firstPath
        while !Task.isCancelled, context == contextGeneration, let deletion = sessionDeletion, deletion.id == id,
              let selection = deletion.preparationSelection, let token = deletion.plan?.deleteToken {
            let pending = (deletion.plan?.worktrees ?? []).filter { selection.contains($0.path) && !$0.isPrepared }
            let row = preferred.flatMap { path in pending.first { $0.path == path } } ?? pending.first
            preferred = nil
            guard let row else {
                sessionDeletion?.phase = .confirm
                sessionDeletion?.checkingPath = nil
                sessionDeletion?.checkStartedAt = nil
                return
            }
            sessionDeletion?.checkingPath = row.path
            sessionDeletion?.checkStartedAt = Date()
            do {
                let result = try await request("sessions.delete.prepare", params: [
                    "kind": .text("session"), "session_id": .text(deletion.candidate.sessionID ?? deletion.candidate.path),
                    "host": .text(deletion.candidate.host ?? ""), "review_worktrees": .flag(true),
                    "delete_token": .text(token), "path": .text(row.path), "selected_paths": .texts(selection.sorted()),
                ])
                guard !Task.isCancelled, context == contextGeneration, sessionDeletion?.id == id else { return }
                if let error = result.error, !error.isEmpty {
                    sessionDeletion?.error = error
                    sessionDeletion?.phase = .failed
                    sessionDeletion?.checkingPath = nil
                    return
                }
                guard result.deleteToken == token, let rows = result.worktrees,
                      Set(rows.map(\.path)).count == rows.count, rows.allSatisfy(\.isChecked),
                      selection.isSubset(of: Set(rows.map(\.path))),
                      let finished = rows.first(where: { $0.path == row.path }), finished.isPrepared || finished.error != nil else {
                    throw APIError.message("Preparation did not finish. Retry this worktree.")
                }
                sessionDeletion?.plan = result
                if finished.error != nil {
                    sessionDeletion?.checkingPath = nil
                    return
                }
            } catch {
                guard !Task.isCancelled, context == contextGeneration, sessionDeletion?.id == id else { return }
                if backendIsClosed {
                    sessionDeletion?.error = "Connection lost. Refresh the review before preparing again. \(error.localizedDescription)"
                    sessionDeletion?.phase = .failed
                } else if let index = sessionDeletion?.plan?.worktrees?.firstIndex(where: { $0.path == row.path }) {
                    sessionDeletion?.plan?.worktrees?[index].error = error.localizedDescription
                } else {
                    sessionDeletion?.error = error.localizedDescription
                    sessionDeletion?.phase = .failed
                }
                sessionDeletion?.checkingPath = nil
                return
            }
        }
    }

    private func retryDeletionPreparation(_ path: String) {
        guard !busy, let deletion = sessionDeletion, deletion.checkingPath == nil,
              deletion.preparationSelection?.contains(path) == true,
              deletion.plan?.worktrees?.contains(where: { $0.path == path && !$0.isPrepared }) == true else { return }
        let context = contextGeneration
        deletionPreviewTask?.cancel()
        deletionPreviewTask = Task { [weak self] in await self?.prepareDeletionWorktrees(context: context, id: deletion.id, firstPath: path) }
    }

    func retryDeletionWorktree(_ path: String) {
        if sessionDeletion?.phase == .preparing { retryDeletionPreparation(path); return }
        guard !busy, let deletion = sessionDeletion, deletion.checkingPath == nil, deletion.preparationSelection == nil,
              deletion.phase == .loading || deletion.phase == .review || deletion.phase == .confirm,
              let index = deletion.plan?.worktrees?.firstIndex(where: { $0.path == path && ($0.retryable || !$0.isChecked) }) else { return }
        sessionDeletion?.plan?.worktrees?[index].checked = false
        sessionDeletion?.plan?.worktrees?[index].error = nil
        sessionDeletion?.phase = .loading
        let context = contextGeneration
        deletionPreviewTask?.cancel()
        deletionPreviewTask = Task { [weak self] in await self?.checkDeletionWorktrees(context: context, id: deletion.id, firstPath: path) }
    }

    func refreshDeletionReview() {
        guard !closed, !busy, sessionDeletion != nil else { return }
        cancelDeleteSession()
        if let process = backend as? ProcessBackend, process.isClosed {
            themeTask?.cancel()
            backend = ProcessBackend(options: options)
            renewSubscription()
        }
        beginDeleteSession()
    }

    func cancelDeleteSession() {
        guard !busy else { return }
        deletionPreviewTask?.cancel(); deletionPreviewTask = nil
        sessionDeletion = nil
    }

    var canConfirmSessionDeletion: Bool {
        guard contextReady, !backendIsClosed, !busy, let deletion = sessionDeletion,
              deletion.phase == .confirm || deletion.phase == .forceConfirm,
              deletion.plan?.deleteToken != nil, deletion.closeSessionConfirmed,
              deletion.checkingPath == nil, deletion.plan?.worktrees?.allSatisfy(\.isChecked) == true,
              !deletion.selectedPaths.isEmpty,
              deletion.preparationSelection == nil || deletion.preparationSelection == deletion.selectedPaths else { return false }
        let deletable = Set((deletion.plan?.worktrees ?? []).filter { $0.deletable && $0.isPrepared }.map(\.path))
        return deletion.selectedPaths.isSubset(of: deletable)
            && deletion.selectedPaths.isDisjoint(with: deletion.deletedPaths)
    }

    func selectDeletionWorktree(_ path: String, selected: Bool) {
        guard !busy, let deletion = sessionDeletion, deletion.preparationSelection == nil,
              deletion.phase == .confirm || deletion.phase == .loading || deletion.phase == .review,
              deletion.plan?.worktrees?.contains(where: { $0.path == path && $0.deletable }) == true else { return }
        if selected { sessionDeletion?.selectedPaths.insert(path) }
        else { sessionDeletion?.selectedPaths.remove(path) }
    }

    func confirmDeletionSessionClose(_ confirmed: Bool) {
        guard !busy, let deletion = sessionDeletion, deletion.plan != nil,
              deletion.phase == .confirm || deletion.phase == .loading || deletion.phase == .review else { return }
        sessionDeletion?.closeSessionConfirmed = confirmed
    }

    func offerForceDeleteSession() {
        guard !busy, sessionDeletion?.phase == .forceOffered,
              sessionDeletion?.closeSessionConfirmed == true else { return }
        sessionDeletion?.phase = .forceConfirm
    }

    func confirmDeleteSession() {
        guard canConfirmSessionDeletion, let deletion = sessionDeletion,
              let token = deletion.plan?.deleteToken else { return }
        let context = contextGeneration
        sessionDeletion?.phase = .deleting
        sessionDeletion?.checkStartedAt = Date()
        sessionDeletion?.error = nil
        perform {
            do {
                let result = try await self.request("sessions.delete", params: [
                    "kind": .text("session"),
                    "session_id": .text(deletion.candidate.sessionID ?? deletion.candidate.path),
                    "host": .text(deletion.candidate.host ?? ""), "delete_token": .text(token),
                    "force": .flag(deletion.phase == .forceConfirm),
                    "review_worktrees": .flag(true), "close_session": .flag(deletion.closeSessionConfirmed),
                    "selected_paths": .texts(deletion.selectedPaths.sorted()),
                ])
                guard context == self.contextGeneration, self.sessionDeletion?.id == deletion.id else { return }
                let deletedPaths = Set(result.deletedPaths ?? [])
                guard deletedPaths.isSubset(of: deletion.selectedPaths) else {
                    throw APIError.message("Backend returned unexpected deleted paths. Check resources before retrying.")
                }
                self.sessionDeletion?.deletedPaths.formUnion(deletedPaths)
                if !deletedPaths.isEmpty {
                    self.items.removeAll { item in
                        item.host == deletion.candidate.host && item.kind == "dir"
                            && deletedPaths.contains(where: { item.path == $0 || item.path.hasPrefix($0 + "/") })
                    }
                    self.invalidateLists()
                    self.cacheSessionSnapshot()
                }
                if let error = result.error, !error.isEmpty, result.sessionClosed != true {
                    self.sessionDeletion?.error = error
                    self.sessionDeletion?.phase = result.forceAvailable == true ? .forceOffered : .failed
                    if result.deleteToken != nil, result.worktrees != nil { self.sessionDeletion?.plan = result }
                    return
                }
                guard result.sessionClosed == true, result.worktreeRemoved == true, result.branchRemoved == true,
                      deletedPaths == deletion.selectedPaths else {
                    self.sessionDeletion?.error = "Backend did not confirm complete deletion. Check resources before retrying."
                    self.sessionDeletion?.phase = .failed
                    return
                }
                self.sessionDeletion = nil
                self.removeSessionRow(deletion.candidate)
                if let warning = result.error, !warning.isEmpty { self.notice = warning }
            } catch {
                guard context == self.contextGeneration, !self.closed,
                      self.sessionDeletion?.id == deletion.id else { return }
                self.sessionDeletion?.error = error.localizedDescription
                self.sessionDeletion?.phase = .failed
            }
        }
    }

    func openCreated() {
        guard contextReady else { return }
        guard !busy, !backendIsClosed, let path = createdPath, !target.isEmpty else { return }
        dispatch(path: path, target: target)
    }

    private func dispatch(path: String, target: String) {
        perform {
            let result: APIResult
            if let launch = self.createdLaunch {
                result = try await self.request("dispatch", params: [
                    "target": .text(target), "path": .text(path),
                    "agent": .text(launch.agent), "agent_provider": .text(launch.provider),
                    "agent_model": .text(launch.model), "agent_reasoning": .text(launch.reasoning),
                ])
            } else {
                result = try await self.request("dispatch", params: ["target": .text(target), "path": .text(path)])
            }
            self.acceptLauncherMutation(result)
            if let message = result.error, !message.isEmpty { throw APIError.message(message) }
            if self.options.demo {
                self.notice = "Demo only: opened \(PathDisplay.abbreviate(path, home: "/Users/demo")) → \(Self.targetLabel(target)). No Rex call."
            } else {
                self.createdPath = nil // Dispatch succeeded: no recovery remains to preserve.
                self.finishNavigation()
            }
        }
    }

    private func openPath(_ path: String, target: String) async throws {
        let result = try await request("dispatch", params: ["target": .text(target), "path": .text(path)])
        acceptLauncherMutation(result)
        if let message = result.error, !message.isEmpty { throw APIError.message(message) }
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

    // URL recognition is local and read-only. Metadata is requested only in the form.
    static func pullRequestLink(_ input: String) -> (repo: String, number: Int)? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: input), url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com", url.user == nil, url.password == nil,
              url.port == nil else { return nil }
        // Match the encoded path so escaped separators/identities cannot change
        // repository meaning. Query strings and fragments are browser context only.
        let path = url.percentEncodedPath
        let pattern = #"^/([A-Za-z0-9_][A-Za-z0-9_.-]*)/([A-Za-z0-9_][A-Za-z0-9_.-]*)/pull/([1-9][0-9]*)(?:/(?:changes|files|commits|checks))?/?$"#
        guard let match = path.range(of: pattern, options: .regularExpression),
              match == path.startIndex..<path.endIndex else { return nil }
        let parts = path.dropFirst().split(separator: "/")
        guard parts[1] != ".", parts[1] != "..", let number = Int(parts[3]) else { return nil }
        return ("\(parts[0])/\(parts[1])", number)
    }

    static func normalizedPullRequestURL(_ input: String) -> String? {
        guard let link = pullRequestLink(input) else { return nil }
        return "https://github.com/\(link.repo)/pull/\(link.number)"
    }

    /// Keep recovery on this model and retain its original Rex context. Open
    /// reconciles durable path/IDs state; reconnect must never call Prepare.
    @discardableResult
    func reconnectPullRequestBackend() -> Bool {
        guard !closed, !busy, page == .pr, createdPath != nil,
              let process = backend as? ProcessBackend, process.isClosed else { return false }
        prTask?.cancel(); themeTask?.cancel()
        backend = ProcessBackend(options: options)
        renewSubscription()
        return true
    }

    private var canReconnectPullRequest: Bool {
        !closed && page == .pr && createdPath != nil && backendIsClosed
    }

    var requiresPullRequestCommitChoice: Bool {
        guard let info = pullRequest else { return false }
        return ["CLOSED", "MERGED"].contains(info.state?.uppercased() ?? "") && info.headDeleted == true
    }

    var pullRequestCommitExplanation: String {
        let state = pullRequest?.state?.lowercased() ?? "closed"
        let number = pullRequest?.number ?? Self.pullRequestLink(prInput)?.number ?? 0
        return "This PR is \(state) and its branch was deleted. Create an editable worktree at its last commit on local branch pr/\(number). The deleted branch will not be restored or pushed."
    }

    var canOpenPullRequest: Bool {
        contextReady && (!backendIsClosed || canReconnectPullRequest) && !busy && !loading && !targetPickerPresented && !prCommitConfirmationPresented
            && ["session", "tab"].contains(target)
            && (createdPath != nil || pullRequest != nil)
    }

    private func prefillPullRequestFromClipboard() {
        guard page == .pr, prInput.isEmpty, createdPath == nil,
              let value = pullRequestClipboard()?.trimmingCharacters(in: .whitespacesAndNewlines),
              Self.pullRequestLink(value) != nil else { return }
        prInput = value
    }

    func beginPullRequest(input: String = "") {
        guard contextReady, !busy, page != .pr, createdPath == nil else { return }
        prReturn = (page, view, repo, query, selectedID, scrollID, targets, target, items)
        let context = repo ?? ((selected?.kind == "dir" || selected?.kind == "worktree") ? selected?.path : nil)
        saveListPosition()
        generation += 1; queryTask?.cancel()
        activityTask?.cancel(); activityTask = nil; activityDirty = false
        refreshing = false
        view = .sessions; page = .pr
        repo = context
        targets = ["session", "tab"]; target = "session"
        splitMode = false; targetPickerPresented = false
        error = nil; notice = nil; pullRequest = nil; prStage = nil
        prInput = input
        prefillPullRequestFromClipboard()
        resolvePullRequest()
    }

    private func returnFromPullRequest() {
        prGeneration += 1; prTask?.cancel(); prStage = nil
        prCommitConfirmationPresented = false; prCheckoutCommit = false
        guard let saved = prReturn else { dismiss(); return }
        changingContext = true
        page = saved.page; view = saved.view; repo = saved.repo; query = saved.query
        items = saved.items; selectedID = saved.selected; scrollID = saved.scroll
        targets = saved.targets; target = saved.target
        loading = false; error = nil; pullRequest = nil; prReturn = nil
        changingContext = false
        if page == .create { scheduleQuery(immediate: true) }
        else { onFocusSearch?() }
    }

    private func pullRequestParams() -> [String: APIValue] {
        // Commit checkout is sent only after explicit confirmation for this input.
        var params: [String: APIValue] = ["input": .text(Self.normalizedPullRequestURL(prInput) ?? prInput.trimmingCharacters(in: .whitespacesAndNewlines))]
        if prCheckoutCommit { params["checkout_commit"] = .flag(true) }
        return params
    }

    private func resolvePullRequest() {
        guard page == .pr, createdPath == nil, !busy, contextReady, !closed else { return }
        prGeneration += 1
        let token = prGeneration
        prTask?.cancel(); pullRequest = nil; error = nil; prStage = nil; loading = false
        prCommitConfirmationPresented = false; prCheckoutCommit = false; prCommitConfirmationInput = nil
        let input = prInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        guard Self.pullRequestLink(input) != nil else {
            error = "Enter a full GitHub pull request URL: https://github.com/owner/repo/pull/123"
            return
        }
        let params = pullRequestParams()
        loading = true; prStage = "Resolving"
        prTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(180))
                let result = try await self.request("pullrequests.resolve", params: params)
                guard token == self.prGeneration, self.page == .pr, !Task.isCancelled else { return }
                if let message = result.error, !message.isEmpty { throw APIError.message(message) }
                self.pullRequest = result
                self.loading = false; self.prStage = nil
            } catch {
                guard token == self.prGeneration, self.page == .pr, !Task.isCancelled else { return }
                self.loading = false; self.prStage = nil; self.error = error.localizedDescription
            }
        }
    }

    func cancelPullRequestCommitCheckout() {
        prCommitConfirmationPresented = false
        prCommitConfirmationInput = nil
    }

    func confirmPullRequestCommitCheckout() {
        guard page == .pr, prCommitConfirmationInput == prInput,
              requiresPullRequestCommitChoice, createdPath == nil else { return }
        cancelPullRequestCommitCheckout()
        prCheckoutCommit = true
        openPullRequest()
    }

    func openPullRequest() {
        guard page == .pr, canOpenPullRequest else { return }
        if createdPath == nil && requiresPullRequestCommitChoice && !prCheckoutCommit {
            prCommitConfirmationInput = prInput
            prCommitConfirmationPresented = true
            return
        }
        if backendIsClosed {
            guard reconnectPullRequestBackend() else { return }
        }
        let params = pullRequestParams(), target = target
        perform {
            defer { self.prStage = nil }
            if self.createdPath == nil {
                self.prStage = "Preparing repository and worktree"
                let result = try await self.request("pullrequests.prepare", params: params)
                // Even a partial prepare result can contain a usable recovery path.
                if let path = result.path, !path.isEmpty { self.createdPath = path }
                if let message = result.error, !message.isEmpty { throw APIError.message(message) }
                guard self.createdPath != nil else { throw APIError.message("Backend returned no worktree path.") }
                self.pullRequest = result
                self.invalidateLists()
            }
            guard let path = self.createdPath else { return }
            self.prStage = "Opening session"
            do {
                let result = try await self.request("pullrequests.open", params: ["path": .text(path), "target": .text(target)])
                self.acceptLauncherMutation(result)
                if let returned = result.path, !returned.isEmpty { self.createdPath = returned }
                if let message = result.error, !message.isEmpty { throw APIError.message(message) }
            } catch {
                throw APIError.message("Worktree preserved at \(self.createdPath ?? path). Retry opening. \(error.localizedDescription)")
            }
            self.createdPath = nil
            self.finishNavigation()
        }
    }

    static func targetLabel(_ target: String) -> String {
        switch target {
        case "tab": return "New tab"
        case "session": return "New session"
        case "here": return "cd here"
        case "pane_right": return "Split right"
        case "pane_below": return "Split below"
        default: return target
        }
    }
}
