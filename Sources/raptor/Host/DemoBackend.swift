import Foundation

// Synthetic data only. This type never creates a Process or accesses the file system.
actor DemoBackend: BackendClient {
    private var worktrees = [
        PickerItem(path: "/Users/demo/Projects/example-kit", branch: "main", isMain: true, state: "blocked", working: true, updatedAt: ISO8601DateFormatter().string(from: Date())),
        PickerItem(path: "/Users/demo/Projects/example-kit-worktrees/native-picker", branch: "feat/native-picker", isMain: false, state: "working", working: true, updatedAt: ISO8601DateFormatter().string(from: Date())),
        PickerItem(path: "/Users/demo/Projects/example-kit-worktrees/fix-focus", branch: "fix/focus", isMain: false, state: "idle", working: false, updatedAt: ISO8601DateFormatter().string(from: Date()))
    ]
    private var pinned: Set<String> = ["/Users/demo/Workspace/Projects/raptor"]
    private var contextUpdates = 0
    private var calls: [String] = []
    private var lastParams: [String: [String: APIValue]] = [:]
    private let agents = [
        PickerItem(path: "agent:demo-1", label: "Native Agents view", kind: "agent", sessionID: "session:demo-1", sessionLabel: "dotfiles", app: "Pi", state: "working", updatedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-120)), agentID: "pi-1", windowID: "window:demo-1a", windowLabel: "picker", blockID: "block:demo-left", active: true),
        PickerItem(path: "agent:demo-2", label: "Backend API", kind: "agent", sessionID: "session:demo-1", sessionLabel: "dotfiles", app: "Codex", state: "blocked", updatedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20)), windowID: "window:demo-1a", windowLabel: "picker", blockID: "block:demo-right"),
        PickerItem(path: "agent:demo-3", label: "Review tests", kind: "agent", sessionID: "session:demo-2", sessionLabel: "castty", app: "Claude", state: "idle", updatedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600)), windowID: "window:demo-2a", windowLabel: "research", blockID: "block:demo-review")
    ]
    private var sessionEntries: [PickerItem] = [
        PickerItem(path: "session:demo-1", label: "dotfiles", kind: "session", sessionID: "session:demo-1", sessionLabel: "dotfiles", state: "working", working: true, updatedAt: ISO8601DateFormatter().string(from: Date()), active: true, host: "This Mac"),
        PickerItem(path: "session:demo-2", label: "castty", kind: "session", sessionID: "session:demo-2", sessionLabel: "castty", state: "idle", working: false, updatedAt: ISO8601DateFormatter().string(from: Date()), host: "This Mac"),
        PickerItem(path: "session:demo-3", label: "demo-app", kind: "session", sessionID: "session:demo-3", sessionLabel: "demo-app", state: "blocked", working: false, updatedAt: ISO8601DateFormatter().string(from: Date()), host: "Demo Host")
    ]
    private let sessionHosts: [HostHeader] = [
        HostHeader(label: "This Mac", local: true, reachable: true, error: nil),
        HostHeader(label: "Demo Host", local: false, reachable: true, error: nil),
        HostHeader(label: "Offline Host", local: false, reachable: false, error: "ssh: host down")
    ]
    nonisolated func close() {}

    func count(_ method: String) -> Int { calls.filter { $0 == method }.count }

    func parameters(_ method: String) -> [String: APIValue] { lastParams[method] ?? [:] }

    var contextUpdateCount: Int { contextUpdates }

    func request(_ method: String, params: [String: APIValue]) async throws -> APIResult {
        calls.append(method)
        lastParams[method] = params
        try await Task.sleep(for: .milliseconds(70))
        func text(_ key: String) -> String { if case let .text(value) = params[key] { return value }; return "" }
        let targets = ["tab", "session", "here", "pane_right", "pane_below"]
        let repo = "/Users/demo/Projects/example-kit"
        let branches = ["main", "develop", "feat/native-picker", "fix/focus"]
        switch method {
        case "directories":
            let items = [repo, "/Users/demo/Projects/sample-console", "/Users/demo/Projects/demo-sandbox", "/Users/demo/Work/demo-studio", "/Users/demo/Work/sample-notes"]
                .filter { text("query").isEmpty || $0.localizedCaseInsensitiveContains(text("query")) }
                .map { path in
                    PickerItem(path: path, state: path == repo ? "blocked" : "working", working: true,
                               updatedAt: ISO8601DateFormatter().string(from: Date()), isPinned: pinned.contains(path))
                }
            let sorted = items.sorted { ($0.isPinned ?? false) && !($1.isPinned ?? false) }
            return APIResult(items: sorted, targets: targets, target: "tab")
        case "sessions":
            // The flat unified launcher, mirroring catalog.LauncherItems: live
            // sessions first (origin session on top), then directories per host
            // ("This Mac" first). Unreachable hosts contribute no rows but stay
            // in hosts so their error remains visible.
            let query = text("query")
            let localDirs: [PickerItem] = [
                PickerItem(path: "/Users/demo/.dotfiles", label: ".dotfiles", kind: "dir",
                           isPinned: pinned.contains("/Users/demo/.dotfiles"), host: "This Mac"),
                PickerItem(path: "/Users/demo/Workspace/Projects/raptor", label: "raptor", kind: "dir", state: "working", working: true,
                           isPinned: pinned.contains("/Users/demo/Workspace/Projects/raptor"), host: "This Mac"),
            ]
            let remoteDirs: [PickerItem] = [
                PickerItem(path: "/Volumes/Demo/Projects/demo-app", label: "demo-app", kind: "dir", host: "Demo Host"),
            ]
            let rows = sessionEntries + localDirs + remoteDirs
            let filtered = rows.filter {
                query.isEmpty || [$0.label ?? "", $0.sessionLabel ?? "", $0.path, $0.host ?? ""]
                    .contains { $0.localizedCaseInsensitiveContains(query) }
            }
            return APIResult(items: filtered, hosts: sessionHosts, targets: targets, target: "tab")
        case "agents":
            let query = text("query")
            let ordered = agents.sorted { lhs, rhs in
                let groups = AgentGroup.allCases
                let left = groups.firstIndex(of: lhs.agentGroup)!, right = groups.firstIndex(of: rhs.agentGroup)!
                if left != right { return left < right }
                return (lhs.updatedDate ?? .distantPast) > (rhs.updatedDate ?? .distantPast)
            }
            return APIResult(items: ordered.filter { item in
                query.isEmpty || [item.label, item.app, item.state, item.sessionLabel, item.windowLabel]
                    .compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(query) }
            })
        case "agents.jump":
            return APIResult()
        case "sessions.jump":
            return APIResult()
        case "sessions.create":
            return APIResult()
        case "sessions.close":
            sessionEntries.removeAll { $0.path == text("session_id") }
            return APIResult()
        case "sessions.delete.preview", "sessions.delete":
            let session = text("session_id")
            let token = "demo-delete:" + session
            let plan = APIResult(repo: repo, path: repo + "-worktrees/native-picker", branch: "feat/native-picker", deleteToken: token)
            if method == "sessions.delete.preview" { return plan }
            guard text("delete_token") == token else { throw APIError.message("Deletion plan changed. Start again.") }
            if session == "session:demo-2", case .flag(false) = params["force"] {
                var result = plan
                result.error = "Worktree has uncommitted changes. Normal deletion stopped."
                result.forceAvailable = true
                return result
            }
            sessionEntries.removeAll { $0.path == session }
            return APIResult(worktreeRemoved: true, branchRemoved: true, sessionClosed: true)
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
            branches: branches, baseBranch: "main", suggestedBranch: "amber-falcon")
        case "worktrees.branches":
            return APIResult(branches: branches.filter { text("query").isEmpty || $0.localizedCaseInsensitiveContains(text("query")) })
        case "worktrees.preview":
            let branch = text("branch")
            return APIResult(path: "/Users/demo/Projects/example-kit-worktrees/" + branch.replacingOccurrences(of: "/", with: "-"),
                             validationError: branch.isEmpty ? "Enter a branch name." : nil)
        case "worktrees.create":
            let path = "/Users/demo/Projects/example-kit-worktrees/" + text("branch").replacingOccurrences(of: "/", with: "-")
            worktrees.append(PickerItem(path: path, branch: text("branch"), isMain: false, state: "idle", working: false,
                                       updatedAt: ISO8601DateFormatter().string(from: Date())))
            return APIResult(path: path)
        case "worktrees.remove":
            worktrees.removeAll { $0.path == text("path") && $0.isMain != true }
            return APIResult()
        case "pullrequests.resolve", "pullrequests.prepare":
            let input = text("input")
            let number = Int(input) ?? Int(input.split(separator: "/").last ?? "") ?? 123
            return APIResult(repo: repo, path: "/Users/demo/workspace/worktrees/example-kit/feat-native-picker",
                             input: input, url: "https://github.com/demo/example-kit/pull/\(number)", number: number,
                             title: "Add native pull request workflow", branch: "feat/native-picker",
                             cloneRequired: false, existing: false)
        case "pullrequests.open":
            return APIResult(path: text("path"), sessionID: "session:demo-pr", windowID: "window:demo-pr", blockID: "block:demo-pr")
        case "dispatch":
            return APIResult() // No Rex call; the UI shows the synthetic result.
        default: throw APIError.message("Unknown demo method: \(method)")
        }
    }
}
