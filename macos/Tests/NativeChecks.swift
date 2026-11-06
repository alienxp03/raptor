import Foundation
import AppKit
import SwiftUI

// Standalone headless checks. Compile with Backend, DemoBackend and PickerModel,
// not RaptorApp. No NSApplication, panel, Rex call or live file operation.
private actor ScriptedBackend: BackendClient {
    private var calls: [String] = []
    nonisolated func close() {}
    func count(_ method: String) -> Int { calls.filter { $0 == method }.count }
    func request(_ method: String, params: [String: APIValue]) async throws -> APIResult {
        calls.append(method)
        if method == "directories" {
            var query = ""
            if case let .text(value) = params["query"] { query = value }
            // The first response arrives after the second response.
            await delay(query == "old" ? 0.45 : 0.02)
            return APIResult(items: [PickerItem(path: "/demo/" + query)], targets: ["tab", "session"], target: "tab")
        }
        if method == "worktrees.list" {
            return APIResult(items: [PickerItem(path: "/demo/tree", branch: "main", isMain: true)], targets: ["tab"], target: "tab", repo: "/demo", branches: ["main"], baseBranch: "main")
        }
        if method == "worktrees.preview" {
            var branch = ""
            if case let .text(value) = params["branch"] { branch = value }
            await delay(branch == "old" ? 0.45 : 0.02)
            return APIResult(path: "/demo/" + branch, validationError: "")
        }
        return APIResult()
    }
    // Pipe requests cannot be recalled once written; simulate that here.
    private func delay(_ seconds: Double) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }
}

private actor CreateThenOpenBackend: BackendClient {
    private var creates = 0
    private var opens = 0
    private var openedTargets: [String] = []
    nonisolated func close() {}
    func counts() -> (Int, Int) { (creates, opens) }
    func targets() -> [String] { openedTargets }
    func request(_ method: String, params: [String: APIValue]) async throws -> APIResult {
        switch method {
        case "worktrees.list":
            return APIResult(items: [], targets: ["tab", "session"], target: "tab", repo: "/demo", branches: ["main"], baseBranch: "main")
        case "worktrees.preview": return APIResult(path: "/demo/new-worktree", validationError: "")
        case "worktrees.branches":
            guard case .text("backend-order") = params["query"] else { throw APIError.message("Query not sent to Go") }
            return APIResult(branches: ["zeta", "alpha"])
        case "worktrees.create": creates += 1; return APIResult(path: "/demo/new-worktree")
        case "dispatch":
            opens += 1
            if case let .text(target) = params["target"] { openedTargets.append(target) }
            if opens == 1 { throw APIError.message("Client could not switch") }
            return APIResult()
        default: return APIResult()
        }
    }
}

private actor DelayedMetadataBackend: BackendClient {
    private var calls: [String] = []
    private var origin: String?
    nonisolated func close() {}
    func methods() -> [String] { calls }
    func requestedRepo() -> String? { origin }
    func request(_ method: String, params: [String: APIValue]) async throws -> APIResult {
        calls.append(method)
        if method == "worktrees.list" {
            if case let .text(value) = params["repo"] { origin = value }
            // Simulate a pipe response that cannot be recalled on cancellation.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { continuation.resume() }
            }
            return APIResult(items: [PickerItem(path: "/resolved", branch: "main")],
                             targets: ["tab", "session", "here", "pane_right", "pane_below"],
                             target: "tab", repo: "/resolved", branches: ["main"], baseBranch: "main")
        }
        if method == "worktrees.preview" {
            guard case .text("feat/typed-early") = params["branch"],
                  case .text("/resolved") = params["repo"],
                  case .text("main") = params["base"] else {
                preconditionFailure("Preview ran before metadata or lost entered branch")
            }
            return APIResult(path: "/resolved-worktrees/typed", validationError: "")
        }
        return APIResult()
    }
}

private actor SlowDirectoryBackend: BackendClient {
    nonisolated func close() {}
    func request(_ method: String, params: [String: APIValue]) async throws -> APIResult {
        try await Task.sleep(for: .milliseconds(100))
        return APIResult(items: (0..<30).map { PickerItem(path: "/demo/\($0)") }, targets: ["tab"], target: "tab")
    }
}

// Explicit replies simulate pipe calls that finish even after task cancellation.
private actor CachedListBackend: BackendClient {
    private var pending: [String: [CheckedContinuation<APIResult, Error>]] = [:]
    private var calls: [String] = []
    private var lastParams: [String: [String: APIValue]] = [:]
    func parameters(_ method: String) -> [String: APIValue] { lastParams[method] ?? [:] }
    private var held: Set<String> = []
    func hold(_ method: String) { held.insert(method) }
    nonisolated func close() {}
    func count(_ method: String) -> Int { calls.filter { $0 == method }.count }
    func waiting(_ method: String) -> Bool { !(pending[method] ?? []).isEmpty }
    func reply(_ method: String, _ result: APIResult) {
        pending[method]!.removeFirst().resume(returning: result)
    }
    func fail(_ method: String) {
        pending[method]!.removeFirst().resume(throwing: APIError.message("Refresh failed"))
    }
    func request(_ method: String, params: [String: APIValue]) async throws -> APIResult {
        calls.append(method)
        lastParams[method] = params
        if ["directories", "sessions", "agents", "worktrees.list"].contains(method) || held.contains(method) {
            return try await withCheckedThrowingContinuation { pending[method, default: []].append($0) }
        }
        return APIResult()
    }
}

