import SwiftUI

@MainActor
final class PickerModel: ObservableObject {
    enum Page: Equatable { case directories, repositories, worktrees, create }
    let options: LaunchOptions
    private let backend: any BackendClient
    @Published var page: Page
    @Published var query = "" { didSet { if query != oldValue && page != .create { scheduleQuery() } } }
    @Published var items: [PickerItem] = []
    @Published var selectedID: String?
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

    init(options: LaunchOptions, backend: any BackendClient) {
        self.options = options
        self.backend = backend
        self.page = options.mode == "wt-create" ? .create : (options.mode == "wt" ? .worktrees : .directories)
        self.repo = options.repo
        self.loading = true
    }

    var selected: PickerItem? { items.first { $0.id == selectedID } }
    var canOpen: Bool { !busy && !loading && selected != nil && !target.isEmpty }
    var canCreate: Bool { !busy && !loading && !basePickerPresented && !targetPickerPresented && previewReady && validationError == nil && destination != nil && !branch.isEmpty && !base.isEmpty && !target.isEmpty && createdPath == nil }
    var canSubmitForm: Bool { !basePickerPresented && (canCreate || (!busy && createdPath != nil && !target.isEmpty)) }
    var heading: String {
        switch page {
        case .directories: return "Open directory"
        case .repositories: return "Choose repository"
        case .worktrees: return "Worktrees"
        case .create: return "Create worktree"
        }
    }

    func start() {
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
    func close() {
        guard !closed else { return }
        closed = true
        queryTask?.cancel(); previewTask?.cancel(); operationTask?.cancel(); themeTask?.cancel()
        onAdvanceFormFocus = nil; onFocusSearch = nil
        backend.close()
        onClose?()
    }

    private func scheduleQuery(immediate: Bool = false) {
        guard !closed else { return }
        generation += 1
        let token = generation
        queryTask?.cancel()
        loading = true
        splitMode = false
        error = nil
        let currentPage = page
        let currentQuery = query
        let currentRepo = repo
        queryTask = Task { [weak self] in
            guard let self else { return }
            do {
                if !immediate { try await Task.sleep(for: .milliseconds(140)) }
                try Task.checkCancellation()
                var params: [String: APIValue] = ["query": .text(currentQuery)]
                let method: String
                if currentPage == .worktrees || currentPage == .create {
                    method = "worktrees.list"
                    if let currentRepo { params["repo"] = .text(currentRepo) }
                } else {
                    method = "directories"
                    params["repos_only"] = .flag(currentPage == .repositories)
                }
                let result = try await self.backend.request(method, params: params)
                guard !Task.isCancelled, token == self.generation, !self.closed else { return }
                if (currentPage == .worktrees || currentPage == .create), result.needsRepo == true {
                    self.repo = nil
                    self.navigate(.repositories)
                    return
                }
                let previous = self.selectedID
                self.items = currentPage == .create ? [] : (result.items ?? [])
                self.selectedID = self.items.contains { $0.id == previous } ? previous : self.items.first?.id
                if let targets = result.targets { self.targets = targets }
                if !self.targets.contains(self.target) { self.target = result.target ?? self.targets.first ?? "" }
                if currentPage == .worktrees || currentPage == .create {
                    self.repo = result.repo ?? currentRepo
                    self.destinationRoot = result.destinationRoot
                    self.branches = result.branches ?? []
                    self.base = result.baseBranch ?? self.branches.first ?? ""
                }
                self.loading = false
                if currentPage == .create { self.schedulePreview() }
            } catch {
                guard !Task.isCancelled, token == self.generation, !self.closed else { return }
                self.loading = false
                self.items = []
                self.selectedID = nil
                self.error = error.localizedDescription
            }
        }
    }

    private func navigate(_ newPage: Page) {
        generation += 1
        previewGeneration += 1
        queryTask?.cancel(); previewTask?.cancel()
        page = newPage
        items = []; selectedID = nil; splitMode = false
        error = nil; notice = nil
        query = ""
        scheduleQuery(immediate: true)
        if newPage != .create { onFocusSearch?() }
    }

    func move(_ delta: Int) {
        guard !loading, !busy, !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == selectedID } ?? 0
        selectedID = items[min(max(index + delta, 0), items.count - 1)].id
    }

