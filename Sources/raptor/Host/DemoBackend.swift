import Foundation

// Synthetic data only. This type never creates a Process or accesses the file system.
actor DemoBackend: BackendClient {
    private var worktrees = [
        PickerItem(path: "/Users/demo/Projects/example-kit", branch: "main", isMain: true, state: "blocked", working: true, updatedAt: ISO8601DateFormatter().string(from: Date())),
        PickerItem(path: "/Users/demo/Projects/example-kit-worktrees/native-picker", branch: "feat/native-picker", isMain: false, state: "working", working: true, updatedAt: ISO8601DateFormatter().string(from: Date())),
        PickerItem(path: "/Users/demo/Projects/example-kit-worktrees/fix-focus", branch: "fix/focus", isMain: false, state: "idle", working: false, updatedAt: ISO8601DateFormatter().string(from: Date()))
    ]
    private var pinned: Set<String> = ["/Users/demo/Workspace/Projects/raptor"]
    private var pinnedSessions: Set<String> = []
    private var pinSlots: [String: Int] = [:]
    private var contextUpdates = 0
    private var deletionReview: [DeletionWorktree] = []
    private var deletionPreparation: Set<String>?
    private var savedAgent = ""
    private var calls: [String] = []
    private var lastParams: [String: [String: APIValue]] = [:]
    private let agents = [
        PickerItem(path: "agent:demo-1", label: "Native Agents view", kind: "agent", sessionID: "session:demo-1", sessionLabel: "dotfiles", app: "Pi", state: "working", updatedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-120)), agentID: "pi-1", windowID: "window:demo-1a", windowLabel: "picker", blockID: "block:demo-left", active: true),
        PickerItem(path: "agent:demo-2", label: "Backend API", kind: "agent", sessionID: "session:demo-1", sessionLabel: "dotfiles", app: "Codex", state: "blocked", updatedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20)), windowID: "window:demo-1a", windowLabel: "picker", blockID: "block:demo-right"),
        PickerItem(path: "agent:demo-3", label: "Review tests", kind: "agent", sessionID: "session:demo-2", sessionLabel: "castty", app: "Claude", state: "idle", updatedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600)), windowID: "window:demo-2a", windowLabel: "research", blockID: "block:demo-review", unreadDone: true)
    ]
    private var sessionEntries: [PickerItem] = [
        PickerItem(path: "session:demo-1", label: "dotfiles", kind: "session", sessionID: "session:demo-1", sessionLabel: "dotfiles", state: "working", working: true, updatedAt: ISO8601DateFormatter().string(from: Date()), active: true, isLocal: true, host: "This Mac"),
        PickerItem(path: "session:demo-2", label: "castty", kind: "session", sessionID: "session:demo-2", sessionLabel: "castty", state: "idle", working: false, updatedAt: ISO8601DateFormatter().string(from: Date()), isLocal: true, host: "This Mac", unreadDone: true),
        PickerItem(path: "session:demo-3", label: "demo-app", kind: "session", sessionID: "session:demo-3", sessionLabel: "demo-app", state: "blocked", working: false, updatedAt: ISO8601DateFormatter().string(from: Date()), isLocal: false, host: "Demo Host")
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
        let targets = ["session", "tab", "here", "pane_right", "pane_below"]
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
            return APIResult(items: sorted, targets: targets, target: "session")
        case "sessions":
            // The flat unified launcher: pinned rows first, then the origin,
            // other sessions, and directories per host
            // ("This Mac" first). Unreachable hosts contribute no rows but stay
            // in hosts so their error remains visible.
            let query = text("query")
            let localDirs: [PickerItem] = [
                PickerItem(path: "/Users/demo/.dotfiles", label: ".dotfiles", kind: "dir",
                           isLocal: true, isPinned: pinned.contains("/Users/demo/.dotfiles"), host: "This Mac"),
                PickerItem(path: "/Users/demo/Workspace/Projects/raptor", label: "raptor", kind: "dir", state: "working", working: true,
                           isLocal: true, isPinned: pinned.contains("/Users/demo/Workspace/Projects/raptor"), host: "This Mac"),
            ]
            let remoteDirs: [PickerItem] = [
                PickerItem(path: "/Volumes/Demo/Projects/demo-app", label: "demo-app", kind: "dir", isLocal: false, host: "Demo Host"),
            ]
            let sessions = sessionEntries.map { item in
                var item = item
                let key = (item.host ?? "") + "\u{0}" + (item.sessionID ?? "")
                item.isPinned = pinnedSessions.contains(key)
                item.pinSlot = pinSlots[key]
                return item
            }
            let rows = sessions + localDirs + remoteDirs
            let filtered = rows.filter {
                query.isEmpty || [$0.label ?? "", $0.sessionLabel ?? "", $0.path, $0.host ?? ""]
                    .contains { $0.localizedCaseInsensitiveContains(query) }
            }
            let ordered = filtered.filter { $0.isPinned == true } + filtered.filter { $0.isPinned != true }
            return APIResult(items: ordered, hosts: sessionHosts, targets: targets, target: "session")
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
        case "pins.toggle":
            if !text("session_id").isEmpty {
                let key = text("host") + "\u{0}" + text("session_id")
                if pinnedSessions.contains(key) {
                    pinnedSessions.remove(key)
                    pinSlots.removeValue(forKey: key)
                } else {
                    pinnedSessions.insert(key)
                    pinSlots[key] = (1...9).first { !pinSlots.values.contains($0) }
                }
                return APIResult(pinned: pinnedSessions.contains(key))
            } else {
                if pinned.contains(text("path")) { pinned.remove(text("path")) } else { pinned.insert(text("path")) }
                return APIResult(pinned: pinned.contains(text("path")))
            }
        case "context":
            contextUpdates += 1
            return APIResult()
        case "worktrees.list", "worktrees.form":
            if text("repo").isEmpty { return APIResult(needsRepo: true) }
            return APIResult(items: method == "worktrees.form" ? [] : worktrees.filter {
                text("query").isEmpty || $0.path.localizedCaseInsensitiveContains(text("query")) || ($0.branch ?? "").localizedCaseInsensitiveContains(text("query"))
            }, targets: targets, target: "session", repo: repo, destinationRoot: "/Users/demo/Projects/example-kit-worktrees", needsRepo: false,
            branches: branches, baseBranch: "main", suggestedBranch: "amber-falcon",
            agent: "pi", agentModel: "glm-5.3", agentReasoning: "high", agents: ["pi", "codex"])
        case "agents.catalog":
            let agent = text("agent")
            let models: [AgentModelPayload]
            if agent == "codex" {
                models = [AgentModelPayload(id: "gpt-6-luna", label: "GPT-6 Luna", reasoning: ["low", "high", "xhigh"], defaultReasoning: "high", isDefault: true)]
            } else {
                models = [AgentModelPayload(id: "glm-5.3", provider: "zai", label: "GLM-5.3", reasoning: ["low", "high", "max"], defaultReasoning: "high", isDefault: true),
                          AgentModelPayload(id: "gpt-6.1-sol", provider: "openai-codex", label: "GPT-6.1 Sol", reasoning: ["medium", "high", "xhigh"])]
            }
            return APIResult(agent: agent, agentModels: models)
        case "worktrees.branches":
            return APIResult(branches: branches.filter { text("query").isEmpty || $0.localizedCaseInsensitiveContains(text("query")) })
        case "sessions.delete.preview":
            deletionPreparation = nil
            deletionReview = deletionRows(repo: repo, session: text("session_id"))
            if case .flag(true) = params["discover_only"] {
                deletionReview = deletionReview.map { DeletionWorktree(path: $0.path, checked: false, prepared: false) }
            }
            return APIResult(deleteToken: "demo-review", worktrees: deletionReview)
        case "sessions.delete.check":
            guard text("delete_token") == "demo-review",
                  let index = deletionReview.firstIndex(where: { $0.path == text("path") }),
                  var row = deletionRows(repo: repo, session: text("session_id")).first(where: { $0.path == text("path") }) else {
                throw APIError.message("Worktree review changed. Refresh the review.")
            }
            if case .flag(true) = params["metadata_only"] { row.prepared = false; row.needsForce = nil }
            deletionReview[index] = row
            return APIResult(deleteToken: "demo-review", worktrees: deletionReview)
        case "sessions.delete.prepare":
            let requested: [String]
            if case .texts(let values) = params["paths"] { requested = values }
            else { requested = [text("path")] }
            guard text("delete_token") == "demo-review", deletionReview.allSatisfy(\.isChecked),
                  case .texts(let paths) = params["selected_paths"], !paths.isEmpty,
                  deletionPreparation == nil || deletionPreparation == Set(paths),
                  !requested.isEmpty, requested.count <= 2, Set(requested).count == requested.count,
                  requested.first == text("path"), Set(requested).isSubset(of: Set(paths)),
                  paths.allSatisfy({ path in deletionReview.contains { $0.path == path && $0.deletable } }) else {
                throw APIError.message("Refresh the worktree review.")
            }
            deletionPreparation = Set(paths)
            for path in requested {
                guard let index = deletionReview.firstIndex(where: { $0.path == path }),
                      let row = deletionRows(repo: repo, session: text("session_id")).first(where: { $0.path == path }) else {
                    throw APIError.message("Refresh the worktree review.")
                }
                deletionReview[index] = row
            }
            return APIResult(deleteToken: "demo-review", worktrees: deletionReview)
        case "sessions.delete":
            guard case .flag(true) = params["review_worktrees"], case .flag(true) = params["close_session"],
                  case .texts(let paths) = params["selected_paths"], !paths.isEmpty,
                  text("delete_token") == "demo-review", deletionReview.allSatisfy(\.isChecked),
                  deletionPreparation == nil || Set(paths).isSubset(of: deletionPreparation ?? []),
                  paths.allSatisfy({ path in deletionReview.contains { $0.path == path && $0.deletable && $0.isPrepared } }) else {
                throw APIError.message("Select worktrees and confirm closing the session.")
            }
            if case .flag(false) = params["force"], deletionRows(repo: repo, session: text("session_id"))
                .contains(where: { paths.contains($0.path) && $0.needsForce == true }) {
                return APIResult(error: "Worktree has uncommitted changes. Normal deletion stopped.", deleteToken: "demo-review", forceAvailable: true,
                                 worktrees: deletionReview)
            }
            worktrees.removeAll { paths.contains($0.path) }
            sessionEntries.removeAll { $0.sessionID == text("session_id") }
            return APIResult(worktreeRemoved: true, branchRemoved: true, sessionClosed: true, deletedPaths: paths)
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
        case "config.saveAgent":
            savedAgent = text("agent")
            return APIResult()
        case "dispatch":
            return APIResult() // No Rex call; the UI shows the synthetic result.
        default: throw APIError.message("Unknown demo method: \(method)")
        }
    }

    private func deletionRows(repo: String, session: String) -> [DeletionWorktree] {
        worktrees.map { item in
            DeletionWorktree(repo: repo, path: item.path, branch: item.branch ?? "",
                             error: item.isMain == true ? "Cannot delete branch `\(item.branch ?? "")`." : nil,
                             isPrimary: item.isMain,
                             needsForce: session == "session:demo-2" && item.branch == "feat/native-picker", checked: true, prepared: true)
        }
    }
}
