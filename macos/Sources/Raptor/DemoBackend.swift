import Foundation

// Synthetic data only. This type never creates a Process or accesses the file system.
actor DemoBackend: BackendClient {
    private var worktrees = [
        PickerItem(path: "/Users/demo/Projects/example-kit", branch: "main", isMain: true),
        PickerItem(path: "/Users/demo/Projects/example-kit-worktrees/native-picker", branch: "feat/native-picker", isMain: false),
        PickerItem(path: "/Users/demo/Projects/example-kit-worktrees/fix-focus", branch: "fix/focus", isMain: false)
    ]
    private var pinned: Set<String> = []
    private var contextUpdates = 0
    private var calls: [String] = []
    private var sessionEntries: [PickerItem] = [
        PickerItem(path: "session:demo-1", label: "dotfiles", kind: "session", sessionID: "session:demo-1", sessionLabel: "dotfiles", active: true),
        PickerItem(path: "window:demo-1a", label: "dotfiles shell", kind: "window", sessionID: "session:demo-1", sessionLabel: "dotfiles", active: true),
        PickerItem(path: "window:demo-1b", label: "build", kind: "window", sessionID: "session:demo-1", sessionLabel: "dotfiles", active: false),
        PickerItem(path: "session:demo-2", label: "castty", kind: "session", sessionID: "session:demo-2", sessionLabel: "castty", active: false),
        PickerItem(path: "window:demo-2a", label: "research", kind: "window", sessionID: "session:demo-2", sessionLabel: "castty", active: true)
    ]
    nonisolated func close() {}

    func count(_ method: String) -> Int { calls.filter { $0 == method }.count }

    var contextUpdateCount: Int { contextUpdates }

    func request(_ method: String, params: [String: APIValue]) async throws -> APIResult {
        calls.append(method)
        try await Task.sleep(for: .milliseconds(70))
        func text(_ key: String) -> String { if case let .text(value) = params[key] { return value }; return "" }
        let targets = ["tab", "session", "here", "pane_right", "pane_below"]
        let repo = "/Users/demo/Projects/example-kit"
        let branches = ["main", "develop", "feat/native-picker", "fix/focus"]
        switch method {
        case "directories":
            let items = [repo, "/Users/demo/Projects/sample-console", "/Users/demo/Projects/demo-sandbox", "/Users/demo/Work/demo-studio", "/Users/demo/Work/sample-notes"]
                .filter { text("query").isEmpty || $0.localizedCaseInsensitiveContains(text("query")) }
                .map { PickerItem(path: $0, isPinned: pinned.contains($0)) }
            let sorted = items.sorted { ($0.isPinned ?? false) && !($1.isPinned ?? false) }
            return APIResult(items: sorted, targets: targets, target: "tab")
        case "sessions":
            let query = text("query")
            return APIResult(items: sessionEntries.filter {
                query.isEmpty || ($0.label ?? "").localizedCaseInsensitiveContains(query) || ($0.sessionLabel ?? "").localizedCaseInsensitiveContains(query)
            }, targets: [], target: "tab")
        case "sessions.jump":
            return APIResult()
        case "sessions.close":
            sessionEntries.removeAll { $0.path == text("window_id") || $0.path == text("session_id") && text("kind") == "session" }
            return APIResult()
        case "sessions.rename":
            for index in sessionEntries.indices where sessionEntries[index].path == (text("kind") == "window" ? text("window_id") : text("session_id")) {
                sessionEntries[index].label = text("label")
            }
            return APIResult()
        case "pins.toggle":
            if pinned.contains(text("path")) { pinned.remove(text("path")) } else { pinned.insert(text("path")) }
            return APIResult()
        case "context":
            contextUpdates += 1
            return APIResult()
        case "worktrees.list":
            if text("repo").isEmpty { return APIResult(needsRepo: true) }
            return APIResult(items: worktrees.filter {
                text("query").isEmpty || $0.path.localizedCaseInsensitiveContains(text("query")) || ($0.branch ?? "").localizedCaseInsensitiveContains(text("query"))
            }, targets: targets, target: "tab", repo: repo, destinationRoot: "/Users/demo/Projects/example-kit-worktrees", needsRepo: false,
            branches: branches, baseBranch: "main")
        case "worktrees.branches":
            return APIResult(branches: branches.filter { text("query").isEmpty || $0.localizedCaseInsensitiveContains(text("query")) })
        case "worktrees.preview":
            let branch = text("branch")
            return APIResult(path: "/Users/demo/Projects/example-kit-worktrees/" + branch.replacingOccurrences(of: "/", with: "-"),
                             validationError: branch.isEmpty ? "Enter a branch name." : nil)
        case "worktrees.create":
            let path = "/Users/demo/Projects/example-kit-worktrees/" + text("branch").replacingOccurrences(of: "/", with: "-")
            worktrees.append(PickerItem(path: path, branch: text("branch"), isMain: false))
            return APIResult(path: path)
        case "worktrees.remove":
            worktrees.removeAll { $0.path == text("path") && $0.isMain != true }
            return APIResult()
        case "dispatch":
            return APIResult() // No Rex call; the UI shows the synthetic result.
        default: throw APIError.message("Unknown demo method: \(method)")
        }
    }
}