@main
struct NativeChecks {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--theme-integration") {
            try await themeIntegrationChecks()
            return
        }
        precondition(PickerStyle.panelAnimationBehavior(reduceMotion: false) == .default,
                     "Panel presentation must use resh's default AppKit animation")
        precondition(PickerStyle.panelAnimationBehavior(reduceMotion: true) == .none,
                     "Reduced Motion must disable panel presentation animation")
        let options = try LaunchOptions(arguments: ["--demo", "--mode", "wt", "--repo", "/demo", "--session", "S", "--block", "B", "--client", "C", "--title", "A title"])
        precondition(options.backendArguments == ["--session", "S", "--block", "B", "--client", "C", "--title", "A title", "api"])
        do {
            _ = try LaunchOptions(arguments: ["--mode", "sessions"])
            preconditionFailure("Invalid mode accepted")
        } catch {}
        do {
            _ = try LaunchOptions(arguments: ["--repo"])
            preconditionFailure("Missing argument accepted")
        } catch {}
        for mode in ["WT-CREATE", "wt-create-extra", "wt-create ", "AGENTS", "agents-extra", "agents ", ""] {
            do {
                _ = try LaunchOptions(arguments: ["--mode", mode])
                preconditionFailure("Invalid create mode accepted")
            } catch {}
        }
        let screen = CGRect(x: -1200, y: 200, width: 1200, height: 800)
        let frame = PickerStyle.panelFrame(in: screen, height: 220)
        let taller = PickerStyle.panelFrame(in: screen, height: 400)
        precondition(frame.midX == screen.midX && frame.maxY == screen.maxY - 72,
                     "Picker must anchor below the top of the active screen")
        precondition(taller.maxY == frame.maxY, "Content growth must preserve the top anchor")
        let decoded = try JSONDecoder().decode(APIResult.self, from: Data("{\"needs_repo\":false,\"base_branch\":\"main\",\"items\":[{\"path\":\"/a\",\"branch\":\"main\",\"is_main\":true}]}".utf8))
        precondition(decoded.items?.first?.isMain == true && decoded.baseBranch == "main")

        precondition(PickerStyle.rowFontSize == 13 && PickerStyle.rowHeight == 32 && PickerStyle.createHeaderHeight == PickerStyle.searchHeight,
                     "Launcher and form must share typography and control sizing")
        precondition(PickerModel.targetLabel("tab") == "New tab")
        precondition(PickerModel.targetLabel("session") == "Session")
        precondition(PickerModel.targetLabel("here") == "cd here")
        let launcher = PickerModel(options: try LaunchOptions(arguments: ["--demo"]), backend: SlowDirectoryBackend())
        let initialListHeight = PickerStyle.height(for: launcher)
        precondition(launcher.loading && initialListHeight == 372,
                     "Launcher must reserve eight compact rows plus the pills row before its first render")
        launcher.start()
        precondition(PickerStyle.height(for: launcher) == initialListHeight && !launcher.canOpen)
        try await wait { !launcher.loading }
        precondition(launcher.items.count == 30 && PickerStyle.height(for: launcher) == initialListHeight,
                     "Populated launcher must not jump from a search-sized window to a list")
        launcher.close()

        let backend = DemoBackend()
        let model = PickerModel(options: options, backend: backend)
        model.start()
        try await wait { !model.loading }
        precondition(model.page == .worktrees && model.items.count == 3)
        precondition(model.destinationRoot == "/Users/demo/Projects/example-kit-worktrees",
                     "Default destination must come from shared backend before branch input")
        precondition(PickerStyle.width == 640 && PickerStyle.height(for: model) == 232,
                     "The picker must use a wider layout with compact, content-fitted height")
        precondition(PickerStyle.rowHeight == 32 && PickerStyle.worktreeRowHeight == 28,
                     "Directory and worktree rows must keep Rex spacing")
        model.askRemove()
        precondition(model.removalCandidate == nil, "Main worktree must not be removable")
        model.move(1)
        model.askRemove()
        precondition(model.removalCandidate != nil)
        model.escape()
        precondition(model.removalCandidate != nil && model.page == .worktrees, "Esc must not navigate behind confirmation")
        let candidate = model.removalCandidate!
        model.removalCandidate = nil // SwiftUI can reset its presentation binding first.
        model.confirmRemove(candidate)
        model.confirmRemove(candidate) // Busy guard blocks repeated submission.
        try await wait { !model.busy && !model.loading }
        precondition(model.items.count == 2)
        model.beginCreate()
        precondition(PickerStyle.height(for: model) == 240, "Creation form grew beyond the compact layout")
        model.branch = "feat/test"
        try await wait { model.previewReady }
        precondition(model.canCreate && model.destination == "/Users/demo/Projects/example-kit-worktrees/feat-test")
        model.create()
        model.create()
        try await wait { !model.busy }
        precondition(model.createdPath != nil && model.notice?.contains("No Rex call") == true,
                     "Create must also open without a second click")
        model.escape()
        try await wait { !model.loading }
        precondition(model.page == .worktrees && model.items.count == 3, "Ordinary create must return to the list without repeated creation")
        model.toggleSplit()
        precondition(model.splitMode)
        model.escape()
        precondition(!model.splitMode && model.page == .worktrees)
        let previousTarget = model.target
        model.cycleTarget(backward: false)
        model.cycleTarget(backward: true)
        precondition(model.target == previousTarget)
        model.close()

        let compactList = PickerModel(options: options, backend: DemoBackend())
        compactList.items = (0..<8).map { PickerItem(path: "/demo/\($0)", branch: "feat/\($0)") }
        let eightRowHeight = PickerStyle.height(for: compactList)
        compactList.items = (0..<30).map { PickerItem(path: "/demo/\($0)", branch: "feat/\($0)") }
        precondition(PickerStyle.height(for: compactList) == eightRowHeight && eightRowHeight == 372,
                     "Lists must stop growing after eight compact rows")
        let longBranch = PickerItem(path: "/demo/long", branch: "feat/" + String(repeating: "long-name-", count: 15))
        precondition(PickerStyle.branchLines(for: longBranch) == 2,
                     "Selected long branch names must wrap instead of sharing width with paths")
        compactList.items[0] = longBranch
        compactList.selectedID = longBranch.id
        precondition(PickerStyle.height(for: compactList) == eightRowHeight + PickerStyle.worktreeRowHeight,
                     "A wrapped selected branch needs one extra row without hiding the path detail")
        compactList.close()

        try await directCreateChecks()
        try await suggestedBranchChecks()
        try await residentChecks()
        try launcherEscapeChecks()
        try await agentsChecks()
        try await directAgentsChecks()
        try await stableAgentsChecks()
        try await groupedActivityChecks()
        try await cachedListChecks()
        try await warmReopenChecks()
        try nativeThemeRoleChecks()
        try await themeRefreshChecks()
        try await dismissalChecks()
        let directoryCreate = PickerModel(options: try LaunchOptions(arguments: ["--demo"]), backend: DemoBackend())
        directoryCreate.start()
        try await wait { !directoryCreate.loading }
        let selectedRepo = directoryCreate.selected?.path
        directoryCreate.beginCreate()
        precondition(directoryCreate.page == .create && directoryCreate.loading && directoryCreate.repo == selectedRepo,
                     "New from directories must open Create directly for the selected repository")
        try await wait { !directoryCreate.loading }
        directoryCreate.escape()
        try await wait { !directoryCreate.loading }
        precondition(directoryCreate.page == .directories, "Create opened from directories must return there")
        directoryCreate.close()

        let fallback = PickerModel(options: try LaunchOptions(arguments: ["--demo", "--mode", "wt"]), backend: DemoBackend())
        fallback.start()
        try await wait { !fallback.loading }
        precondition(fallback.page == .repositories && !fallback.items.isEmpty)
        fallback.choose()
        try await wait { !fallback.loading }
        precondition(fallback.page == .worktrees && fallback.repo != nil)
        fallback.close()

        let scripted = ScriptedBackend()
        let stale = PickerModel(options: try LaunchOptions(arguments: ["--demo"]), backend: scripted)
        stale.start()
        try await wait { !stale.loading }
        stale.query = "old"
        try await Task.sleep(for: .milliseconds(190))
        stale.query = "new"
        try await wait { !stale.loading }
        try await Task.sleep(for: .milliseconds(350))
        precondition(stale.items.first?.path == "/demo/new", "Stale query replaced current results")
        precondition(PickerStyle.height(for: stale) == 180, "Filtered results must shrink the panel")
        stale.choose(); stale.choose()
        try await wait { !stale.busy }
        let dispatches = await scripted.count("dispatch")
        precondition(dispatches == 1, "Repeated Enter submitted twice")
        stale.close()

        let previewBackend = ScriptedBackend()
        let preview = PickerModel(options: options, backend: previewBackend)
        preview.start()
        try await wait { !preview.loading }
        preview.beginCreate()
        try await Task.sleep(for: .milliseconds(250))
        let blankPreviews = await previewBackend.count("worktrees.preview")
        precondition(!preview.previewReady && preview.validationError == nil && blankPreviews == 0,
                     "An untouched branch field must not show premature validation")
        preview.branch = "old"
        try await Task.sleep(for: .milliseconds(220))
        preview.branch = "new"
        try await wait { preview.previewReady }
        try await Task.sleep(for: .milliseconds(350))
        precondition(preview.destination == "/demo/new" && preview.validationError == nil && preview.canCreate, "Stale preview or empty validation error blocked creation")
        preview.close()

        let retryBackend = CreateThenOpenBackend()
        let retry = PickerModel(options: try LaunchOptions(arguments: ["--demo", "--mode", "wt-create", "--repo", "/demo"]), backend: retryBackend)
        retry.start()
        try await wait { !retry.loading }
        precondition(retry.page == .create && !retry.loading)
        let baseMatches = try await retry.searchBaseBranches("backend-order")
        precondition(baseMatches == ["zeta", "alpha"], "Branch search must preserve the backend's matching and order")
        retry.branch = "feat/demo"
        try await wait { retry.canCreate }
        retry.basePickerPresented = true
        retry.create()
        let modalCounts = await retryBackend.counts()
        precondition(modalCounts.0 == 0 && modalCounts.1 == 0 && !retry.canSubmitForm,
                     "The branch popover must not submit the form beneath it")
        retry.escape()
        precondition(!retry.basePickerPresented && retry.page == .create && retry.branch == "feat/demo",
                     "Escape must dismiss the branch popover without discarding the form")
        retry.submitBranch(); retry.submitBranch()
        try await wait { !retry.busy }
        let firstCounts = await retryBackend.counts()
        precondition(firstCounts.0 == 1 && firstCounts.1 == 1 && retry.createdPath == "/demo/new-worktree")
        precondition(retry.error?.contains("Worktree created, but opening failed") == true && retry.canSubmitForm && !retry.canCreate)
        retry.cycleTarget(backward: false)
        retry.submitBranch(); retry.submitBranch() // Retry the open step only, even after repeated submission.
        try await wait { !retry.busy }
        let retriedCounts = await retryBackend.counts()
        let openedTargets = await retryBackend.targets()
        precondition(retriedCounts.0 == 1 && retriedCounts.1 == 2 && openedTargets == ["tab", "session"],
                     "A failed open retried creation or ignored the newly selected target")
        precondition(retry.error == nil && retry.notice?.contains("No Rex call") == true)
        retry.close()

        // Optional transport fixture exists only inside an aux test .app bundle.
        if CommandLine.arguments.contains("--transport-fixture") {
            try await transportChecks()
        }
        print("PASS: launch flags, decoding, repository fallback, query generations, selection, target cycle, split cancel, confirmation, main protection, create-and-open, retry without recreation, untouched validation, backend branch search, popover isolation, duplicate submission")
    }

    @MainActor private static func groupedActivityChecks() async throws {
        let json = #"{"path":"a","kind":"agent","state":"working","updated_at":"2026-01-02T03:04:05.123Z","cwd":"/repo","working":false}"#
        var item = try JSONDecoder().decode(PickerItem.self, from: Data(json.utf8))
        precondition(item.cwd == "/repo" && item.updatedDate != nil && item.activity.working)
        let date = item.updatedDate!
        precondition(item.updatedAge(now: date.addingTimeInterval(-100)) == "now")
        precondition(item.updatedAge(now: date.addingTimeInterval(120)) == "2m")
        precondition(item.updatedAge(now: date.addingTimeInterval(3600)) == "1h")
        item.updatedAt = "2026-01-02T03:04:05Z"
        precondition(item.updatedDate != nil)
        item.updatedAt = nil
        precondition(item.updatedAge() == nil)
        let heartbeatOnly = try JSONDecoder().decode(PickerItem.self, from: Data(#"{"path":"legacy","metadata":{"heartbeat":"2026-01-02T03:04:05Z"}}"#.utf8))
        precondition(heartbeatOnly.updatedAge() == nil, "Never use metadata heartbeat as updated_at")
        item.updatedAt = "bad"
        precondition(item.updatedAge() == nil)
        for kind in ["session", "window", "directory"] {
            item.kind = kind; item.state = "blocked"; item.working = true
            precondition(item.activity == ActivityProjection(blocked: true, working: true))
            precondition(item.activityAccessibility == "Blocked, Working")
            precondition(item.activity.shouldPulse(reduceMotion: false, visible: true))
            precondition(!item.activity.shouldPulse(reduceMotion: true, visible: true))
            precondition(!item.activity.shouldPulse(reduceMotion: false, visible: false))
            item.working = false
            precondition(!item.activity.shouldPulse(reduceMotion: false, visible: true))
        }
        item.kind = "agent"; item.state = "idle"; item.working = true
        precondition(!item.activity.working, "Agent activity must derive only from state")

        let backend = CachedListBackend()
        let options = try LaunchOptions(arguments: ["--demo", "--mode", "agents"])
        let model = PickerModel(options: options, backend: backend)
        func row(_ id: String, _ state: String) -> PickerItem {
            PickerItem(path: id, label: id, kind: "agent", state: state)
        }
        let first = [row("b", "blocked"), row("w", "working"), row("i", "idle")]
        model.start()
        try await pending("agents", backend)
        await backend.reply("agents", APIResult(items: first))
        try await wait { !model.refreshing }
        precondition(model.agentSections.map(\.id) == ["Blocked", "Working", "Idle"])
        precondition(model.agentSections.flatMap(\.items).map { model.numberedPosition(of: $0) } == [1, 2, 3])
        let fullHeight = PickerStyle.height(for: model)
        model.selectView(.repos)
        try await pending("directories", backend)
        await backend.reply("directories", APIResult(items: []))
        try await wait { !model.refreshing }
        model.selectView(.agents)
        try await pending("agents", backend)
        let fresh = [row("new", "blocked"), row("i", "blocked"), row("w", "working"), row("b", "idle")]
        await backend.reply("agents", APIResult(items: fresh))
        try await wait { !model.refreshing }
        precondition(model.items.map(\.id) == ["b", "w", "i"])
        precondition(model.items[0].state == "idle", "Live activity changes in place")
        precondition(model.agentSections.map(\.id) == ["Blocked", "Working", "Idle"])
        precondition(model.agentSections[0].items.map(\.id) == ["b"], "Snapshot membership stays fixed")
        precondition(PickerStyle.height(for: model) == fullHeight)
        let token = model.prepareReconfigure(options)
        precondition(model.items.map(\.id) == fresh.map(\.id), "Next open uses raw cached backend order, including deferred records")
        precondition(model.agentSections.map(\.id) == ["Blocked", "Working", "Idle"])
        precondition(model.agentSections[0].items.map(\.id) == ["new", "i"])
        await model.completeReconfigure(token)
        try await pending("agents", backend)
        await backend.reply("agents", APIResult(items: fresh))
        try await wait { !model.refreshing }
        model.query = "filtered"
        try await pending("agents", backend)
        await backend.reply("agents", APIResult(items: [fresh[1], fresh[2]]))
        try await wait { !model.refreshing }
        precondition(model.agentSections.map(\.id) == ["Blocked", "Working"])
        precondition(model.items.map(\.id) == ["i", "w"])
        precondition(model.numberedPosition(of: model.items[1]) == 2)
        precondition(PickerStyle.height(for: model) == fullHeight - PickerStyle.agentRowHeight - PickerStyle.agentGroupHeight - PickerStyle.agentGroupSpacing)
        model.close()
        print("PASS: native timestamps/ages, aggregate projections/pulse gates, snapshot groups, deferred records, raw cache reopen, search groups and header height/numbering")
    }

    @MainActor private static func stableAgentsChecks() async throws {
        let options = try LaunchOptions(arguments: ["--demo"])
        let backend = CachedListBackend()
        let model = PickerModel(options: options, backend: backend)
        let repos = APIResult(items: [PickerItem(path: "/repo")], targets: ["tab"], target: "tab")
        func agent(_ id: String, _ label: String? = nil) -> PickerItem {
            PickerItem(path: id, label: label ?? id, kind: "agent", sessionID: "s", app: "Pi", state: "idle", windowID: "w", blockID: id)
        }
        model.start()
        try await pending("directories", backend)
        await backend.reply("directories", repos)
        try await wait { !model.refreshing }
        model.selectView(.agents)
        try await pending("agents", backend)
        await backend.reply("agents", APIResult(items: [agent("b"), agent("a")]))
        try await wait { !model.refreshing }
        model.selectedID = "a"; model.scrollID = "a"

        func refresh(_ rows: [PickerItem]) async throws {
            model.selectView(.repos)
            try await pending("directories", backend)
            await backend.reply("directories", repos)
            try await wait { !model.refreshing }
            model.selectView(.agents)
            precondition(!model.loading && model.canOpen, "Cached Agents must remain usable")
            try await pending("agents", backend)
            await backend.reply("agents", APIResult(items: rows))
            try await wait { !model.refreshing }
        }
        try await refresh([agent("c"), agent("a", "Renamed"), agent("b")])
        precondition(model.items.map(\.id) == ["b", "a"] && model.selectedID == "a" && model.scrollID == "a")
        precondition(model.items[1].label == "Renamed", "Stable identity must still update row content")
        model.openNumbered(1)
        try await wait { !model.busy }
        precondition(model.selectedID == "b", "Numbered targets must not move during refresh")
        try await refresh([agent("d"), agent("c"), agent("a")])
        precondition(model.items.map(\.id) == ["a"], "Remove gone records; defer all new records")
        model.query = "ranked"
        try await pending("agents", backend)
        await backend.reply("agents", APIResult(items: [agent("d"), agent("a")]))
        try await wait { !model.refreshing }
        precondition(model.items.map(\.id) == ["d", "a"], "Search changes must use backend relevance")
        model.query = ""
        try await pending("agents", backend)
        await backend.reply("agents", APIResult(items: [agent("d"), agent("c"), agent("a")]))
        try await wait { !model.refreshing }
        precondition(model.items.map(\.id) == ["d", "c", "a"], "Revisited search must also take fresh backend relevance")
        try await refresh([agent("a"), agent("c"), agent("d")])
        precondition(model.items.map(\.id) == ["d", "c", "a"], "Refresh after search must freeze the new relevance order")
        let token = model.prepareReconfigure(options)
        precondition(model.canOpen && !model.loading, "Warm open must remain synchronous")
        await model.completeReconfigure(token)
        model.selectView(.agents)
        precondition(!model.loading && model.canOpen)
        try await pending("agents", backend)
        await backend.reply("agents", APIResult(items: [agent("a"), agent("c"), agent("d")]))
        try await wait { !model.refreshing }
        precondition(model.items.map(\.id) == ["a", "c", "d"], "New presentation must reset frozen order")
        model.close()
        print("PASS: stable Agents refresh identities, content, numbered targets, removal/deferred additions, search order, instant new-open reset")
    }

    @MainActor private static func directAgentsChecks() async throws {
        let options = try LaunchOptions(arguments: ["--demo", "--mode", "agents", "--session", "S"])
        let backend = CachedListBackend()
        let model = PickerModel(options: options, backend: backend)
        func agent(_ id: String) -> PickerItem {
            PickerItem(path: id, kind: "agent", sessionID: "S", windowID: "W", blockID: id)
        }
        precondition(model.view == .agents && model.page == .directories && model.loading)
        model.start()
        try await pending("agents", backend)
        let coldDirectories = await backend.count("directories")
        precondition(coldDirectories == 0, "Cold Agents must not load directories")
        await backend.reply("agents", APIResult(items: [agent("b"), agent("a")]))
        try await wait { !model.refreshing }
        model.query = "filtered"
        try await pending("agents", backend)
        await backend.reply("agents", APIResult(items: [agent("b"), agent("a")]))
        try await wait { !model.refreshing }
        model.selectedID = "a"; model.scrollID = "a"
        model.selectView(.agents)
        precondition(model.query == "filtered" && model.selectedID == "a" && model.shouldToggle(for: options))
        let shortcutCalls = await backend.count("agents")
        precondition(shortcutCalls == 2, "Active Agents shortcut must be idempotent")
        model.selectView(.repos)
        precondition(!model.shouldToggle(for: options), "A routed Agents request must not hide another view")
        try await pending("directories", backend)
        await backend.reply("directories", APIResult(items: []))
        try await wait { !model.refreshing }
        let token = model.prepareReconfigure(options)
        precondition(model.view == .agents && model.contextReady && model.canOpen && !model.loading)
        precondition(model.query == "filtered" && model.selectedID == "a" && model.scrollID == "a")
        await model.completeReconfigure(token)
        try await pending("agents", backend)
        await backend.reply("agents", APIResult(items: [agent("a"), agent("b")]))
        try await wait { !model.refreshing }
        precondition(model.items.map(\.id) == ["b", "a"], "New presentation captures the latest raw cache at first display")
        model.selectView(.repos)
        try await pending("directories", backend)
        await backend.reply("directories", APIResult(items: []))
        try await wait { !model.refreshing }
        model.selectView(.agents)
        try await pending("agents", backend)
        await backend.reply("agents", APIResult(items: [agent("b"), agent("a"), agent("c")]))
        try await wait { !model.refreshing }
        precondition(model.items.map(\.id) == ["b", "a"], "Freeze order and defer new records within a presentation")
        model.askRemove(); model.beginCreate(); model.togglePin()
        precondition(!model.busy && model.removalCandidate == nil)
        for method in ["sessions", "context", "pins.toggle", "worktrees.remove", "sessions.close", "sessions.rename", "dispatch", "agents.jump"] {
            let calls = await backend.count(method)
            precondition(calls == 0, "Direct route must not issue unrelated actions: \(method)")
        }
        await backend.hold("context")
        let changed = try LaunchOptions(arguments: ["--demo", "--mode", "agents", "--session", "changed"])
        let changedToken = model.prepareReconfigure(changed)
        precondition(model.view == .agents && model.items.isEmpty && model.loading && !model.contextReady && !model.canOpen)
        model.choose(); model.openNumbered(1); model.selectView(.repos)
        precondition(model.view == .agents && !model.busy)
        let completion = Task { await model.completeReconfigure(changedToken) }
        try await pending("context", backend)
        let gatedAgents = await backend.count("agents")
        precondition(gatedAgents == 4, "Agents must wait for context acknowledgement")
        await backend.reply("context", APIResult())
        await completion.value
        try await pending("agents", backend)
        await backend.reply("agents", APIResult(items: [agent("new")]))
        try await wait { !model.refreshing }
        precondition(model.canOpen && model.items.map(\.id) == ["new"] && model.query.isEmpty)
        let totalDirectories = await backend.count("directories")
        precondition(totalDirectories == 2, "Only explicit Repos visits may load directories")
        model.close()

        // The shortcut uses selectView; forms, confirmations and popovers keep ownership.
        let guarded = PickerModel(options: try LaunchOptions(arguments: ["--demo"]), backend: DemoBackend())
        guarded.busy = true; guarded.selectView(.agents); precondition(guarded.view == .repos)
        guarded.busy = false; guarded.page = .create
        guarded.selectView(.agents); precondition(guarded.view == .repos)
        guarded.page = .directories; guarded.removalCandidate = PickerItem(path: "confirm")
        guarded.selectView(.agents); precondition(guarded.view == .repos)
        guarded.removalCandidate = nil; guarded.basePickerPresented = true
        guarded.selectView(.agents); precondition(guarded.view == .repos)
        guarded.basePickerPresented = false; guarded.targetPickerPresented = true
        guarded.selectView(.agents); precondition(guarded.view == .repos)
        guarded.targetPickerPresented = false; guarded.selectView(.agents)
        precondition(guarded.view == .agents)
        guarded.close()
    }

    @MainActor private static func agentsChecks() async throws {
        let payload = Data("""
        {"path":"record-unique","kind":"agent","label":"Plan","app":"Pi","state":"working","agent_id":"a","session_id":"s","session_label":"Project","window_id":"w","window_label":"Build","block_id":"b","active":true}
        """.utf8)
        let item = try JSONDecoder().decode(PickerItem.self, from: payload)
        precondition(item.id == "record-unique" && item.agentID == "a" && item.windowID == "w" && item.blockID == "b")
        precondition(item.app == "Pi" && item.state == "working" && item.windowLabel == "Build" && !item.isSessionEntry)
        precondition(PickerStyle.agentRowHeight == 32 && PickerStyle.agentRowHeight == PickerStyle.rowHeight)
        var compact = item
        compact.label = ".dotfiles"; compact.sessionLabel = "personal"; compact.windowLabel = "dotfiles"
        precondition(compact.agentContext == "personal")
        compact.windowLabel = "namedtest"
        precondition(compact.agentContext == "personal / namedtest")
        compact.state = "idle"
        precondition(compact.agentActivity == nil && !compact.agentAccessibility.lowercased().contains("idle") && !compact.agentHelp.lowercased().contains("idle"))
        precondition(compact.agentAccessibility.contains("Pi") && compact.agentHelp.contains("Current pane"))
        for state in ["blocked", "needs_input", "needs-input", "waiting"] {
            compact.state = state
            precondition(compact.agentActivity == "Blocked" && compact.agentAccessibility.contains("Blocked"))
        }
        compact.state = "working"
        precondition(compact.agentActivity == "Working")
        let backend = DemoBackend()
        let options = try LaunchOptions(arguments: ["--demo"])
        let model = PickerModel(options: options, backend: backend)
        model.start()
        try await wait { !model.refreshing }
        precondition(PickerModel.ViewKind.allCases == [.repos, .agents], "Only Repos and Agents are navigable")
        for expected: PickerModel.ViewKind in [.agents, .repos, .agents, .repos] {
            model.switchView()
            precondition(model.view == expected)
            try await wait { !model.refreshing }
        }
        for expected: PickerModel.ViewKind in [.agents, .repos, .agents, .repos] {
            model.switchView(backward: true)
            precondition(model.view == expected)
            try await wait { !model.refreshing }
        }
        model.selectView(.agents)
        precondition(model.view == .agents && !model.loading && model.canOpen)
        try await wait { !model.refreshing }
        precondition(model.items.count == 3 && Set(model.items.map(\.id)).count == 3)
        model.query = "picker"
        try await wait { !model.refreshing }
        precondition(model.items.count == 2)
        model.selectedID = model.items[1].id; model.scrollID = model.items[1].id
        let selected = model.selectedID
        model.selectView(.repos)
        model.selectView(.agents)
        precondition(model.view == .agents && model.query == "picker" && model.selectedID == selected && model.scrollID == selected && model.canOpen)
        model.selectView(.agents)
        precondition(model.view == .agents, "Clicking an active pill must not cycle")
        model.togglePin(); model.askRemove(); model.beginCreate(); model.showWorktrees(); model.toggleSplit()
        precondition(model.removalCandidate == nil && !model.splitMode && model.page == .directories && !model.busy)
        model.openNumbered(2)
        try await wait { !model.busy }
        var params = await backend.parameters("agents.jump")
        precondition(params.count == 3)
        if case .text("session:demo-1") = params["session_id"],
           case .text("window:demo-1a") = params["window_id"],
           case .text("block:demo-left") = params["block_id"] {} else {
            preconditionFailure("Agents jump must focus the exact pane, not record identity")
        }
        model.selectedID = model.items[0].id
        var dismissed = false
        model.onDismiss = { dismissed = true }
        model.choose()
        model.escape()
        precondition(dismissed && model.busy, "Busy Escape must hide without cancelling navigation")
        try await wait { !model.busy }
        params = await backend.parameters("agents.jump")
        if case .text("block:demo-right") = params["block_id"] {} else { preconditionFailure("Enter must jump to selected agent") }
        for method in ["sessions.close", "sessions.rename", "pins.toggle", "worktrees.remove", "worktrees.create", "dispatch"] {
            let count = await backend.count(method)
            precondition(count == 0, "Agents are navigation only: \(method)")
        }
        try await wait { !model.refreshing }
        model.selectedID = selected
        let token = model.prepareReconfigure(options)
        precondition(model.contextReady && !model.loading && model.canOpen && model.view == .repos)
        await model.completeReconfigure(token)
        model.selectView(.agents)
        precondition(!model.loading && model.query == "picker" && model.selectedID == selected && model.scrollID == selected)
        dismissed = false
        model.escape()
        precondition(dismissed && model.view == .agents && model.query == "picker",
                     "Escape must dismiss, not clear search or select Repos")
        let changed = model.prepareReconfigure(try LaunchOptions(arguments: ["--demo", "--session", "changed"]))
        await model.completeReconfigure(changed)
        try await wait { !model.refreshing }
        model.selectView(.agents)
        precondition(model.loading && model.items.isEmpty, "Changed context must discard the Agents cache")
        try await wait { !model.refreshing }
        model.close()
        print("PASS: Agents decoding, two-view forward/backward cycle and exact pills, cached query/selection/scroll, warm reopen, context invalidation, exact-pane Enter/numbered jump, no destructive actions, busy dismissal")
    }

    @MainActor private static func launcherEscapeChecks() throws {
        for view in PickerModel.ViewKind.allCases {
            for query in ["", "filtered"] {
                let model = PickerModel(options: try LaunchOptions(arguments: ["--demo"]), backend: DemoBackend())
                model.view = view
                model.query = query
                var dismissals = 0
                model.onDismiss = { dismissals += 1 }
                model.escape()
                precondition(dismissals == 1 && model.view == view && model.query == query,
                             "Escape must dismiss every launcher view without clearing search or selecting Repos")
                model.close()
            }
        }
    }

    @MainActor private static func residentChecks() async throws {
        // Agents view over the long-lived model.
        let agentsBackend = DemoBackend()
        let agents = PickerModel(options: try LaunchOptions(arguments: ["--demo"]), backend: agentsBackend)
        agents.start()
        try await wait { !agents.loading }
        precondition(agents.view == .repos && agents.page == .directories && agents.showsPills)
        agents.switchView()
        try await wait { !agents.loading }
        precondition(agents.view == .agents && agents.items.count == 3 && agents.items.allSatisfy { $0.kind == "agent" })
        precondition(agents.items.contains { $0.active == true }, "Active agents must be marked")
        agents.openNumbered(2)
        try await wait { !agents.busy }
        let jumpCount = await agentsBackend.count("agents.jump")
        precondition(jumpCount == 1, "Numbered open must jump to the agent")
        agents.switchView(backward: true)
        try await wait { !agents.loading }
        precondition(agents.view == .repos && agents.page == .directories, "Reverse switch must return to Repos")
        let sessionCalls = await agentsBackend.count("sessions")
        precondition(sessionCalls == 0, "View navigation must never request Sessions")
        agents.close()

        // Pins float to the top of the repos list.
        let pinsBackend = DemoBackend()
        let pinned = PickerModel(options: try LaunchOptions(arguments: ["--demo"]), backend: pinsBackend)
        pinned.start()
        try await wait { !pinned.loading }
        pinned.togglePin()
        try await wait { !pinned.busy && !pinned.loading }
        precondition(pinned.items.first?.isPinned == true, "Pinned directories must float to the top")
        let pinCount = await pinsBackend.count("pins.toggle")
        precondition(pinCount == 1, "Pinning must ask the backend once")
        pinned.close()

        // Resident reconfigure: one model serves repeated opens.
        let backend = DemoBackend()
        let resident = PickerModel(options: try LaunchOptions(arguments: ["--demo"]), backend: backend)
        resident.start()
        try await wait { !resident.loading }
        let contexts = await backend.contextUpdateCount
        await resident.reconfigure(try LaunchOptions(arguments: ["--demo", "--mode", "wt", "--repo", "/Users/demo/Projects/example-kit"]))
        try await wait { !resident.loading }
        precondition(resident.page == .worktrees && resident.view == .repos,
                     "Reconfigure must apply the new mode")
        let contextsAfter = await backend.contextUpdateCount
        precondition(contextsAfter == contexts + 1,
                     "Reconfigure must retell the shared backend its context")
        await resident.reconfigure(try LaunchOptions(arguments: ["--demo"]))
        try await wait { !resident.loading }
        precondition(resident.page == .directories)
        resident.close()
        print("PASS: resident Agents view, numbered jump, reverse switch, no Sessions route, pins, resident reconfigure")
    }

    @MainActor private static func cachedListChecks() async throws {
        let backend = CachedListBackend()
        let model = PickerModel(options: try LaunchOptions(arguments: ["--demo"]), backend: backend)
        let repos = APIResult(items: ["/a", "/b", "/c"].map { PickerItem(path: $0) }, targets: ["tab", "session"], target: "tab")
        let agents = APIResult(items: ["A1", "A2", "A3"].map { PickerItem(path: $0, kind: "agent", sessionID: "S", windowID: "W", blockID: $0) })
        model.start()
        try await pending("directories", backend)
        await backend.reply("directories", repos)
        try await wait { !model.refreshing }
        model.selectedID = "/b"; model.scrollID = "/c"; model.target = "session"
        model.switchView()
        precondition(model.loading && model.items.isEmpty && model.selectedID == nil && model.scrollID == nil,
                     "An uncached view must clear the other view before its request starts")
        try await pending("agents", backend)
        await backend.reply("agents", agents)
        try await wait { !model.refreshing }
        model.selectedID = "A2"; model.scrollID = "A3"
        model.selectView(.repos)
        precondition(!model.loading && model.refreshing && model.canOpen && model.selectedID == "/b" && model.scrollID == "/c" && model.target == "session",
                     "Cached repos must restore selection, scroll and target before refreshing, with Open enabled")
        try await pending("directories", backend)
        model.switchView()
        precondition(!model.loading && model.canOpen && model.selectedID == "A2" && model.scrollID == "A3")
        try await pending("agents", backend)
        await backend.reply("directories", APIResult(items: [PickerItem(path: "/obsolete")]))
        await backend.reply("agents", APIResult(items: [agents.items![0]]))
        try await wait { !model.refreshing }
        precondition(model.selectedID == "A1" && model.scrollID == nil,
                     "Refresh must repair selection and scroll when their rows disappear")
        model.selectView(.repos)
        precondition(model.items == repos.items && model.selectedID == "/b" && model.scrollID == "/c",
                     "A cancelled reply must not overwrite the inactive cache")
        try await pending("directories", backend)
        await backend.fail("directories")
        try await wait { !model.refreshing }
        precondition(model.canOpen && model.items == repos.items && model.error != nil,
                     "A failed background refresh must keep cached rows usable")

        model.query = "filtered"
        precondition(model.loading && model.items.isEmpty, "Uncached queries must not expose stale rows")
        try await pending("directories", backend)
        await backend.reply("directories", repos)
        try await wait { !model.refreshing }
        model.selectedID = "/c"; model.scrollID = "/b"
        model.switchView()
        try await pending("agents", backend)
        model.selectView(.repos)
        precondition(model.query == "filtered" && model.selectedID == "/c" && model.scrollID == "/b" && model.canOpen,
                     "Each view must retain its own query and list position")
        try await pending("directories", backend)
        model.openNumbered(2)
        try await wait { !model.busy }
        let cachedDispatches = await backend.count("dispatch")
        precondition(cachedDispatches == 1, "Cached numbered Open must not wait for refresh")
        // Dispatch invalidates both lists: new agent metadata may now exist.
        await backend.reply("agents", agents)
        await backend.reply("directories", repos)
        model.switchView()
        precondition(model.loading && model.items.isEmpty, "Dispatch must invalidate the Agents cache too")
        try await pending("agents", backend)
        await backend.fail("agents")
        try await wait { !model.refreshing }
        precondition(model.items.isEmpty && model.error != nil, "Failed post-mutation refresh must not restore stale rows")
        model.selectView(.repos)
        precondition(model.loading && model.items.isEmpty, "Mutation must invalidate the Repos cache too")
        try await pending("directories", backend)

        // Reconfigure while an old-origin reply is pending. No old rows can
        // appear either during the context request or on a subsequent switch.
        await model.reconfigure(try LaunchOptions(arguments: ["--demo", "--session", "new-origin", "--mode", "wt", "--repo", "/new-repo"]))
        precondition(model.items.isEmpty && model.scrollID == nil && model.loading && !model.canOpen)
        await backend.reply("directories", repos)
        try await pending("worktrees.list", backend)
        let worktrees = APIResult(items: [PickerItem(path: "/new-repo/main", branch: "main")], targets: ["tab"], target: "tab", repo: "/new-repo", branches: ["main"], baseBranch: "main")
        await backend.reply("worktrees.list", worktrees)
        try await wait { !model.refreshing }
        model.switchView()
        precondition(model.loading && model.items.isEmpty, "New origin must not reuse old agent rows")
        try await pending("agents", backend)
        await backend.reply("agents", agents)
        try await wait { !model.refreshing }
        precondition(model.repo == "/new-repo" && model.base == "main",
                     "Agents replies on the worktree page must not replace repository metadata")
        model.selectView(.repos)
        precondition(model.items == worktrees.items && model.canOpen)
        try await pending("worktrees.list", backend)
        model.beginCreate()
        await backend.reply("worktrees.list", APIResult(items: [PickerItem(path: "/late")], repo: "/wrong"))
        try await Task.sleep(for: .milliseconds(30))
        precondition(model.page == .create && model.repo == "/new-repo", "Late background list must not change Create metadata")
        model.close()

        // The first open may overtake startup's directory warmup. Its reply
        // must not leak into a worktree open or restart the model afterwards.
        let warmBackend = CachedListBackend()
        let warm = PickerModel(options: try LaunchOptions(arguments: ["--demo"]), backend: warmBackend)
        warm.start()
        try await pending("directories", warmBackend)
        await warmBackend.hold("context")
        let firstContext = warm.prepareReconfigure(try LaunchOptions(arguments: ["--demo", "--mode", "wt", "--repo", "/first", "--session", "first"]))
        let firstOpen = Task { await warm.completeReconfigure(firstContext) }
        try await pending("context", warmBackend)
        await warmBackend.reply("directories", repos)
        warm.start()
        try await Task.sleep(for: .milliseconds(30))
        precondition(warm.items.isEmpty && warm.page == .worktrees && warm.repo == "/first" && !warm.contextReady,
                     "A late startup reply or repeated start must not overwrite the first open")
        await warmBackend.reply("context", APIResult())
        await firstOpen.value
        try await pending("worktrees.list", warmBackend)
        await warmBackend.reply("worktrees.list", APIResult(items: [PickerItem(path: "/first/main")], targets: ["tab"], target: "tab", repo: "/first"))
        try await wait { !warm.refreshing }
        precondition(warm.contextReady && warm.canOpen && warm.repo == "/first")
        warm.close()

        let mutationBackend = CachedListBackend()
        let mutation = PickerModel(options: try LaunchOptions(arguments: ["--demo"]), backend: mutationBackend)
        mutation.start()
        try await pending("directories", mutationBackend)
        await mutationBackend.reply("directories", repos)
        try await wait { !mutation.refreshing }
        await mutationBackend.hold("pins.toggle")
        mutation.togglePin()
        try await pending("pins.toggle", mutationBackend)
        await mutationBackend.hold("context")
        let context = mutation.prepareReconfigure(try LaunchOptions(arguments: ["--demo", "--session", "changed"]))
        precondition(mutation.items == repos.items && !mutation.loading && !mutation.busy && !mutation.contextReady && !mutation.canOpen,
                     "Prepare must synchronously show global directories, but gate all actions")
        precondition(mutation.targets.isEmpty && mutation.target.isEmpty && mutation.repo == nil && mutation.branches.isEmpty,
                     "Cached directories must not restore old-origin targets or repository state")
        mutation.openNumbered(2); mutation.choose(); mutation.togglePin()
        mutation.showWorktrees(); mutation.beginCreate(); mutation.switchView()
        mutation.askRemove(); mutation.confirmRemove(PickerItem(path: "/old", isMain: false))
        mutation.create(); mutation.openCreated(); mutation.cycleTarget(backward: false); mutation.toggleSplit()
        precondition(mutation.page == .directories && mutation.view == .repos && mutation.repo == nil && !mutation.busy && mutation.removalCandidate == nil,
                     "Actions must not change navigation or candidates before context is ready")
        let reopen = Task { await mutation.completeReconfigure(context) }
        try await pending("context", mutationBackend)
        mutation.start() // Startup warmup cannot reset or query a pending open.
        let callsWhileBlocked = await mutationBackend.count("directories")
        let dispatchesWhileBlocked = await mutationBackend.count("dispatch")
        let pinsWhileBlocked = await mutationBackend.count("pins.toggle")
        precondition(callsWhileBlocked == 1 && dispatchesWhileBlocked == 0 && pinsWhileBlocked == 1,
                     "Blocked actions and late start must not send requests using the old context")
        await mutationBackend.reply("pins.toggle", APIResult())
        await mutationBackend.reply("context", APIResult())
        await reopen.value
        try await pending("directories", mutationBackend)
        await mutationBackend.reply("directories", APIResult(items: [PickerItem(path: "/new-origin")], targets: ["tab"], target: "tab"))
        try await wait { !mutation.refreshing }
        let directoryCalls = await mutationBackend.count("directories")
        precondition(directoryCalls == 2 && mutation.selectedID == "/new-origin" && mutation.error == nil,
                     "Old mutation completion must not refresh or modify a new context")
        let failedContext = mutation.prepareReconfigure(try LaunchOptions(arguments: ["--demo", "--session", "failed"]))
        let failedOpen = Task { await mutation.completeReconfigure(failedContext) }
        try await pending("context", mutationBackend)
        await mutationBackend.fail("context")
        await failedOpen.value
        precondition(!mutation.contextReady && !mutation.canOpen && !mutation.canCreate && !mutation.canSubmitForm && mutation.error != nil && !mutation.refreshing,
                     "Context failure must be explicit and must never enable stale-backend actions")
        mutation.openNumbered(1); mutation.togglePin(); mutation.beginCreate(); mutation.switchView()
        precondition(!mutation.busy && mutation.page == .directories && mutation.view == .repos)
        let worktreeContext = mutation.prepareReconfigure(try LaunchOptions(arguments: ["--demo", "--mode", "wt", "--repo", "/different", "--session", "third"]))
        precondition(mutation.items.isEmpty && mutation.loading && mutation.repo == "/different" && mutation.branches.isEmpty && mutation.base.isEmpty,
                     "A worktree open must never show cached directories or old contextual metadata")
        let directoryContext = mutation.prepareReconfigure(try LaunchOptions(arguments: ["--demo", "--session", "fourth"]))
        await mutation.completeReconfigure(worktreeContext)
        precondition(mutation.items.first?.path == "/new-origin" && !mutation.contextReady,
                     "A superseded completion must not send context or enable actions")
        let recovered = Task { await mutation.completeReconfigure(directoryContext) }
        try await pending("context", mutationBackend)
        await mutationBackend.reply("context", APIResult())
        await recovered.value
        try await pending("directories", mutationBackend)
        precondition(mutation.contextReady && mutation.target.isEmpty && !mutation.canOpen,
                     "Targets must come from the refreshed origin, not the global directory cache")
        await mutationBackend.reply("directories", repos)
        try await wait { !mutation.refreshing }
        precondition(mutation.canOpen, "A successful retry and list refresh must restore actions")
        mutation.close()
        print("PASS: instant cached switching, per-view query/selection/scroll, cached Open, cancelled replies, refresh failure, mutation invalidation, origin/repo/page isolation, synchronous directory reopen, blocked context action gates, context failure/retry, startup warmup race")
    }

    @MainActor private static func dismissalChecks() async throws {
        let options = try LaunchOptions(arguments: []) // Real success path, not demo notices.
        let rows = APIResult(items: [PickerItem(path: "/repo")], targets: ["tab"], target: "tab")
        for method in ["agents.jump", "dispatch"] {
            let backend = CachedListBackend()
            await backend.hold(method)
            let model = PickerModel(options: options, backend: backend)
            var closes = 0
            var dismissals = 0
            model.onClose = { closes += 1 }
            model.onDismiss = { dismissals += 1 }
            model.start()
            try await pending("directories", backend)
            await backend.reply("directories", rows)
            try await wait { !model.loading }
            if method == "agents.jump" {
                model.selectView(.agents)
                try await pending("agents", backend)
                await backend.reply("agents", APIResult(items: [PickerItem(path: "record", kind: "agent", sessionID: "S", windowID: "W", blockID: "B")]))
                try await wait { !model.loading }
            }
            model.choose()
            try await pending(method, backend)
            model.escape()
            model.dismiss() // Window close / resident toggle / Command-Q use this API.
            model.choose()
            precondition(model.busy && dismissals == 2 && closes == 0 && !model.backendIsClosed,
                         "Dismiss must hide without closing or cancelling a live operation")
            await backend.reply(method, APIResult())
            try await wait { closes == 1 }
            precondition(!model.busy && model.backendIsClosed,
                         "Successful non-demo jump/dispatch must close without sticky busy; resident recovery must be eligible")
            let calls = await backend.count(method)
            precondition(calls == 1, "Dismiss and repeated Open must not replay an operation")
            // The resident delegate replaces a closed backend before reconfiguration.
            let freshBackend = CachedListBackend()
            let fresh = PickerModel(options: options, backend: freshBackend)
            await fresh.reconfigure(options)
            try await pending("directories", freshBackend)
            await freshBackend.reply("directories", rows)
            try await wait { fresh.canOpen }
            precondition(!fresh.busy && !fresh.backendIsClosed)
            fresh.close()
        }

        // A hidden create must retain its committed path if opening fails.
        let backend = CachedListBackend()
        await backend.hold("worktrees.create")
        await backend.hold("dispatch")
        let createOptions = try LaunchOptions(arguments: ["--mode", "wt-create", "--repo", "/repo", "--session", "original", "--block", "B", "--client", "C", "--title", "Original"])
        let create = PickerModel(options: createOptions, backend: backend)
        var hidden = 0
        create.onDismiss = { hidden += 1 }
        create.start()
        try await pending("worktrees.list", backend)
        await backend.reply("worktrees.list", APIResult(targets: ["tab"], target: "tab", repo: "/repo", branches: ["main"], baseBranch: "main"))
        try await wait { !create.loading }
        create.branch = "feat/new"
        create.destination = "/repo-new"; create.previewReady = true
        create.create()
        try await pending("worktrees.create", backend)
        create.escape(); create.dismiss(); create.create()
        precondition(create.busy && hidden == 2 && !create.backendIsClosed)
        await backend.reply("worktrees.create", APIResult(path: "/repo-new"))
        try await pending("dispatch", backend)
        create.escape() // Hide after create committed, while dispatch is pending.
        let busyReopen = create.prepareReconfigure(createOptions)
        await create.completeReconfigure(busyReopen)
        precondition(create.busy && create.createdPath == "/repo-new")
        await backend.fail("dispatch")
        try await wait { !create.busy }
        precondition(create.createdPath == "/repo-new" && create.error != nil,
                     "Hidden create must finish and retain its path after dispatch failure")
        let savedError = create.error
        let reopen = create.prepareReconfigure(createOptions)
        await create.completeReconfigure(reopen)
        precondition(create.page == .create && create.createdPath == "/repo-new"
                     && create.error == savedError && create.canSubmitForm && !create.canCreate,
                     "Actual resident reopen must restore Retry opening and its failure")
        create.escape()
        precondition(hidden == 4 && create.createdPath == "/repo-new",
                     "Escape must hide recovery without discarding it")
        let unrelated = try LaunchOptions(arguments: ["--mode", "wt-create", "--repo", "/other", "--session", "new", "--block", "new", "--client", "new", "--title", "New"])
        for incoming in [unrelated, try LaunchOptions(arguments: ["--mode", "agents"])] {
            let changed = create.prepareReconfigure(incoming)
            await create.completeReconfigure(changed)
            precondition(create.options.matches(createOptions) && create.repo == "/repo"
                         && create.target == "tab" && create.createdPath == "/repo-new"
                         && create.error?.contains("original context") == true && !create.canCreate,
                         "Unrelated requests must show recovery, not retarget its repo or origin")
        }
        let contexts = await backend.count("context")
        let lists = await backend.count("worktrees.list")
        precondition(contexts == 0 && lists == 1,
                     "Recovery reopen must not reconfigure the backend or regenerate the form")
        create.submitBranch() // Retry opens only, never creates again.
        try await pending("dispatch", backend)
        await backend.reply("dispatch", APIResult())
        try await wait { create.backendIsClosed }
        let creates = await backend.count("worktrees.create")
        let opens = await backend.count("dispatch")
        let openParams = await backend.parameters("dispatch")
        if case .text("/repo-new") = openParams["path"], case .text("tab") = openParams["target"] {} else {
            preconditionFailure("Retry must open the committed path with the retained target")
        }
        precondition(creates == 1 && opens == 2 && !create.busy && create.createdPath == nil,
                     "Successful retry must clear recovery so the resident can replace the closed backend")

        // Directory-origin Create has a different createParent. Neither a hide
        // nor an unrelated launch may navigate away and erase its recovery.
        let discardBackend = CachedListBackend()
        await discardBackend.hold("worktrees.create")
        await discardBackend.hold("dispatch")
        let discard = PickerModel(options: options, backend: discardBackend)
        discard.start()
        try await pending("directories", discardBackend)
        await discardBackend.reply("directories", rows)
        try await wait { !discard.loading }
        discard.beginCreate()
        try await pending("worktrees.list", discardBackend)
        await discardBackend.reply("worktrees.list", APIResult(targets: ["tab"], target: "tab", repo: "/repo", branches: ["main"], baseBranch: "main"))
        try await wait { !discard.loading }
        discard.branch = "feat/discard"
        discard.destination = "/repo-discard"; discard.previewReady = true
        discard.create()
        try await pending("worktrees.create", discardBackend)
        await discardBackend.reply("worktrees.create", APIResult(path: "/repo-discard"))
        try await pending("dispatch", discardBackend)
        discard.escape()
        await discardBackend.fail("dispatch")
        try await wait { !discard.busy }
        let retained = discard.prepareReconfigure(unrelated)
        await discard.completeReconfigure(retained)
        discard.escape()
        precondition(discard.page == .create && discard.createdPath == "/repo-discard" && discard.repo == "/repo")
        discard.discardCreatedRecovery()
        discard.submitBranch(); discard.create(); discard.openCreated()
        precondition(discard.createdPath == nil && !discard.contextReady && !discard.canCreate,
                     "Explicit discard must gate all old-context actions until a new request")
        let freshContext = discard.prepareReconfigure(unrelated)
        await discard.completeReconfigure(freshContext)
        try await pending("worktrees.list", discardBackend)
        precondition(discard.options.matches(unrelated) && discard.repo == "/other")
        let contextParams = await discardBackend.parameters("context")
        if case .text("new") = contextParams["session"], case .text("new") = contextParams["block"] {} else {
            preconditionFailure("Only explicit discard may install the new origin")
        }
        await discardBackend.reply("worktrees.list", APIResult(targets: ["tab"], target: "tab", repo: "/other", branches: ["main"], baseBranch: "main"))
        try await wait { !discard.loading }
        let discardedCreates = await discardBackend.count("worktrees.create")
        let discardedOpens = await discardBackend.count("dispatch")
        precondition(discardedCreates == 1 && discardedOpens == 1)
        discard.close()

        let pinBackend = CachedListBackend()
        await pinBackend.hold("pins.toggle")
        let pin = PickerModel(options: options, backend: pinBackend)
        pin.onDismiss = { hidden += 1 }
        pin.start()
        try await pending("directories", pinBackend)
        await pinBackend.reply("directories", rows)
        try await wait { !pin.loading }
        pin.togglePin()
        try await pending("pins.toggle", pinBackend)
        pin.escape(); pin.dismiss(); pin.togglePin()
        precondition(pin.busy && !pin.backendIsClosed)
        await pinBackend.reply("pins.toggle", APIResult())
        try await pending("directories", pinBackend)
        await pinBackend.reply("directories", APIResult(items: []))
        try await wait { !pin.busy && !pin.refreshing }
        let pins = await pinBackend.count("pins.toggle")
        precondition(pins == 1 && pin.items.isEmpty && pin.error == nil,
                     "Hidden pin mutation must finish once and refresh, without cancellation or replay")
        pin.close()
        print("PASS: non-demo jump/dispatch closes without sticky busy, resident replacement reopens, pending Escape/dismiss preserves create/pin, real recovery reconfigure retains error/path/origin without recreation, explicit discard gates stale actions")
    }

    @MainActor private static func nativeThemeRoleChecks() throws {
        let ui = InterfacePalettePayload(background: "#303030", foreground: "#ddbbcc",
                                         selection: "#aaccaa", selectionForeground: "#102030",
                                         surface: "#505050")
        for dark in [true, false] {
            for style in ["modern", "classic", "blendTheme", "useTheme"] {
                let payload = ThemePayload(isDark: dark, background: "#112233", foreground: "#aabbaa",
                                           selection: "#223322", selectionForeground: "#ddeedd",
                                           interfaceStyle: style, ui: ui)
                precondition(PickerPalette.apply(payload))
                precondition(NSColor(PickerStyle.background) == NSColor(hexColor("#303030")!) &&
                             NSColor(PickerStyle.selection) == NSColor(hexColor("#aaccaa")!) &&
                             NSColor(PickerStyle.selectionText) == NSColor(hexColor("#102030")!) &&
                             PickerPalette.selectionOpacity == 0.75,
                             "Native roles must not reuse terminal canvas, selection or selected text")
                let label = NSColor(PickerStyle.foreground).usingColorSpace(.sRGB)!
                if style == "useTheme" {
                    precondition(NSColor(PickerStyle.foreground) == NSColor(hexColor("#ddbbcc")!),
                                 "Full-theme chrome must use UI content, not terminal foreground")
                } else {
                    precondition(abs(label.redComponent - label.greenComponent) < 0.01 &&
                                 abs(label.greenComponent - label.blueComponent) < 0.01 &&
                                 (dark ? label.redComponent > 0.8 : label.redComponent < 0.2),
                                 "Native labels must follow Rex appearance, not system or terminal colors")
                }
                let tinted = style == "blendTheme" || style == "useTheme"
                precondition(PickerPalette.usesThemeTint == tinted)
                if #available(macOS 26.0, *) {
                    let glass = NSGlassEffectView(frame: .zero)
                    glass.wantsLayer = true
                    PickerStyle.applyPanelTheme(to: glass)
                    precondition(glass.tintColor == (tinted ? PickerStyle.glassTint : nil),
                                 "Only Rex's theme-tinted styles may color the glass")
                }
            }
        }
        PickerPalette.useFallback(dark: true)
        print("PASS: native UI versus terminal roles, light/dark system labels, tinted/full-theme styles and translucent selection")
    }

    @MainActor private static func themeRefreshChecks() async throws {
        let backend = CachedListBackend()
        await backend.hold("theme")
        let options = try LaunchOptions(arguments: ["--demo"])
        let model = PickerModel(options: options, backend: backend)
        let rows = APIResult(items: [PickerItem(path: "/a"), PickerItem(path: "/b")],
                             targets: ["tab", "session"], target: "tab")
        let dark = ThemePayload(name: "Forest", isDark: true, background: "#102030",
                                foreground: "#eeeeee", selection: "#aaccee",
                                selectionForeground: "#203040", surface: "#223344")
        let light = ThemePayload(name: "Light", isDark: false, background: "#f0e0d0",
                                 foreground: "#203040", selection: "#556677",
                                 selectionForeground: "#ffeedd", surface: "#ddccbb")
        model.start()
        try await pending("theme", backend)
        try await pending("directories", backend)
        await backend.reply("directories", rows)
        try await wait { !model.refreshing }
        precondition(model.canOpen && !model.themeLoaded,
                     "A slow theme lookup must not block loaded rows")
        let first = model.refreshTheme()
        await backend.reply("theme", APIResult(theme: dark))
        await first?.value
        precondition(model.themeLoaded && model.themeRevision == 1 && PickerPalette.isDark)
        precondition(NSColor(PickerStyle.selectionText) == NSColor(hexColor("#203040")!),
                     "Selected text must use Rex's selected-theme color, not hardcoded white")
        let material = NSView()
        material.wantsLayer = true
        PickerStyle.applyPanelTheme(to: material)
        precondition(material.appearance?.name == .darkAqua &&
                     material.layer?.backgroundColor == NSColor(PickerPalette.background).cgColor,
                     "Asynchronous theme loading must repaint the native material")

        model.query = "keep"
        try await pending("directories", backend)
        await backend.reply("directories", rows)
        try await wait { !model.refreshing }
        model.selectedID = "/b"; model.scrollID = "/a"; model.target = "session"
        let refresh = model.refreshTheme()
        model.refreshTheme()
        try await pending("theme", backend)
        let themeCalls = await backend.count("theme")
        precondition(themeCalls == 2 && model.canOpen && !model.busy,
                     "Theme refresh must coalesce requests without gating cached Open")
        await backend.reply("theme", APIResult(theme: light))
        await refresh?.value
        precondition(model.themeRevision == 2 && !PickerPalette.isDark)
        precondition(model.query == "keep" && model.selectedID == "/b" && model.scrollID == "/a" &&
                     model.target == "session" && model.items == rows.items,
                     "Theme changes must preserve query, rows, selection, scroll and target")
        PickerStyle.applyPanelTheme(to: material)
        precondition(material.appearance?.name == .aqua &&
                     material.layer?.backgroundColor == NSColor(PickerPalette.background).cgColor &&
                     material.layer?.borderColor == PickerStyle.hairline.cgColor,
                     "Native surface, border and appearance must follow a changed Rex theme")
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: .zero)
            glass.wantsLayer = true
            glass.tintColor = .red
            PickerStyle.applyPanelTheme(to: glass)
            precondition(glass.tintColor == PickerStyle.glassTint && glass.appearance?.name == .aqua,
                         "Glass must replace the previous tint with the loaded Rex theme")
        }
        let effect = NSVisualEffectView(frame: .zero)
        effect.wantsLayer = true
        PickerStyle.applyPanelTheme(to: effect)
        precondition(effect.layer?.backgroundColor == PickerStyle.glassTint.cgColor &&
                     effect.appearance?.name == .aqua,
                     "Pre-glass macOS material must also follow the Rex theme")

        let unchanged = model.refreshTheme()
        try await pending("theme", backend)
        await backend.reply("theme", APIResult(theme: light))
        await unchanged?.value
        precondition(model.themeRevision == 2, "An unchanged theme must not repaint")
        let failed = model.refreshTheme()
        try await pending("theme", backend)
        await backend.fail("theme")
        await failed?.value
        precondition(model.themeRevision == 2 && model.error == nil,
                     "A failed refresh must retain the palette without disrupting the picker")
        let invalid = model.refreshTheme()
        try await pending("theme", backend)
        await backend.reply("theme", APIResult(theme: ThemePayload(background: "invalid")))
        await invalid?.value
        precondition(model.themeRevision == 2 && !PickerPalette.isDark,
                     "Malformed colors must not replace the last valid palette")
        let retry = model.refreshTheme()
        try await pending("theme", backend)
        await backend.reply("theme", APIResult(theme: dark))
        await retry?.value
        precondition(model.themeRevision == 3 && PickerPalette.isDark,
                     "Theme lookup must remain retryable after an error or invalid payload")
        let late = model.refreshTheme()
        try await pending("theme", backend)
        model.close()
        await backend.reply("theme", APIResult(theme: light))
        await late?.value
        precondition(model.themeRevision == 3 && PickerPalette.isDark && model.refreshTheme() == nil,
                     "Closed models must reject late themes and new refreshes")
        PickerPalette.useFallback(dark: true)
        print("PASS: asynchronous Rex theme refresh, request coalescing, cached Open, stable picker state, selected text, material repaint, unchanged/error/invalid responses, retry and close")
    }

    @MainActor private static func warmReopenChecks() async throws {
        let options = try LaunchOptions(arguments: ["--demo", "--session", "S", "--block", "B", "--client", "C", "--title", "T"])
        let repos = APIResult(items: ["/a", "/b", "/c"].map { PickerItem(path: $0) }, targets: ["tab", "session"], target: "tab")
        // Zero TTL forces an expired refresh without a wall-clock sleep.
        for ttl: TimeInterval in [30, 0] {
            let backend = CachedListBackend()
            let model = PickerModel(options: options, backend: backend, cacheTTL: ttl)
            model.start()
            try await pending("directories", backend)
            await backend.reply("directories", repos)
            try await wait { !model.refreshing && model.themeLoaded }
            model.selectedID = "/b"; model.scrollID = "/c"; model.target = "session"
            model.query = "filtered"
            try await pending("directories", backend)
            await backend.reply("directories", APIResult(items: [PickerItem(path: "/filtered")], targets: ["tab"], target: "tab"))
            try await wait { !model.refreshing }
            model.switchView()
            try await pending("agents", backend)
            await backend.reply("agents", APIResult(items: [PickerItem(path: "A", kind: "agent", sessionID: "S", windowID: "W", blockID: "B")]))
            try await wait { !model.refreshing }

            let token = model.prepareReconfigure(options)
            precondition(model.contextReady && model.canOpen && !model.loading && model.view == .repos && model.page == .directories && model.query.isEmpty,
                         "Warm same-context reopen must enable Open synchronously, before any backend reply")
            precondition(model.items == repos.items && model.selectedID == "/b" && model.scrollID == "/c" && model.targets == ["tab", "session"] && model.target == "session",
                         "Warm reopen must restore unfiltered repos, selection, scroll and valid cached targets")
            await model.completeReconfigure(token)
            if ttl == 0 { try await pending("directories", backend) }
            for _ in 0..<10 {
                await model.reconfigure(options)
                precondition(model.canOpen && model.target == "session" && model.selectedID == "/b" && model.scrollID == "/c")
                await Task.yield()
            }
            let contexts = await backend.count("context")
            let themes = await backend.count("theme")
            let directories = await backend.count("directories")
            precondition(contexts == 0 && themes == 1 && directories == (ttl == 0 ? 3 : 2),
                         "Warm reopen must skip context/theme RPCs, honor TTL and coalesce an in-flight refresh")
            model.choose()
            try await wait { !model.busy }
            let opens = await backend.count("dispatch")
            precondition(opens == 1, "Cached Open must dispatch before the background directory reply")
            if ttl == 0 { await backend.reply("directories", repos) }
            model.close()
        }

        // Each backend context component must independently disable the fast path.
        for flag in ["--session", "--block", "--client", "--title"] {
            let backend = CachedListBackend()
            let model = PickerModel(options: options, backend: backend)
            model.start()
            try await pending("directories", backend)
            await backend.reply("directories", repos)
            try await wait { !model.refreshing && model.themeLoaded }
            await backend.hold("context")
            let changed = try LaunchOptions(arguments: ["--demo", "--session", "S", "--block", "B", "--client", "C", "--title", "T", flag, "changed"])
            let token = model.prepareReconfigure(changed)
            precondition(!model.contextReady && !model.canOpen && model.targets.isEmpty && model.target.isEmpty,
                         "A changed context component must gate actions and discard cached targets")
            model.choose(); model.showWorktrees(); model.switchView()
            let completion = Task { await model.completeReconfigure(token) }
            try await pending("context", backend)
            let directoryCalls = await backend.count("directories")
            let dispatches = await backend.count("dispatch")
            precondition(directoryCalls == 1 && dispatches == 0 && !model.contextReady)
            await backend.reply("context", APIResult())
            await completion.value
            try await pending("directories", backend)
            precondition(!model.canOpen, "Context acknowledgement alone must not trust old-origin targets")
            await backend.reply("directories", repos)
            try await wait { !model.refreshing }
            precondition(model.canOpen)
            let themes = await backend.count("theme")
            precondition(themes == 1, "A loaded theme must not reload on reopen")
            model.close()
        }
        print("PASS: synchronous warm reopen, unfiltered repos and targets, pre-reply Open, theme/context RPC bypass, refresh TTL/coalescing, all changed-context components gated")
    }

    @MainActor private static func pending(_ method: String, _ backend: CachedListBackend) async throws {
        for _ in 0..<150 {
            if await backend.waiting(method) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        preconditionFailure("Timed out waiting for \(method)")
    }

    @MainActor private static func suggestedBranchChecks() async throws {
        let decoded = try JSONDecoder().decode(APIResult.self, from: Data(#"{"suggested_branch":"amber-falcon"}"#.utf8))
        precondition(decoded.suggestedBranch == "amber-falcon")
        let options = try LaunchOptions(arguments: ["--demo", "--mode", "wt-create", "--repo", "/demo"])
        let demo = DemoBackend()
        let direct = PickerModel(options: options, backend: demo)
        direct.start()
        direct.submitBranch() // Loading Enter must not be queued.
        try await wait { direct.canCreate }
        precondition(direct.branch == "amber-falcon" && direct.base == "main" && direct.target == "tab")
        precondition(direct.destination == "/Users/demo/Projects/example-kit-worktrees/amber-falcon")
        let before = await demo.count("worktrees.create")
        precondition(before == 0 && !direct.basePickerPresented)
        direct.submitBranch()
        direct.submitBranch()
        try await wait { direct.createdPath != nil && !direct.busy }
        let creates = await demo.count("worktrees.create"), opens = await demo.count("dispatch")
        precondition(creates == 1 && opens == 1, "One Enter creates and opens; repeated Enter cannot duplicate")
        let params = await demo.parameters("worktrees.create")
        if case .text("amber-falcon") = params["branch"], case .text("main") = params["base"],
           case .text("/Users/demo/Projects/example-kit") = params["repo"] {} else { preconditionFailure("Wrong default create params") }
        let dispatch = await demo.parameters("dispatch")
        if case .text("tab") = dispatch["target"], case .text("/Users/demo/Projects/example-kit-worktrees/amber-falcon") = dispatch["path"] {} else { preconditionFailure("Wrong default dispatch") }
        direct.close()

        // Explicit metadata responses cover loading, early edits and authoritative collisions.
        for edit in [nil, "feat/early", ""] as [String?] {
            let backend = CachedListBackend()
            await backend.hold("worktrees.preview")
            let model = PickerModel(options: options, backend: backend)
            model.start()
            try await pending("worktrees.list", backend)
            if let edit { model.editBranch(edit) }
            model.submitBranch()
            await backend.reply("worktrees.list", APIResult(targets: ["tab"], target: "tab", repo: "/demo",
                branches: ["main"], baseBranch: "main", suggestedBranch: "quiet-otter"))
            try await wait { !model.loading }
            precondition(model.branch == (edit ?? "quiet-otter"), "Metadata must preserve early typing and explicit blank")
            if edit != "" {
                try await pending("worktrees.preview", backend)
                model.submitBranch()
                await backend.reply("worktrees.preview", APIResult(path: "/demo/new", validationError: "Branch already exists"))
                try await wait { model.previewReady }
                model.submitBranch()
                precondition(!model.canCreate && !model.basePickerPresented)
            }
            let count = await backend.count("worktrees.create")
            precondition(count == 0, "Loading or collision must block Enter")
            model.close()
        }

        let backend = CachedListBackend()
        let listOptions = try LaunchOptions(arguments: ["--demo", "--mode", "wt", "--repo", "/demo"])
        let list = PickerModel(options: listOptions, backend: backend)
        func metadata(_ suggestion: String?) -> APIResult {
            APIResult(items: [PickerItem(path: "/demo/main")], targets: ["tab"], target: "tab", repo: "/demo",
                      destinationRoot: "/trees", branches: ["main"], baseBranch: "main", suggestedBranch: suggestion)
        }
        list.start()
        try await pending("worktrees.list", backend)
        await backend.reply("worktrees.list", metadata("first-otter"))
        try await wait { !list.loading }
        list.query = "refresh"
        try await pending("worktrees.list", backend)
        await backend.reply("worktrees.list", metadata("fresh-otter"))
        try await wait { !list.refreshing }
        list.beginCreate()
        precondition(list.branch == "fresh-otter" && list.base == "main", "List entry must prefill synchronously with current metadata")
        list.query = "default-form-query"
        try await Task.sleep(for: .milliseconds(200))
        precondition(list.branch == "fresh-otter", "Query must not replace the initial default")
        list.editBranch("feat/custom")
        list.query = "ignored-form-query"
        try await Task.sleep(for: .milliseconds(200))
        precondition(list.branch == "feat/custom", "Query must not rename the form")
        list.escape()
        try await pending("worktrees.list", backend)
        await backend.reply("worktrees.list", metadata("next-otter"))
        try await wait { !list.refreshing }
        list.beginCreate()
        precondition(list.branch == "next-otter" && !list.branchWasEdited, "New form resets edit/default flags")
        list.escape()
        try await pending("worktrees.list", backend)
        await backend.reply("worktrees.list", metadata(nil))
        try await wait { !list.refreshing }
        list.beginCreate()
        precondition(list.branch.isEmpty && !list.canCreate, "Missing suggestion requires manual input")
        list.editBranch("feat/manual")
        precondition(list.branch == "feat/manual" && list.branchWasEdited)
        list.close()

        let continuation = PickerModel(options: try LaunchOptions(arguments: ["--demo", "--mode", "wt-create"]), backend: DemoBackend())
        continuation.start()
        try await wait { continuation.page == .repositories && !continuation.loading }
        continuation.choose()
        try await wait { continuation.canCreate }
        precondition(continuation.branch == "amber-falcon")
        continuation.editBranch("feat/old-repo")
        let newRepoOptions = try LaunchOptions(arguments: ["--demo", "--mode", "wt-create", "--repo", "/another-repo"])
        let token = continuation.prepareReconfigure(newRepoOptions)
        precondition(continuation.branch.isEmpty && !continuation.branchWasEdited)
        await continuation.completeReconfigure(token)
        try await wait { continuation.canCreate }
        precondition(continuation.branch == "amber-falcon")
        continuation.close()
        print("PASS: suggested branch decoding, direct/list prefill, one-Enter create/open, early edits/blank, refresh, reset, missing suggestion, collision and loading gates")
    }

    @MainActor private static func directCreateChecks() async throws {
        let options = try LaunchOptions(arguments: ["--demo", "--mode", "wt-create", "--repo", "/origin"])
        precondition(options.mode == "wt-create" && options.repo == "/origin")
        let backend = DelayedMetadataBackend()
        let direct = PickerModel(options: options, backend: backend)
        precondition(direct.page == .create && direct.loading && !direct.canSubmitForm,
                     "Direct launch must render a disabled form before starting backend work")
        direct.start()
        direct.branch = "feat/typed-early"
        direct.create()
        try await Task.sleep(for: .milliseconds(230))
        let pendingMethods = await backend.methods()
        precondition(direct.page == .create && direct.branch == "feat/typed-early" && !direct.canCreate)
        precondition(pendingMethods.filter { $0 != "theme" } == ["worktrees.list"], "Metadata must precede preview and create")
        try await wait { direct.canCreate }
        let origin = await backend.requestedRepo()
        precondition(origin == "/origin" && direct.repo == "/resolved" && direct.items.isEmpty)
        precondition(direct.branch == "feat/typed-early" && direct.base == "main")
        precondition(PickerStyle.height(for: direct) == 240)
        direct.validationError = "Branch already exists"
        precondition(!direct.canSubmitForm && PickerStyle.height(for: direct) == 264)
        direct.error = "Backend error"
        precondition(PickerStyle.height(for: direct) == 296)
        direct.validationError = nil
        direct.error = nil
        let targets = ["tab", "session", "here", "pane_right", "pane_below"]
        let labels = ["New tab", "Session", "cd here", "Split right", "Split below"]
        precondition(direct.targets == targets)
        for (target, label) in zip(targets, labels) {
            precondition(direct.target == target && PickerModel.targetLabel(target) == label)
            direct.cycleTarget(backward: false)
        }
        precondition(direct.target == "tab", "Ctrl+O must wrap through all five targets")
        for target in targets.reversed() {
            direct.cycleTarget(backward: true)
            precondition(direct.target == target)
        }
        var closed = false
        direct.onClose = { closed = true }
        direct.onDismiss = { direct.close() } // Nonresident idle dismissal.
        direct.basePickerPresented = true
        direct.escape()
        precondition(!direct.basePickerPresented && !closed && direct.page == .create)
        direct.escape()
        precondition(closed, "Direct Escape must close, not show a worktree list")

        let slow = PickerModel(options: options, backend: DelayedMetadataBackend())
        var slowClosed = false
        slow.onClose = { slowClosed = true }
        slow.onDismiss = { slow.close() } // Nonresident idle dismissal.
        slow.start()
        slow.branch = "feat/typed-early"
        try await Task.sleep(for: .milliseconds(40))
        slow.escape()
        precondition(slowClosed && !slow.canCreate, "Escape must work while metadata loads")
        try await Task.sleep(for: .milliseconds(350))
        precondition(slow.repo == "/origin" && slow.base.isEmpty && !slow.previewReady,
                     "Late metadata must not update a closed picker")

        let fallback = PickerModel(options: try LaunchOptions(arguments: ["--demo", "--mode", "wt-create"]), backend: DemoBackend())
        fallback.start()
        precondition(fallback.page == .create)
        try await wait { !fallback.loading }
        precondition(fallback.page == .repositories && !fallback.items.isEmpty)
        fallback.choose()
        precondition(fallback.page == .create && fallback.loading && !fallback.canCreate,
                     "Repository selection must continue directly to the form")
        fallback.branch = "feat/repository"
        try await wait { fallback.canCreate }
        precondition(fallback.page == .create && fallback.items.isEmpty && fallback.branch == "feat/repository")
        fallback.close()
        print("PASS: immediate direct form, origin metadata, early typing, disabled submit, close during load, stale metadata, direct repository continuation, direct Escape/popover, five target labels and bidirectional cycling")
    }

    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        preconditionFailure("Timed out waiting for model")
    }

    @MainActor private static func themeIntegrationChecks() async throws {
        let options = try LaunchOptions(arguments: [])
        let backend = ProcessBackend(options: options)
        let result = try await backend.request("theme", params: [:])
        precondition(result.theme?.name == "Wire Forest" && result.theme?.background == "#102030" &&
                     result.theme?.ui?.selection == "#bfbfbf",
                     "Real Go NDJSON must decode result.theme, not silently drop a flat palette")
        let model = PickerModel(options: options, backend: backend)
        await model.refreshTheme()?.value
        precondition(model.themeRevision == 1 && model.themeLoaded && PickerPalette.isDark,
                     "The real backend must update the native model's palette")
        precondition(NSColor(PickerStyle.background) == NSColor(hexColor("#333333")!) &&
                     NSColor(PickerStyle.selection) == NSColor(hexColor("#bfbfbf")!) &&
                     NSColor(PickerStyle.selectionText) == NSColor(hexColor("#1a191a")!) &&
                     PickerPalette.selectionOpacity == 0.75,
                     "Native selection must use UI tokens, not terminal selection colors")
        let label = NSColor(PickerStyle.foreground).usingColorSpace(.sRGB)!
        precondition(abs(label.redComponent - label.greenComponent) < 0.01 &&
                     abs(label.greenComponent - label.blueComponent) < 0.01,
                     "Glass chrome must keep native neutral labels, not green terminal text")
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: .zero)
            glass.wantsLayer = true
            PickerStyle.applyPanelTheme(to: glass)
            precondition(glass.tintColor == NSColor(hexColor("#333333")!).withAlphaComponent(0.35),
                         "Real backend colors must reach the panel material")
        }
        model.close()
        print("PASS: real Go backend → NDJSON → Swift decoding → model → selected text and native panel tint")
    }

    private static func transportChecks() async throws {
        let options = try LaunchOptions(arguments: ["--session", "S", "--block", "B", "--client", "C", "--title", "A title"])
        let dismissed = ProcessBackend(options: options)
        dismissed.close() // Closing before the first request must not start a child.
        do {
            _ = try await dismissed.request("ok", params: [:])
            preconditionFailure("Closed connection survived close")
        } catch {}
        let backend = ProcessBackend(options: options)
        _ = try await backend.request("ok", params: [:])
        do {
            _ = try await backend.request("error", params: [:])
            preconditionFailure("API error accepted")
        } catch { precondition(error.localizedDescription == "fixture error", "Unexpected error: \(error.localizedDescription)") }
        _ = try await backend.request("ok", params: [:])
        backend.close()
        for method in ["bad-id", "malformed", "eof", "both", "no-result"] {
            let connection = ProcessBackend(options: options)
            do {
                _ = try await connection.request(method, params: [:])
                preconditionFailure("Invalid transport accepted: \(method)")
            } catch {}
            do {
                _ = try await connection.request("ok", params: [:])
                preconditionFailure("Broken connection reused: \(method)")
            } catch {}
            connection.close()
        }
        let blocked = ProcessBackend(options: options)
        let pending = Task { try await blocked.request("hang", params: [:]) }
        try await Task.sleep(for: .milliseconds(100))
        blocked.close()
        do {
            _ = try await pending.value
            preconditionFailure("In-flight request survived close")
        } catch {}
        print("PASS: persistent NDJSON, split reads, valid API error recovery, ID mismatch, malformed JSON, EOF, invalid envelopes, closed connection, in-flight shutdown")
    }
}
