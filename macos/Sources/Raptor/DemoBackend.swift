import Foundation

// Synthetic data only. This type never creates a Process or accesses the file system.
actor DemoBackend: BackendClient {
    private var worktrees = [
        PickerItem(path: "/Users/demo/Projects/example-kit", branch: "main", isMain: true),
        PickerItem(path: "/Users/demo/Projects/example-kit-worktrees/native-picker", branch: "feat/native-picker", isMain: false),
        PickerItem(path: "/Users/demo/Projects/example-kit-worktrees/fix-focus", branch: "fix/focus", isMain: false)
    ]
    nonisolated func close() {}

    func request(_ method: String, params: [String: APIValue]) async throws -> APIResult {
        try await Task.sleep(for: .milliseconds(70))
        func text(_ key: String) -> String { if case let .text(value) = params[key] { return value }; return "" }
        let targets = ["tab", "here", "session", "pane", "pane_left", "pane_above", "pane_below"]
        let repo = "/Users/demo/Projects/example-kit"
        let branches = ["main", "develop", "feat/native-picker", "fix/focus"]
        switch method {
        case "directories":
            let items = [repo, "/Users/demo/Projects/sample-console", "/Users/demo/Projects/demo-sandbox", "/Users/demo/Work/demo-studio", "/Users/demo/Work/sample-notes"]
                .filter { text("query").isEmpty || $0.localizedCaseInsensitiveContains(text("query")) }
                .map { PickerItem(path: $0) }
            return APIResult(items: items, targets: targets, target: "tab")
        case "worktrees.list":
            if text("repo").isEmpty { return APIResult(needsRepo: true) }
            return APIResult(items: worktrees.filter {
                text("query").isEmpty || $0.path.localizedCaseInsensitiveContains(text("query")) || ($0.branch ?? "").localizedCaseInsensitiveContains(text("query"))
            }, targets: targets, target: "tab", repo: repo, needsRepo: false,
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
