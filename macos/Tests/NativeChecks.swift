import Foundation

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
        if ["directories", "sessions", "worktrees.list"].contains(method) || held.contains(method) {
            return try await withCheckedThrowingContinuation { pending[method, default: []].append($0) }
        }
        return APIResult()
    }
}

@main
struct NativeChecks {
    @MainActor static func main() async throws {
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
        for mode in ["WT-CREATE", "wt-create-extra", "wt-create ", ""] {
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
        try await residentChecks()
        try await cachedListChecks()
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
        retry.create(); retry.create()
        try await wait { !retry.busy }
        let firstCounts = await retryBackend.counts()
        precondition(firstCounts.0 == 1 && firstCounts.1 == 1 && retry.createdPath == "/demo/new-worktree")
        precondition(retry.error?.contains("Worktree created, but opening failed") == true && retry.canSubmitForm && !retry.canCreate)
        retry.cycleTarget(backward: false)
        retry.create(); retry.create() // Retry the open step only, even after repeated submission.
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

    @MainActor private static func residentChecks() async throws {
        // Tabs & Sessions view over the long-lived model.
        let tabsBackend = DemoBackend()
        let tabs = PickerModel(options: try LaunchOptions(arguments: ["--demo"]), backend: tabsBackend)
        tabs.start()
        try await wait { !tabs.loading }
        precondition(tabs.view == .repos && tabs.page == .directories && tabs.showsPills)
        tabs.switchView()
        try await wait { !tabs.loading }
        precondition(tabs.view == .tabs && tabs.items.count == 5 && tabs.items.first?.kind == "session",
                     "Tabs view must list sessions and windows")
        precondition(tabs.items.contains { $0.kind == "window" && $0.active == true }, "Active windows must be marked")
        precondition(PickerStyle.height(for: tabs) == 276, "Tabs view must use the same compact row height")
        tabs.openNumbered(2)
        try await wait { !tabs.busy }
        let jumpCount = await tabsBackend.count("sessions.jump")
        precondition(jumpCount == 1, "Numbered open must jump to the tab")
        tabs.selectedID = tabs.items.last?.id
        tabs.requestCloseEntry()
        precondition(tabs.removalCandidate != nil, "Tabs must confirm before closing")
        tabs.confirmCloseEntry()
        try await wait { !tabs.busy }
        try await wait { !tabs.loading }
        precondition(tabs.items.count == 4, "Closing a tab must refresh the list")
        tabs.selectedID = tabs.items.first?.id
        tabs.beginRename()
        tabs.renameLabel = "renamed"
        tabs.commitRename()
        try await wait { !tabs.busy }
        try await wait { !tabs.loading }
        precondition(tabs.items.contains { $0.label == "renamed" }, "Rename must refresh the tabs list")
        let renameCount = await tabsBackend.count("sessions.rename")
        precondition(renameCount == 1, "Rename must be requested once")
        tabs.switchView()
        try await wait { !tabs.loading }
        precondition(tabs.view == .repos && tabs.page == .directories, "Escape-level switch must return to repos")
        tabs.close()

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
        print("PASS: tabs and sessions view, numbered jump, close confirmation, rename, pins, resident reconfigure")
    }

    @MainActor private static func cachedListChecks() async throws {
        let backend = CachedListBackend()
        let model = PickerModel(options: try LaunchOptions(arguments: ["--demo"]), backend: backend)
        let repos = APIResult(items: ["/a", "/b", "/c"].map { PickerItem(path: $0) }, targets: ["tab", "session"], target: "tab")
        let sessions = APIResult(items: ["S1", "S2", "S3"].map { PickerItem(path: $0, kind: "session") })
        model.start()
        try await pending("directories", backend)
        await backend.reply("directories", repos)
        try await wait { !model.refreshing }
        model.selectedID = "/b"; model.scrollID = "/c"; model.target = "session"
        model.switchView()
        precondition(model.loading && model.items.isEmpty && model.selectedID == nil && model.scrollID == nil,
                     "An uncached view must clear the other view before its request starts")
        try await pending("sessions", backend)
        await backend.reply("sessions", sessions)
        try await wait { !model.refreshing }
        model.selectedID = "S2"; model.scrollID = "S3"
        model.switchView()
        precondition(!model.loading && model.refreshing && model.canOpen && model.selectedID == "/b" && model.scrollID == "/c" && model.target == "session",
                     "Cached repos must restore selection, scroll and target before refreshing, with Open enabled")
        try await pending("directories", backend)
        model.switchView()
        precondition(!model.loading && model.canOpen && model.selectedID == "S2" && model.scrollID == "S3")
        try await pending("sessions", backend)
        await backend.reply("directories", APIResult(items: [PickerItem(path: "/obsolete")]))
        await backend.reply("sessions", APIResult(items: [PickerItem(path: "S1", kind: "session")]))
        try await wait { !model.refreshing }
        precondition(model.selectedID == "S1" && model.scrollID == nil,
                     "Refresh must repair selection and scroll when their rows disappear")
        model.switchView()
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
        try await pending("sessions", backend)
        model.switchView()
        precondition(model.query == "filtered" && model.selectedID == "/c" && model.scrollID == "/b" && model.canOpen,
                     "Each view must retain its own query and list position")
        try await pending("directories", backend)
        model.openNumbered(2)
        try await wait { !model.busy }
        let cachedDispatches = await backend.count("dispatch")
        precondition(cachedDispatches == 1, "Cached numbered Open must not wait for refresh")
        // Dispatch invalidates both lists: a new session may now exist.
        await backend.reply("sessions", sessions)
        await backend.reply("directories", repos)
        model.switchView()
        precondition(model.loading && model.items.isEmpty)
        try await pending("sessions", backend)
        await backend.reply("sessions", sessions)
        try await wait { !model.refreshing }
        model.beginRename(); model.renameLabel = "renamed"; model.commitRename()
        try await wait { !model.busy }
        precondition(model.loading && model.items.isEmpty, "Mutation refresh must not reuse pre-mutation rows")
        try await pending("sessions", backend)
        await backend.fail("sessions")
        try await wait { !model.refreshing }
        model.switchView()
        precondition(model.loading && model.items.isEmpty, "Mutation must invalidate the other view too")
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
        precondition(model.loading && model.items.isEmpty, "New origin must not reuse old session rows")
        try await pending("sessions", backend)
        await backend.reply("sessions", sessions)
        try await wait { !model.refreshing }
        precondition(model.repo == "/new-repo" && model.base == "main",
                     "Session replies on the worktree page must not replace repository metadata")
        model.switchView()
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
        mutation.beginRename(); mutation.requestCloseEntry(); mutation.confirmCloseEntry(); mutation.commitRename()
        mutation.askRemove(); mutation.confirmRemove(PickerItem(path: "/old", isMain: false))
        mutation.create(); mutation.openCreated(); mutation.cycleTarget(backward: false); mutation.toggleSplit()
        precondition(mutation.page == .directories && mutation.view == .repos && mutation.repo == nil && !mutation.busy && mutation.removalCandidate == nil && mutation.renameCandidate == nil,
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

    @MainActor private static func pending(_ method: String, _ backend: CachedListBackend) async throws {
        for _ in 0..<150 {
            if await backend.waiting(method) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        preconditionFailure("Timed out waiting for \(method)")
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
        direct.basePickerPresented = true
        direct.escape()
        precondition(!direct.basePickerPresented && !closed && direct.page == .create)
        direct.escape()
        precondition(closed, "Direct Escape must close, not show a worktree list")

        let slow = PickerModel(options: options, backend: DelayedMetadataBackend())
        var slowClosed = false
        slow.onClose = { slowClosed = true }
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