    func cycleTarget(backward: Bool) {
        guard !busy, page != .repositories, !targets.isEmpty else { return }
        let index = targets.firstIndex(of: target) ?? 0
        target = targets[(index + (backward ? targets.count - 1 : 1)) % targets.count]
    }

    func advanceFormFocus(backward: Bool) { onAdvanceFormFocus?(backward) }

    func searchBaseBranches(_ query: String) async throws -> [String] {
        guard !closed, let repo else { throw APIError.message("Choose a repository first.") }
        let result = try await backend.request("worktrees.branches", params: ["repo": .text(repo), "query": .text(query)])
        let matches = result.branches ?? []
        if query.isEmpty { branches = matches }
        return matches
    }

    func choose() {
        guard !busy, !loading, let selected else { return }
        if page == .repositories {
            repo = selected.path
            navigate(options.mode == "wt-create" ? .create : .worktrees)
        } else if canOpen {
            dispatch(path: selected.path, target: target)
        }
    }

    func showWorktrees() {
        guard !busy, !loading, page == .directories else { return }
        repo = selected?.path
        navigate(.worktrees)
    }

    func beginCreate() {
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
        page = .create
        splitMode = false
        error = nil; notice = nil; createdPath = nil
        branch = ""
        schedulePreview()
    }

    func escape() {
        guard removalCandidate == nil, !busy else { return }
        if basePickerPresented { basePickerPresented = false; return }
        if targetPickerPresented { targetPickerPresented = false; return }
        if splitMode { splitMode = false; return }
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
        guard page == .create, !closed, createdPath == nil else { return }
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
                let result = try await self.backend.request("worktrees.preview", params: ["repo": .text(repo), "branch": .text(branch), "base": .text(base)])
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
        guard !basePickerPresented else { return }
        if createdPath != nil { openCreated(); return }
        guard canCreate, let repo else { return }
        let params: [String: APIValue] = ["repo": .text(repo), "branch": .text(branch), "base": .text(base)]
        let target = target
        perform {
            let result = try await self.backend.request("worktrees.create", params: params)
            guard let path = result.path, !path.isEmpty else { throw APIError.message("Backend returned no worktree path.") }
            // Commit this state before opening. A failed dispatch must never
            // turn the retry button into a second create request.
            self.createdPath = path
            do { try await self.openPath(path, target: target) }
            catch { throw APIError.message("Worktree created, but opening failed. \(error.localizedDescription)") }
        }
    }

    func askRemove() {
        guard !busy, !loading, page == .worktrees, let selected, selected.isMain == false else { return }
        removalCandidate = selected
    }

    func confirmRemove(_ candidate: PickerItem) {
        guard let repo, !busy, page == .worktrees, candidate.isMain == false else { return }
        removalCandidate = nil
        perform {
            _ = try await self.backend.request("worktrees.remove", params: ["repo": .text(repo), "path": .text(candidate.path)])
            self.scheduleQuery(immediate: true)
        }
    }

    func openCreated() {
        guard !busy, let path = createdPath, !target.isEmpty else { return }
        dispatch(path: path, target: target)
    }

    private func dispatch(path: String, target: String) {
        perform { try await self.openPath(path, target: target) }
    }

    private func openPath(_ path: String, target: String) async throws {
        _ = try await backend.request("dispatch", params: ["target": .text(target), "path": .text(path)])
        if options.demo {
            notice = "Demo only: opened \(PathDisplay.abbreviate(path, home: "/Users/demo")) → \(Self.targetLabel(target)). No Rex call."
        } else { close() }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy, !closed else { return }
        busy = true; error = nil; splitMode = false
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            do { try await operation() }
            catch { if !self.closed { self.error = error.localizedDescription } }
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
