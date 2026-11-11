import Foundation
import AppKit
import SwiftUI

// Check failures must exit cleanly instead of trapping: a precondition trap
// makes macOS file a crash report for every headless assertion failure.
private func require(_ condition: Bool, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) {
    if !condition {
        testFailure(message.isEmpty ? "check failed at \(file):\(line)" : message)
    }
}

private func testFailure(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(2)
}

// Standalone headless checks. Compile with Backend, DemoBackend and PickerModel,
// not RaptorApp. No NSApplication, panel, Rex call or live file operation.
private actor ScriptedBackend: BackendClient {
    private var calls: [String] = []
    nonisolated func close() {}
    func count(_ method: String) -> Int { calls.filter { $0 == method }.count }
    func request(_ method: String, params: [String: APIValue]) async throws -> APIResult {
        calls.append(method)
        if method == "sessions" {
            var query = ""
            if case let .text(value) = params["query"] { query = value }
            // The first response arrives after the second response.
            await delay(query == "old" ? 0.45 : 0.02)
            return APIResult(items: [PickerItem(path: "/demo/" + query, kind: "dir")], targets: ["tab", "session"], target: "tab")
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
                testFailure("Preview ran before metadata or lost entered branch")
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
private actor EventCounter {
    private var value = 0
    func increment() { value += 1 }
    func count() -> Int { value }
}

private actor CachedListBackend: BackendClient {
    private let events: Bool
    private var handler: (@Sendable () -> Void)?
    private var oldHandler: (@Sendable () -> Void)?
    init(events: Bool = false) { self.events = events }
    func setChangeHandler(_ handler: (@Sendable () -> Void)?) async throws -> Bool {
        guard events else { return false }
        calls.append(handler == nil ? "unsubscribe" : "subscribe")
        oldHandler = self.handler
        self.handler = handler
        return true
    }
    func emit(_ times: Int = 1, stale: Bool = false) {
        for _ in 0..<times { (stale ? oldHandler : handler)?() }
    }
    func methods() -> [String] { calls }
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
        guard waiting(method) else { testFailure("Reply for \(method) arrived with no pending call") }
        pending[method]!.removeFirst().resume(returning: result)
    }
    func replyLatest(_ method: String, _ result: APIResult) {
        guard waiting(method) else { testFailure("Reply for \(method) arrived with no pending call") }
        pending[method]!.removeLast().resume(returning: result)
    }
    func fail(_ method: String) {
        guard waiting(method) else { testFailure("Failure for \(method) arrived with no pending call") }
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

@MainActor
private final class ShortcutEditor: NSTextView {
    var lastAction = ""
    override func paste(_ sender: Any?) { lastAction = "v" }
    override func copy(_ sender: Any?) { lastAction = "c" }
    override func cut(_ sender: Any?) { lastAction = "x" }
    override func selectAll(_ sender: Any?) { lastAction = "a" }
}

@main
struct NativeChecks {
    @MainActor static func main() async {
        do { try await run() } catch {
            // An unhandled top-level error also traps; report it cleanly instead.
            testFailure("Unhandled error: \(error)")
        }
    }

    @MainActor private static func outsideClickChecks() {
        let panel = NSRect(x: 100, y: 100, width: 640, height: 300)
        let popover = NSRect(x: 740, y: 180, width: 240, height: 180)
        let sheet = NSRect(x: 180, y: 330, width: 400, height: 180)
        let frames = [panel, popover, sheet]
        for point in [NSPoint(x: 200, y: 200), NSPoint(x: 800, y: 200), NSPoint(x: 300, y: 480)] {
            require(!OutsideClickMonitor.isOutside(point, frames: frames), "Picker, popover and sheet clicks must remain inside")
        }
        require(OutsideClickMonitor.isOutside(NSPoint(x: 40, y: 40), frames: frames))
        require(OutsideClickMonitor.isOutside(NSPoint(x: 1500, y: 200), frames: frames))
        require(OutsideClickMonitor.isOutside(.zero, frames: []))
        let monitor = OutsideClickMonitor()
        monitor.stop(); monitor.stop() // Dismiss/terminate cleanup is idempotent.
        let model = PickerModel(options: try! LaunchOptions(arguments: ["--demo", "--mode", "pr"]), backend: DemoBackend())
        model.prInput = "https://github.com/o/r/pull/12"
        model.basePickerPresented = true; model.targetPickerPresented = true
        model.prCommitConfirmationPresented = true
        model.removalCandidate = PickerItem(path: "/keep")
        model.createdPath = "/preserved"; model.error = "Retry opening"
        var dismissals = 0
        model.onDismiss = { dismissals += 1 }
        model.dismissForOutsideClick()
        require(dismissals == 1 && !model.basePickerPresented && !model.targetPickerPresented && !model.prCommitConfirmationPresented && model.removalCandidate == nil)
        require(model.page == .pr && model.prInput == "https://github.com/o/r/pull/12" && model.createdPath == "/preserved" && model.error == "Retry opening" && !model.backendIsClosed,
                "Outside click must keep form input and worktree recovery, without closing the backend")
        model.close()
        print("PASS: outside-click hit regions include popovers/sheets; dismissal clears transient UI and preserves input/recovery")
    }

    @MainActor private static func textEditingChecks() {
        let editor = ShortcutEditor()
        editor.isEditable = true
        for key in ["v", "c", "x", "a"] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: 0, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
            require(TextEditingShortcuts.perform(event, responder: editor))
            require(editor.lastAction == key, "Editing shortcut must reach the current editor")
            require(!TextEditingShortcuts.perform(event, responder: NSResponder()))
            editor.isEditable = false
            require(!TextEditingShortcuts.perform(event, responder: editor))
            editor.isEditable = true
        }
        print("PASS: accessory-panel paste/copy/cut/select-all route to editable text only")
    }

    @MainActor private static func run() async throws {
        if CommandLine.arguments.contains("--theme-integration") {
            try await themeIntegrationChecks()
            return
        }
        textEditingChecks()
        outsideClickChecks()
        try await pullRequestClipboardChecks()
        try await pullRequestChecks()
        try await pullRequestCommitChoiceChecks()
        try await createdLauncherSnapshotChecks()
        try await RexFocusChecks.run()
        try await searchLatencyChecks()
        require(PickerStyle.panelAnimationBehavior(reduceMotion: false) == .default,
                     "Panel presentation must use resh's default AppKit animation")
        require(PickerStyle.panelAnimationBehavior(reduceMotion: true) == .none,
                     "Reduced Motion must disable panel presentation animation")
        let options = try LaunchOptions(arguments: ["--demo", "--mode", "wt", "--repo", "/demo", "--session", "S", "--block", "B", "--client", "C", "--title", "A title"])
        require(options.backendArguments == ["--session", "S", "--block", "B", "--client", "C", "--title", "A title", "api"])
        let sessionsMode = try LaunchOptions(arguments: ["--mode", "sessions", "--session", "S", "--block", "B", "--client", "C"])
        require(sessionsMode.mode == "sessions")
        // Empty context values are omitted: flag parsing stops at the first
        // non-flag argument, and an empty string is non-flag.
        require(sessionsMode.backendArguments == ["--session", "S", "--block", "B", "--client", "C", "api"])
        let sessionsPanel = try LaunchOptions(panelRequest: PanelRequest(mode: "sessions", session: "S", block: "B", client: "C"))
        require(sessionsMode.matches(sessionsPanel), "The panel variant must route Sessions like the flag form")
        do {
            _ = try LaunchOptions(arguments: ["--repo"])
            testFailure("Missing argument accepted")
        } catch {}
        for mode in ["WT-CREATE", "wt-create-extra", "wt-create ", "AGENTS", "agents-extra", "agents ", "SESSIONS", "sessions-extra", "sessions ", ""] {
            do {
                _ = try LaunchOptions(arguments: ["--mode", mode])
                testFailure("Invalid create mode accepted")
            } catch {}
        }
        let screen = CGRect(x: -1200, y: 200, width: 1200, height: 800)
        let frame = PickerStyle.panelFrame(in: screen, height: 220)
        let taller = PickerStyle.panelFrame(in: screen, height: 400)
        require(frame.midX == screen.midX && frame.maxY == screen.maxY - 72,
                     "Picker must anchor below the top of the active screen")
        require(taller.maxY == frame.maxY, "Content growth must preserve the top anchor")
        let decoded = try JSONDecoder().decode(APIResult.self, from: Data("{\"needs_repo\":false,\"base_branch\":\"main\",\"items\":[{\"path\":\"/a\",\"branch\":\"main\",\"is_main\":true}]}".utf8))
        require(decoded.items?.first?.isMain == true && decoded.baseBranch == "main")

        require(PickerStyle.rowFontSize == 13 && PickerStyle.rowHeight == 32 && PickerStyle.createHeaderHeight == PickerStyle.searchHeight,
                     "Launcher and form must share typography and control sizing")
        let sessionColor = PickerPalette.isDark ? "#ADD0AD" : "#396039"
        require(NSColor(PickerStyle.sessionText) == NSColor(hexColor(sessionColor)!),
                     "Session rows must use sage text instead of dimming folders")
        if PickerPalette.isDark {
            require(NSColor(PickerStyle.directoryText) == NSColor(hexColor("#C6C9C6")!),
                         "Folder rows must retain readable neutral text")
        }
        require(PickerModel.targetLabel("tab") == "New tab")
        require(PickerModel.targetLabel("session") == "Session")
        require(PickerModel.targetLabel("here") == "cd here")
        let launcher = PickerModel(options: try LaunchOptions(arguments: ["--demo"]), backend: SlowDirectoryBackend())
        let initialListHeight = PickerStyle.height(for: launcher)
        require(launcher.loading && initialListHeight == 338 && !launcher.showsPills,
                     "Launcher must reserve eight compact rows without a pills row")
        launcher.start()
        require(PickerStyle.height(for: launcher) == initialListHeight && !launcher.canOpen)
        try await wait { !launcher.loading }
        require(launcher.items.count == 30 && PickerStyle.height(for: launcher) == initialListHeight,
                     "Populated launcher must not jump from a search-sized window to a list")
        launcher.close()

        let backend = DemoBackend()
        let model = PickerModel(options: options, backend: backend)
        model.page = .worktrees // Internal creation/shared-helper coverage, not a native route.
        model.start()
        try await wait { !model.loading }
        require(model.page == .worktrees && model.items.count == 3)
        require(model.destinationRoot == "/Users/demo/Projects/example-kit-worktrees",
                     "Default destination must come from shared backend before branch input")
        require(PickerStyle.width == 640 && PickerStyle.height(for: model) == 198,
                     "The picker must use a wider layout with compact, content-fitted height")
        require(PickerStyle.rowHeight == 32 && PickerStyle.worktreeRowHeight == 28,
                     "Directory and worktree rows must keep Rex spacing")
        model.askRemove()
        require(model.removalCandidate == nil, "Main worktree must not be removable")
        model.move(1)
        model.askRemove()
        require(model.removalCandidate != nil)
        model.escape()
        require(model.removalCandidate != nil && model.page == .worktrees, "Esc must not navigate behind confirmation")
        let candidate = model.removalCandidate!
        model.removalCandidate = nil // SwiftUI can reset its presentation binding first.
        model.confirmRemove(candidate)
        model.confirmRemove(candidate) // Busy guard blocks repeated submission.
        try await wait { !model.busy && !model.loading }
        require(model.items.count == 2)
        model.beginCreate()
        require(PickerStyle.height(for: model) == 240, "Creation form grew beyond the compact layout")
        model.branch = "feat/test"
        try await wait { model.previewReady }
        require(model.canCreate && model.destination == "/Users/demo/Projects/example-kit-worktrees/feat-test")
        model.create()
        model.create()
        try await wait { !model.busy }
        require(model.createdPath != nil && model.notice?.contains("No Rex call") == true,
                     "Create must also open without a second click")
        model.escape()
        try await wait { !model.loading }
        require(model.page == .worktrees && model.items.count == 3, "Ordinary create must return to the list without repeated creation")
        model.toggleSplit()
        require(model.splitMode)
        model.escape()
        require(!model.splitMode && model.page == .worktrees)
        let previousTarget = model.target
        model.cycleTarget(backward: false)
        model.cycleTarget(backward: true)
        require(model.target == previousTarget)
        model.close()

        let compactList = PickerModel(options: options, backend: DemoBackend())
        compactList.page = .worktrees
        compactList.items = (0..<8).map { PickerItem(path: "/demo/\($0)", branch: "feat/\($0)") }
        let eightRowHeight = PickerStyle.height(for: compactList)
        compactList.items = (0..<30).map { PickerItem(path: "/demo/\($0)", branch: "feat/\($0)") }
        require(PickerStyle.height(for: compactList) == eightRowHeight && eightRowHeight == 338,
                     "Lists must stop growing after eight compact rows")
        let longBranch = PickerItem(path: "/demo/long", branch: "feat/" + String(repeating: "long-name-", count: 15))
        require(PickerStyle.branchLines(for: longBranch) == 2,
                     "Selected long branch names must wrap instead of sharing width with paths")
        compactList.items[0] = longBranch
        compactList.selectedID = longBranch.id
        require(PickerStyle.height(for: compactList) == eightRowHeight + PickerStyle.worktreeRowHeight,
                     "A wrapped selected branch needs one extra row without hiding the path detail")
        compactList.close()

        try await directCreateChecks()
        try await suggestedBranchChecks()
        try await residentChecks()
        try launcherEscapeChecks()
        try await agentsChecks()
        try await nativeSimplificationChecks()
        try await stableAgentsChecks()
        try await sessionsChecks()
        try await groupedActivityChecks()
        try await cachedListChecks()
        try await warmReopenChecks()
        try nativeThemeRoleChecks()
        try await themeRefreshChecks()
        try await dismissalChecks()
        try await residentNavigationWarmthChecks()
        // Retained internal browser metadata still supports shared creation helpers.
        let directoryCreate = PickerModel(options: try LaunchOptions(arguments: ["--demo"]), backend: DemoBackend())
        directoryCreate.start()
        try await wait { !directoryCreate.loading }
        let selectedDir = directoryCreate.items.first { $0.kind == "dir" }?.path
        directoryCreate.selectedID = selectedDir
        directoryCreate.showWorktrees()
        require(directoryCreate.page == .worktrees && directoryCreate.repo == selectedDir,
                     "Internal browser helper must retain the selected repository")
        try await wait { !directoryCreate.loading }
        directoryCreate.beginCreate()
        require(directoryCreate.page == .create && directoryCreate.repo == "/Users/demo/Projects/example-kit",
                     "New from worktrees must open Create in the backend-resolved repository")
        try await wait { !directoryCreate.loading }
        directoryCreate.escape()
        try await wait { !directoryCreate.loading }
        require(directoryCreate.page == .worktrees, "Create opened from worktrees must return there")
        directoryCreate.close()

        let fallback = PickerModel(options: try LaunchOptions(arguments: ["--demo", "--mode", "wt"]), backend: DemoBackend())
        fallback.start()
        try await wait { !fallback.loading }
        require(fallback.page == .directories && fallback.view == .sessions && !fallback.items.isEmpty,
                     "A worktree open without a repository must fall back to the launcher")
        fallback.selectedID = fallback.items.first?.id
        fallback.choose()
        try await wait { !fallback.busy }
        require(fallback.notice?.contains("No Rex call") == true, "Launcher fallback jump stays visible with its demo notice")
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
        require(stale.items.first?.path == "/demo/new", "Stale query replaced current results")
        require(PickerStyle.height(for: stale) == 146, "Filtered results must shrink the panel")
        stale.choose(); stale.choose()
        try await wait { !stale.busy }
        let dispatches = await scripted.count("dispatch")
        require(dispatches == 1, "Repeated Enter submitted twice")
        stale.close()

        let previewBackend = ScriptedBackend()
        let preview = PickerModel(options: options, backend: previewBackend)
        preview.page = .worktrees // Internal creation metadata helper coverage.
        preview.start()
        try await wait { !preview.loading }
        preview.beginCreate()
        try await Task.sleep(for: .milliseconds(250))
        let blankPreviews = await previewBackend.count("worktrees.preview")
        require(!preview.previewReady && preview.validationError == nil && blankPreviews == 0,
                     "An untouched branch field must not show premature validation")
        preview.branch = "old"
        try await Task.sleep(for: .milliseconds(220))
        preview.branch = "new"
        try await wait { preview.previewReady }
        try await Task.sleep(for: .milliseconds(350))
        require(preview.destination == "/demo/new" && preview.validationError == nil && preview.canCreate, "Stale preview or empty validation error blocked creation")
        preview.close()

        let retryBackend = CreateThenOpenBackend()
        let retry = PickerModel(options: try LaunchOptions(arguments: ["--demo", "--mode", "wt-create", "--repo", "/demo"]), backend: retryBackend)
        retry.start()
        try await wait { !retry.loading }
        require(retry.page == .create && !retry.loading)
        let baseMatches = try await retry.searchBaseBranches("backend-order")
        require(baseMatches == ["zeta", "alpha"], "Branch search must preserve the backend's matching and order")
        retry.branch = "feat/demo"
        try await wait { retry.canCreate }
        retry.basePickerPresented = true
        retry.create()
        let modalCounts = await retryBackend.counts()
        require(modalCounts.0 == 0 && modalCounts.1 == 0 && !retry.canSubmitForm,
                     "The branch popover must not submit the form beneath it")
        retry.escape()
        require(!retry.basePickerPresented && retry.page == .create && retry.branch == "feat/demo",
                     "Escape must dismiss the branch popover without discarding the form")
        retry.submitBranch(); retry.submitBranch()
        try await wait { !retry.busy }
        let firstCounts = await retryBackend.counts()
        require(firstCounts.0 == 1 && firstCounts.1 == 1 && retry.createdPath == "/demo/new-worktree")
        require(retry.error?.contains("Worktree created, but opening failed") == true && retry.canSubmitForm && !retry.canCreate)
        retry.cycleTarget(backward: false)
        retry.submitBranch(); retry.submitBranch() // Retry the open step only, even after repeated submission.
        try await wait { !retry.busy }
        let retriedCounts = await retryBackend.counts()
        let openedTargets = await retryBackend.targets()
        require(retriedCounts.0 == 1 && retriedCounts.1 == 2 && openedTargets == ["tab", "session"],
                     "A failed open retried creation or ignored the newly selected target")
        require(retry.error == nil && retry.notice?.contains("No Rex call") == true)
        retry.close()

        try await liveEventChecks()

        // Optional transport fixture exists only inside an aux test .app bundle.
        if CommandLine.arguments.contains("--transport-fixture") {
            try await transportChecks()
        }
        print("PASS: launch flags, decoding, launcher fallback, query generations, selection, target cycle, split cancel, confirmation, main protection, create-and-open, retry without recreation, untouched validation, backend branch search, popover isolation, duplicate submission")
    }

    @MainActor private static func nativeSimplificationChecks() async throws {
        for mode in ["agents", "wt"] {
            let options = try LaunchOptions(arguments: ["--mode", mode])
            require(options.mode == "sessions")
            require(try LaunchOptions(panelRequest: PanelRequest(mode: mode)).mode == "sessions")
            let model = PickerModel(options: options, backend: DemoBackend())
            model.start()
            try await wait { !model.loading }
            require(model.view == .sessions && model.page == .directories && !model.showsPills)
            model.close()
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/raptor/Host/PickerView.swift"), encoding: .utf8)
        let app = try String(contentsOf: root.appendingPathComponent("Sources/raptor/Host/RaptorApp.swift"), encoding: .utf8)
        for removed in ["view-pills", "pill-agents", "pill-sessions", "show-worktrees", "remove-worktree", "confirmRemove("] {
            require(!view.contains(removed), "Removed native UI: \(removed)")
        }
        for removed in ["key == \"a\"", "case \"t\":", "model.switchView(", "model.askRemove("] {
            require(!app.contains(removed), "Removed shortcut route: \(removed)")
        }
        let current = PickerItem(path: "current", kind: "session", active: true)
        let previous = PickerItem(path: "previous", kind: "session")
        let directory = PickerItem(path: "/repo", kind: "dir")
        let older = PickerItem(path: "older", kind: "session")
        require(PickerModel.preferredSelection(in: APIResult(items: [current, directory, previous, older])) == current.id)
        require(PickerModel.preferredSelection(in: APIResult(items: [current, directory])) == current.id,
                "The first row stays selected even when it is the current session")
        require(PickerModel.preferredSelection(in: APIResult(items: [current])) == current.id)
        require(PickerModel.preferredSelection(in: APIResult()) == nil)
        let decoded = try JSONDecoder().decode(APIResult.self, from: Data(#"{"selected_id":"previous"}"#.utf8))
        require(decoded.selectedID == "previous")
        let backend = CachedListBackend(events: true)
        let options = try LaunchOptions(arguments: ["--mode", "sessions"])
        let model = PickerModel(options: options, backend: backend)
        var result = APIResult(items: [current, previous, older, directory], selectedID: older.id, targets: ["session"], target: "session")
        require(PickerModel.preferredSelection(in: result) == current.id, "Displayed order wins over backend preference")
        require(PickerModel.preferredSelection(in: result, query: "ranked") == current.id)
        model.setPresented(true); model.start()
        try await pending("sessions", backend)
        await backend.reply("sessions", result)
        try await wait { !model.refreshing }
        require(model.selectedID == current.id && model.items.contains { $0.active == true })
        model.selectedID = directory.id
        await backend.emit()
        try await pending("sessions", backend)
        result.items?[0].label = "Refreshed current"
        await backend.reply("sessions", result)
        try await wait { model.items.first?.label == "Refreshed current" }
        require(model.selectedID == directory.id, "Live refresh preserves manual selection despite selected_id")
        model.dismiss()
        let token = model.prepareReconfigure(options)
        require(model.selectedID == current.id && !model.loading, "Warm reopen immediately resets manual selection to preferred row")
        await model.completeReconfigure(token)
        model.query = "ranked"
        try await pending("sessions", backend)
        await backend.reply("sessions", result)
        try await wait { !model.refreshing }
        require(model.selectedID == current.id, "Search uses ranked first row, not empty-query preference")
        model.query = ""
        require(model.selectedID == current.id, "Clearing query immediately restores cached preference")
        try await pending("sessions", backend)
        result.selectedID = nil
        await backend.reply("sessions", result)
        try await wait { !model.refreshing }
        require(model.selectedID == current.id, "Missing selected_id still selects the first row")
        model.selectedID = current.id
        model.dismiss()
        _ = model.prepareReconfigure(options)
        require(model.selectedID == current.id, "Legacy cached reopen selects the first row")
        model.close()
        let source = CachedListBackend()
        let noHistory = PickerModel(options: options, backend: source)
        noHistory.start()
        try await pending("sessions", source)
        await source.reply("sessions", APIResult(items: [current, directory], targets: ["session"], target: "session"))
        try await wait { !noHistory.refreshing }
        require(noHistory.selectedID == current.id && noHistory.items.first?.active == true)
        noHistory.selectedID = current.id
        _ = noHistory.prepareReconfigure(options)
        require(noHistory.selectedID == current.id && !noHistory.loading,
                "No-history source cached reopen selects the first row")
        noHistory.close()
        print("PASS: native modes normalized, no pills/browser shortcuts, preferred selection decoding/fallback, cached reopen, ranked search and live refresh preservation")
    }

    @MainActor private static func pullRequestClipboardChecks() async throws {
        let url = "https://github.com/o/r/pull/12"
        let options = try LaunchOptions(arguments: ["--mode", "pr"])
        for value in [nil, "", "12", "https://github.com/o/r/issues/12", "https://github.com.evil/o/r/pull/12", "\(url)/changes?overview=true", " \n\(url)/ \n"] as [String?] {
            let backend = CachedListBackend()
            let model = PickerModel(options: options, backend: backend, pullRequestClipboard: { value })
            model.start()
            let expected = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let valid = PickerModel.pullRequestLink(expected) != nil
            let wanted = PickerModel.normalizedPullRequestURL(expected) ?? ""
            var settled = false
            for _ in 0..<100 {
                if model.prInput == wanted { settled = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            require(settled, "Only canonical PR URLs may be prefilled")
            // Valid prefills resolve; wait for that to settle before judging
            // errors, so CI load cannot race the response.
            if valid {
                var resolved = false
                for _ in 0..<100 {
                    if await backend.count("pullrequests.resolve") >= 1 { resolved = true; break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                require(resolved, "A valid prefill must resolve")
            } else {
                try await Task.sleep(for: .milliseconds(120))
            }
            require(model.error == nil, "Ignored clipboard contents must not cause validation errors")
            require(await backend.count("pullrequests.resolve") == (valid ? 1 : 0))
            require(await backend.count("pullrequests.prepare") == 0, "Prefill must never create a worktree")
            model.close()
        }
        let backend = CachedListBackend()
        var reads = 0
        let launcher = try LaunchOptions(arguments: [])
        let model = PickerModel(options: launcher, backend: backend, pullRequestClipboard: { reads += 1; return url })
        model.start()
        require(reads == 0, "Do not read clipboard outside the PR form")
        model.beginPullRequest(input: "https://github.com/explicit/project/pull/99")
        require(model.prInput == "https://github.com/explicit/project/pull/99" && reads == 0,
                "Explicit search input must win over clipboard")
        model.escape()
        model.beginPullRequest()
        require(model.prInput == url && reads == 1, "Shortcut entry must prefill the clipboard")
        model.prInput = ""
        require(model.prInput.isEmpty && reads == 1, "Clearing the field must not refill it")
        model.escape()
        let token = model.prepareReconfigure(options)
        require(model.prInput == url && reads == 2, "Resident direct PR opens must prefill too")
        await model.completeReconfigure(token)
        model.close()
        print("PASS: PR clipboard prefill on direct/shortcut/resident entry, valid URLs only, explicit input wins, no mutation or refill after clearing")
    }

    @MainActor private static func createdLauncherSnapshotChecks() async throws {
        let decoded = try JSONDecoder().decode(APIResult.self, from: Data(#"{"launcher_items":[{"path":"new-session","kind":"session","session_id":"new-session","label":"new-worktree"}]}"#.utf8))
        require(decoded.launcherItems?.first?.label == "new-worktree")
        let old = PickerItem(path: "old-session", label: "original", kind: "session", sessionID: "old-session", active: true)
        let fresh = PickerItem(path: "new-session", label: "new-worktree", kind: "session", sessionID: "new-session")
        for method in ["pullrequests.open", "dispatch", "sessions.create"] {
            let backend = CachedListBackend()
            for name in [method, "pullrequests.resolve", "pullrequests.prepare", "worktrees.create"] { await backend.hold(name) }
            let mode = method == "pullrequests.open" ? "pr" : (method == "dispatch" ? "wt-create" : "sessions")
            let options = try LaunchOptions(arguments: ["--mode", mode, "--repo", "/repo", "--session", "old-session"])
            let model = PickerModel(options: options, backend: backend)
            model.keepsBackendWarmOnNavigation = true
            model.start()
            if method == "pullrequests.open" {
                model.prInput = "https://github.com/o/r/pull/12"
                try await pending("pullrequests.resolve", backend)
                await backend.reply("pullrequests.resolve", APIResult(repo: "/repo", path: "/new", number: 12, branch: "feat/new"))
                try await wait({ model.canOpenPullRequest }, label: "pr:canOpenPullRequest")
                model.openPullRequest()
                try await pending("pullrequests.prepare", backend)
                await backend.reply("pullrequests.prepare", APIResult(repo: "/repo", path: "/new"))
            } else if method == "dispatch" {
                try await pending("worktrees.list", backend)
                await backend.reply("worktrees.list", APIResult(targets: ["session", "tab", "here"], target: "session", repo: "/repo", branches: ["main"], baseBranch: "main"))
                try await wait({ !model.loading }, label: "dispatch:!loading")
                model.branch = "feat/new"; model.destination = "/new"; model.previewReady = true
                model.create()
                try await pending("worktrees.create", backend)
                await backend.reply("worktrees.create", APIResult(path: "/new"))
            } else {
                try await pending("sessions", backend)
                await backend.reply("sessions", APIResult(items: [old, PickerItem(path: "/new", kind: "dir")], targets: ["session", "tab", "here"], target: "session"))
                try await wait({ model.canOpen }, label: "sessions:canOpen")
                model.selectedID = "/new"
                model.choose()
            }
            try await pending(method, backend)
            await backend.reply(method, APIResult(launcherItems: [old, fresh], path: "/new", sessionID: "new-session"))
            try await wait({ !model.busy }, label: method + ":!busy")
            let before = await backend.count("sessions")
            let reopen = try LaunchOptions(arguments: ["--mode", "sessions", "--session", "new-session", "--block", "new-pane"])
            _ = model.prepareReconfigure(reopen)
            require(model.items.contains { $0.id == "new-session" && $0.label == "new-worktree" },
                    "\(method): the new resource must be visible synchronously on first reopen")
            require(await backend.count("sessions") == before, "Immediate display must not wait for a follow-up scan")
            require(!model.canOpen, "Cached mutation rows must still revalidate new origin targets")
            model.close()
        }
        print("PASS: PR/manual/session creation publishes known launcher rows before hide; first reopen needs no scan or delay")
    }

    @MainActor private static func pullRequestCommitChoiceChecks() async throws {
        let decoded = try JSONDecoder().decode(APIResult.self, from: Data(#"{"state":"CLOSED","head_deleted":true,"head_oid":"abc123"}"#.utf8))
        require(decoded.state == "CLOSED" && decoded.headDeleted == true && decoded.headOID == "abc123")
        let backend = CachedListBackend()
        for method in ["pullrequests.resolve", "pullrequests.prepare", "pullrequests.open"] { await backend.hold(method) }
        let model = PickerModel(options: try LaunchOptions(arguments: ["--mode", "pr"]), backend: backend)
        model.keepsBackendWarmOnNavigation = true
        model.start()
        model.prInput = "https://github.com/o/r/pull/12"
        try await pending("pullrequests.resolve", backend)
        await backend.reply("pullrequests.resolve", APIResult(repo: "/repo", path: "/original", number: 12,
            branch: "deleted", state: "CLOSED", headDeleted: true, headOID: "abc123"))
        try await wait { model.canOpenPullRequest }
        require(model.requiresPullRequestCommitChoice && PickerStyle.height(for: model) == 300)
        model.openPullRequest()
        require(model.prCommitConfirmationPresented && !model.busy && !model.canOpenPullRequest)
        require(model.pullRequestCommitExplanation.contains("pr/12") && model.pullRequestCommitExplanation.contains("closed"))
        require(await backend.count("pullrequests.prepare") == 0, "Offering commit checkout must not mutate")
        model.cancelPullRequestCommitCheckout()
        model.confirmPullRequestCommitCheckout()
        require(!model.busy, "Cancel must revoke permission to check out the commit")
        model.openPullRequest()
        model.escape()
        require(model.page == .pr && !model.prCommitConfirmationPresented, "Escape must cancel only the choice")
        model.openPullRequest()
        model.prInput = "https://github.com/o/r/pull/13"
        model.confirmPullRequestCommitCheckout()
        require(!model.prCommitConfirmationPresented && !model.busy, "Old confirmation must not apply to changed input")
        try await pending("pullrequests.resolve", backend)
        await backend.reply("pullrequests.resolve", APIResult(repo: "/repo", path: "/original13", number: 13,
            branch: "deleted13", state: "MERGED", headDeleted: true, headOID: "def456"))
        try await wait { model.canOpenPullRequest }
        model.openPullRequest()
        require(model.prCommitConfirmationPresented && model.pullRequestCommitExplanation.contains("merged"))
        // SwiftUI dismisses the alert binding before invoking its action.
        model.prCommitConfirmationPresented = false
        model.confirmPullRequestCommitCheckout()
        try await pending("pullrequests.prepare", backend)
        guard case .flag(true) = await backend.parameters("pullrequests.prepare")["checkout_commit"] else {
            testFailure("Explicit checkout must be sent only after confirmation")
        }
        await backend.reply("pullrequests.prepare", APIResult(repo: "/repo", path: "/pr13", number: 13,
            branch: "pr/13", state: "MERGED", headDeleted: true, headOID: "def456"))
        try await pending("pullrequests.open", backend)
        await backend.reply("pullrequests.open", APIResult(path: "/pr13", error: "selection failed"))
        try await wait { !model.busy }
        model.openPullRequest()
        require(!model.prCommitConfirmationPresented, "Preserved worktrees retry Open, not confirmation or Prepare")
        try await pending("pullrequests.open", backend)
        require(await backend.count("pullrequests.prepare") == 1)
        await backend.reply("pullrequests.open", APIResult(path: "/pr13"))
        try await wait { !model.busy }
        model.close()
        require(PickerStyle.errorSummary("wt switch: Fetching PR...\nfatal: couldn't find remote ref refs/heads/topic\nparse wt switch: unexpected end of JSON input") == "fatal: couldn't find remote ref refs/heads/topic")
        print("PASS: closed/deleted PR choice, cancel/Escape/stale-input safety, confirmed checkout flag, merged PR, recovery without recreation and meaningful error summaries")
    }

    @MainActor private static func pullRequestChecks() async throws {
        let options = try LaunchOptions(arguments: ["--mode", "pr", "--repo", "/repo", "--session", "original"])
        require(try LaunchOptions(panelRequest: PanelRequest(mode: "pr")).mode == "pr")
        require(ProcessBackend.timeoutSeconds(for: "pullrequests.prepare") == 600)
        require(ProcessBackend.timeoutSeconds(for: "pullrequests.resolve") == 180)
        require(ProcessBackend.timeoutSeconds(for: "pullrequests.open") == 180)
        for method in ["sessions", "directories", "worktrees.list", "theme"] {
            require(ProcessBackend.timeoutSeconds(for: method) == 30)
        }
        let decoded = try JSONDecoder().decode(APIResult.self, from: Data(#"{"input":"12","url":"https://github.com/o/r/pull/12","number":12,"title":"PR title","branch":"feat/pr","repo":"/repo","path":"/wt","clone_required":true,"existing":false,"session_id":"S","window_id":"W","block_id":"B","error":"select failed"}"#.utf8))
        require(decoded.number == 12 && decoded.cloneRequired == true && decoded.sessionID == "S" && decoded.windowID == "W" && decoded.blockID == "B" && decoded.error == "select failed")
        for invalid in ["12", "https://gitlab.com/o/r/pull/12", "https://github.com.evil/o/r/pull/12", "https://github.com/o/r/issues/12", "https://github.com/o/r/pull/0", "https://github.com/o/r/pull/12/extra"] {
            require(PickerModel.pullRequestLink(invalid) == nil)
        }
        for invalid in ["github.com/o/r/pull/12", "http://github.com/o/r/pull/12",
                        "https://user@github.com/o/r/pull/12", "https://github.com:443/o/r/pull/12",
                        "https://github.com//o/r/pull/12", "https://github.com/o/r/pull/12//",
                        "https://github.com/o/r/pull/01", "https://github.com/./r/pull/12",
                        "https://github.com/o/../pull/12", "https://github.com/o%20x/r/pull/12"] {
            require(PickerModel.pullRequestLink(invalid) == nil, "Invalid PR URL accepted: \(invalid)")
        }
        for suffix in ["", "/", "?overview=true", "#discussion_r123", "/changes", "/files?diff=split#diff-123", "/commits/", "/checks"] {
            let decorated = "https://github.com/bateriku/bateriku-app/pull/3300" + suffix
            require(PickerModel.normalizedPullRequestURL(decorated) == "https://github.com/bateriku/bateriku-app/pull/3300",
                    "Browser PR URLs must normalize: \(decorated)")
        }
        require(PickerModel.pullRequestLink("https://github.com/o/r/pull/12")?.number == 12)
        require(PickerModel.pullRequestLink(" https://github.com/o/r/pull/12/ \n")?.repo == "o/r")
        let backend = CachedListBackend()
        for method in ["pullrequests.resolve", "pullrequests.prepare", "pullrequests.open"] { await backend.hold(method) }
        let model = PickerModel(options: options, backend: backend)
        model.keepsBackendWarmOnNavigation = true
        model.start()
        require(model.page == .pr && !model.showsPills && !model.loading && !model.canOpenPullRequest)
        require(model.targets == ["session", "tab"] && model.target == "session")
        require(PickerStyle.height(for: model) == 276, "PR preview should fit a compact form")
        model.prInput = "12"
        require(model.error != nil && !model.canOpenPullRequest, "Bare numbers must be rejected even with repo context")
        try await Task.sleep(for: .milliseconds(220))
        require(await backend.count("pullrequests.resolve") == 0, "Invalid numbers must not reach the backend")
        model.prInput = "https://github.com/o/r/pull/12/changes?overview=true#diff-123"
        require(model.prInput == "https://github.com/o/r/pull/12", "Pasted URL should be cleaned in the field")
        try await pending("pullrequests.resolve", backend)
        require(model.prStage == "Resolving" && !model.canOpenPullRequest)
        require(PickerStyle.height(for: model) == 300, "Progress must have its own row")
        let params = await backend.parameters("pullrequests.resolve")
        require(params["repo"] == nil, "URL must be the only repository authority")
        guard case .text("https://github.com/o/r/pull/12") = params["input"] else {
            testFailure("Backend must receive only the canonical PR URL")
        }
        model.prInput = "https://github.com/o/r/pull/13"
        try await Task.sleep(for: .milliseconds(220))
        await backend.replyLatest("pullrequests.resolve", APIResult(repo: "/repo", path: "/wt13", title: "Latest", branch: "feat/latest", existing: true))
        try await wait { model.canOpenPullRequest }
        await backend.reply("pullrequests.resolve", APIResult(title: "Stale"))
        try await Task.sleep(for: .milliseconds(20))
        require(model.pullRequest?.title == "Latest", "Stale PR response replaced current metadata")
        model.openPullRequest(); model.openPullRequest()
        try await pending("pullrequests.prepare", backend)
        require(model.prStage == "Preparing repository and worktree")
        model.escape()
        let changed = try LaunchOptions(arguments: ["--session", "different", "--repo", "/other"])
        let duringPrepare = model.prepareReconfigure(changed)
        await model.completeReconfigure(duringPrepare)
        require(model.busy && model.page == .pr && model.options.session == "original")
        await backend.reply("pullrequests.prepare", APIResult(repo: "/repo", path: "/wt13", title: "Latest"))
        try await pending("pullrequests.open", backend)
        require(model.createdPath == "/wt13" && model.prStage == "Opening session")
        await backend.reply("pullrequests.open", APIResult(path: "/wt13", sessionID: "S", error: "Selection failed"))
        try await wait { !model.busy }
        require(model.error?.contains("Selection failed") == true && model.error?.contains("/wt13") == true && model.canOpenPullRequest)
        require(PickerStyle.height(for: model) == 308, "Recovery errors must fit below the compact form")
        let reopen = model.prepareReconfigure(changed)
        await model.completeReconfigure(reopen)
        require(model.createdPath == "/wt13" && model.options.session == "original")
        model.target = "tab"; model.openPullRequest()
        try await pending("pullrequests.open", backend)
        require(await backend.count("pullrequests.prepare") == 1, "Open retry prepared a second worktree")
        let openParams = await backend.parameters("pullrequests.open")
        guard case .text("/wt13") = openParams["path"], case .text("tab") = openParams["target"] else { testFailure("PR retry lost path/target") }
        await backend.fail("pullrequests.open")
        try await wait { !model.busy }
        require(model.createdPath == "/wt13" && model.canOpenPullRequest && model.error?.contains("Refresh failed") == true)
        model.openPullRequest()
        try await pending("pullrequests.open", backend)
        require(await backend.count("pullrequests.prepare") == 1)
        await backend.reply("pullrequests.open", APIResult(path: "/wt13"))
        try await wait { !model.busy }
        require(model.createdPath == nil && !model.backendIsClosed)
        model.close()

        let searchBackend = CachedListBackend()
        let search = PickerModel(options: try LaunchOptions(arguments: []), backend: searchBackend)
        search.start()
        try await pending("sessions", searchBackend)
        await searchBackend.reply("sessions", APIResult(items: [PickerItem(path: "/repo", kind: "dir")], targets: ["here", "tab"], target: "here"))
        try await wait { search.canOpen }
        search.query = "https://github.com/o/r/pull/12"
        require(search.items.count == 1 && search.selected?.label == "Open PR #12 — o/r" && search.canOpen)
        require(await searchBackend.count("pullrequests.prepare") == 0, "Paste prepared a worktree")
        require(await searchBackend.count("pullrequests.resolve") == 0, "Paste requested metadata")
        let savedID = search.selectedID
        search.choose()
        require(search.page == .pr && search.prInput == "https://github.com/o/r/pull/12" && search.target == "session")
        search.escape()
        require(search.page == .directories && search.query == "https://github.com/o/r/pull/12" && search.selectedID == savedID && search.target == "here")
        search.beginPullRequest()
        search.prInput = "12"
        require(!search.canOpenPullRequest && search.error != nil, "Number without explicit repo was accepted")
        search.prInput = "https://gitlab.com/o/r/pull/12"
        require(!search.canOpenPullRequest && search.error != nil)
        search.escape(); search.close()

        let ambientBackend = CachedListBackend()
        await ambientBackend.hold("pullrequests.resolve")
        await ambientBackend.hold("pullrequests.prepare")
        let ambient = PickerModel(options: options, backend: ambientBackend)
        ambient.start()
        ambient.prInput = "https://github.com/other/project/pull/12"
        try await pending("pullrequests.resolve", ambientBackend)
        require(await ambientBackend.parameters("pullrequests.resolve")["repo"] == nil,
                "URL resolve must not require the unrelated ambient repository")
        await ambientBackend.reply("pullrequests.resolve", APIResult(repo: "/other", path: "/other-wt"))
        try await wait { ambient.canOpenPullRequest }
        ambient.openPullRequest()
        try await pending("pullrequests.prepare", ambientBackend)
        require(await ambientBackend.parameters("pullrequests.prepare")["repo"] == nil,
                "URL prepare must not require the unrelated ambient repository")
        await ambientBackend.fail("pullrequests.prepare")
        try await wait { !ambient.busy }
        require(ambient.createdPath == nil && ambient.canOpenPullRequest,
                "A failed Prepare must stay retryable without editing valid input")
        ambient.openPullRequest()
        try await pending("pullrequests.prepare", ambientBackend)
        require(await ambientBackend.count("pullrequests.prepare") == 2)
        await ambientBackend.fail("pullrequests.prepare")
        try await wait { !ambient.busy }
        ambient.close()
        print("PASS: native PR mode, URL action without mutation, Escape state, URL-only input, stale resolve, session/tab targets, layout, progress, structured open failure, hidden/context recovery and retry without prepare")
    }

    @MainActor private static func liveEventChecks() async throws {
        let options = try LaunchOptions(arguments: ["--demo", "--mode", "agents"])
        let backend = CachedListBackend(events: true)
        let model = PickerModel(options: options, backend: backend)
        model.view = .agents // Internal activity subscription helper coverage.
        func agent(_ id: String, _ state: String) -> PickerItem {
            PickerItem(path: id, kind: "agent", state: state)
        }
        let initial = APIResult(items: [agent("a", "working"), agent("b", "idle")], targets: ["tab", "session"], target: "tab")
        model.setPresented(true)
        model.start()
        try await pending("agents", backend)
        let methods = await backend.methods()
        require(methods.firstIndex(of: "subscribe")! < methods.firstIndex(of: "agents")!, "Subscribe must precede initial rows")
        await backend.reply("agents", initial)
        try await wait { !model.refreshing }
        require(await backend.count("agents") == 1, "Cold subscribe must not duplicate the initial snapshot")
        await backend.emit()
        try await pending("agents", backend)
        await backend.reply("agents", initial)
        try await Task.sleep(for: .milliseconds(70))
        model.selectedID = "b"; model.scrollID = "b"; model.target = "session"
        model.splitMode = true; model.targetPickerPresented = true
        let count = await backend.count("agents")
        await backend.emit(20)
        try await pending("agents", backend)
        require(await backend.count("agents") == count + 1, "Burst must coalesce")
        require(!model.loading && !model.refreshing, "Live refresh must not show loading")
        await backend.emit(20)
        await backend.reply("agents", APIResult(items: [agent("new", "blocked"), agent("b", "working"), agent("a", "idle")]))
        try await pending("agents", backend)
        require(model.items.map(\.id) == ["a", "b"] && model.items[0].state == "idle", "Update content, not presentation order")
        require(model.agentSections.map(\.id) == ["Working", "Idle"], "Keep snapshot groups")
        require(model.selectedID == "b" && model.scrollID == "b" && model.target == "session")
        require(model.splitMode && model.targetPickerPresented, "Keep split and popover state")
        await backend.reply("agents", initial)
        try await Task.sleep(for: .milliseconds(100))
        require(await backend.count("agents") == count + 2, "In-flight changes need exactly one follow-up, no polling")
        model.targetPickerPresented = false
        model.query = "filter"
        try await pending("agents", backend)
        await backend.reply("agents", initial)
        try await wait { !model.refreshing }
        await backend.emit()
        try await pending("agents", backend)
        let params = await backend.parameters("agents")
        if case .text("filter") = params["query"] {} else { testFailure("Live refresh lost query") }
        model.setPresented(false)
        await backend.reply("agents", APIResult(items: []))
        try await Task.sleep(for: .milliseconds(80))
        require(model.items.count == 2 && model.query == "filter", "Hidden response must not apply")
        let hiddenCount = await backend.count("agents")
        await backend.emit(10, stale: true)
        try await Task.sleep(for: .milliseconds(80))
        require(await backend.count("agents") == hiddenCount, "Hidden callbacks must not request rows")
        require(await backend.count("unsubscribe") == 1)
        model.setPresented(true)
        try await pending("agents", backend)
        let token = model.prepareReconfigure(try LaunchOptions(arguments: ["--demo", "--session", "new"]))
        let completion = Task { await model.completeReconfigure(token) }
        await backend.reply("agents", APIResult(items: [agent("stale", "blocked")]))
        await completion.value
        try await pending("sessions", backend)
        require(!model.items.contains { $0.id == "stale" }, "Prior-context event response must not apply")
        await backend.reply("sessions", APIResult(items: [PickerItem(path: "s", kind: "session", working: true)], targets: ["tab"], target: "tab"))
        try await wait { !model.refreshing }
        await backend.emit()
        try await pending("sessions", backend)
        await backend.reply("sessions", APIResult(items: [PickerItem(path: "s", kind: "session", state: "blocked")]))
        try await wait { model.items.first?.state == "blocked" }
        require(model.items.first?.activity.blocked == true)
        await backend.emit()
        try await pending("sessions", backend)
        model.close()
        await backend.reply("sessions", APIResult(items: []))
        await backend.emit(5)
        try await Task.sleep(for: .milliseconds(80))
        require(model.items.first?.id == "s", "Close must reject late events and responses")
        let worktrees = CachedListBackend(events: true)
        let worktreeOptions = try LaunchOptions(arguments: ["--demo", "--mode", "wt", "--repo", "/repo"])
        let worktreeModel = PickerModel(options: worktreeOptions, backend: worktrees)
        worktreeModel.page = .worktrees // Internal event isolation helper coverage.
        let trees = APIResult(items: [PickerItem(path: "/repo/tree", branch: "main")], targets: ["tab"], target: "tab", repo: "/repo", branches: ["main"], baseBranch: "main")
        worktreeModel.setPresented(true); worktreeModel.start()
        try await pending("worktrees.list", worktrees)
        await worktrees.reply("worktrees.list", trees)
        try await wait { !worktreeModel.refreshing }
        await worktrees.emit()
        try await pending("worktrees.list", worktrees)
        worktreeModel.busy = true
        await worktrees.reply("worktrees.list", trees)
        try await Task.sleep(for: .milliseconds(80))
        require(worktreeModel.busy && worktreeModel.repo == "/repo" && worktreeModel.base == "main", "Activity must preserve busy workflow and repository metadata")
        worktreeModel.busy = false
        worktreeModel.beginCreate(); worktreeModel.editBranch("feat/keep")
        let treeCount = await worktrees.count("worktrees.list")
        await worktrees.emit(10)
        try await Task.sleep(for: .milliseconds(80))
        require(await worktrees.count("worktrees.list") == treeCount, "Activity must not refresh a Create form")
        require(worktreeModel.page == .create && worktreeModel.branch == "feat/keep" && worktreeModel.base == "main")
        worktreeModel.close()
        print("PASS: idle live subscriptions, subscribe-before-snapshot, burst/in-flight coalescing, row-only refresh, stable order/groups/selection/scroll/target/query/popover/split, hidden/context/close isolation, busy worktree/Create preservation")
    }

    @MainActor private static func groupedActivityChecks() async throws {
        let json = #"{"path":"a","kind":"agent","state":"working","updated_at":"2026-01-02T03:04:05.123Z","cwd":"/repo","working":false}"#
        var item = try JSONDecoder().decode(PickerItem.self, from: Data(json.utf8))
        require(item.cwd == "/repo" && item.updatedDate != nil && item.activity.working)
        let date = item.updatedDate!
        require(item.updatedAge(now: date.addingTimeInterval(-100)) == "now")
        require(item.updatedAge(now: date.addingTimeInterval(120)) == "2m")
        require(item.updatedAge(now: date.addingTimeInterval(3600)) == "1h")
        item.updatedAt = "2026-01-02T03:04:05Z"
        require(item.updatedDate != nil)
        item.updatedAt = nil
        require(item.updatedAge() == nil)
        let heartbeatOnly = try JSONDecoder().decode(PickerItem.self, from: Data(#"{"path":"legacy","metadata":{"heartbeat":"2026-01-02T03:04:05Z"}}"#.utf8))
        require(heartbeatOnly.updatedAge() == nil, "Never use metadata heartbeat as updated_at")
        item.updatedAt = "bad"
        require(item.updatedAge() == nil)
        require(ActivityProjection.workingDotOpacities(at: nil) == [1, 1, 1],
                "Reduced-motion working indicator must show three static dots")
        let firstDots = ActivityProjection.workingDotOpacities(at: 0)
        require(firstDots.count == 3 && firstDots.allSatisfy { $0 >= 0.4 && $0 <= 1 },
                "Three working dots must stay visible throughout animation")
        require(firstDots != ActivityProjection.workingDotOpacities(at: 0.35),
                "Working dots must animate in sequence")
        for kind in ["session", "window", "directory"] {
            item.kind = kind; item.state = "blocked"; item.working = true
            require(item.activity == ActivityProjection(blocked: true, working: true))
            require(item.activityAccessibility == "Blocked, Working")
            require(item.activity.shouldPulse(reduceMotion: false, visible: true))
            require(!item.activity.shouldPulse(reduceMotion: true, visible: true))
            require(!item.activity.shouldPulse(reduceMotion: false, visible: false))
            item.working = false
            require(!item.activity.shouldPulse(reduceMotion: false, visible: true))
        }
        item.kind = "agent"; item.state = "idle"; item.working = true
        require(!item.activity.working, "Agent activity must derive only from state")

        let backend = CachedListBackend()
        let options = try LaunchOptions(arguments: ["--demo", "--mode", "agents"])
        let model = PickerModel(options: options, backend: backend)
        model.view = .agents // Internal activity projection coverage only.
        func row(_ id: String, _ state: String) -> PickerItem {
            PickerItem(path: id, label: id, kind: "agent", state: state)
        }
        let first = [row("b", "blocked"), row("w", "working"), row("i", "idle")]
        model.start()
        try await pending("agents", backend)
        await backend.reply("agents", APIResult(items: first))
        try await wait { !model.refreshing }
        require(model.agentSections.map(\.id) == ["Blocked", "Working", "Idle"])
        require(model.agentSections.flatMap(\.items).map { model.numberedPosition(of: $0) } == [1, 2, 3])
        let fullHeight = PickerStyle.height(for: model)
        model.selectView(.sessions)
        try await pending("sessions", backend)
        await backend.reply("sessions", APIResult(items: []))
        try await wait { !model.refreshing }
        model.selectView(.agents)
        try await pending("agents", backend)
        let fresh = [row("new", "blocked"), row("i", "blocked"), row("w", "working"), row("b", "idle")]
        await backend.reply("agents", APIResult(items: fresh))
        try await wait { !model.refreshing }
        require(model.items.map(\.id) == ["b", "w", "i"])
        require(model.items[0].state == "idle", "Live activity changes in place")
        require(model.agentSections.map(\.id) == ["Blocked", "Working", "Idle"])
        require(model.agentSections[0].items.map(\.id) == ["b"], "Snapshot membership stays fixed")
        require(PickerStyle.height(for: model) == fullHeight)
        model.query = "filtered"
        try await pending("agents", backend)
        await backend.reply("agents", APIResult(items: [fresh[1], fresh[2]]))
        try await wait { !model.refreshing }
        require(model.agentSections.map(\.id) == ["Blocked", "Working"])
        require(model.items.map(\.id) == ["i", "w"])
        require(model.numberedPosition(of: model.items[1]) == 2)
        require(PickerStyle.height(for: model) == fullHeight - PickerStyle.agentRowHeight - PickerStyle.agentGroupHeight - PickerStyle.agentGroupSpacing)
        model.close()
        print("PASS: internal activity timestamps/ages, projections/pulse gates, snapshot groups, deferred records, search groups and numbering")
    }

    @MainActor private static func stableAgentsChecks() async throws {
        let options = try LaunchOptions(arguments: ["--demo"])
        let backend = CachedListBackend()
        let model = PickerModel(options: options, backend: backend)
        let launcherRows = APIResult(items: ["/repo"].map { PickerItem(path: $0, kind: "dir") }, targets: ["tab"], target: "tab")
        func agent(_ id: String, _ label: String? = nil) -> PickerItem {
            PickerItem(path: id, label: label ?? id, kind: "agent", sessionID: "s", app: "Pi", state: "idle", windowID: "w", blockID: id)
        }
        model.start()
        try await pending("sessions", backend)
        await backend.reply("sessions", launcherRows)
        try await wait { !model.refreshing }
        model.selectView(.agents)
        try await pending("agents", backend)
        await backend.reply("agents", APIResult(items: [agent("b"), agent("a")]))
        try await wait { !model.refreshing }
        model.selectedID = "a"; model.scrollID = "a"

        func refresh(_ rows: [PickerItem]) async throws {
            model.selectView(.sessions)
            try await pending("sessions", backend)
            await backend.reply("sessions", launcherRows)
            try await wait { !model.refreshing }
            model.selectView(.agents)
            require(!model.loading && model.canOpen, "Cached Agents must remain usable")
            try await pending("agents", backend)
            await backend.reply("agents", APIResult(items: rows))
            try await wait { !model.refreshing }
        }
        try await refresh([agent("c"), agent("a", "Renamed"), agent("b")])
        require(model.items.map(\.id) == ["b", "a"] && model.selectedID == "a" && model.scrollID == "a")
        require(model.items[1].label == "Renamed", "Stable identity must still update row content")
        model.openNumbered(1)
        try await wait { !model.busy }
        require(model.selectedID == "b", "Numbered targets must not move during refresh")
        try await refresh([agent("d"), agent("c"), agent("a")])
        require(model.items.map(\.id) == ["a"], "Remove gone records; defer all new records")
        model.query = "ranked"
        try await pending("agents", backend)
        await backend.reply("agents", APIResult(items: [agent("d"), agent("a")]))
        try await wait { !model.refreshing }
        require(model.items.map(\.id) == ["d", "a"], "Search changes must use backend relevance")
        model.query = ""
        try await pending("agents", backend)
        await backend.reply("agents", APIResult(items: [agent("d"), agent("c"), agent("a")]))
        try await wait { !model.refreshing }
        require(model.items.map(\.id) == ["d", "c", "a"], "Revisited search must also take fresh backend relevance")
        try await refresh([agent("a"), agent("c"), agent("d")])
        require(model.items.map(\.id) == ["d", "c", "a"], "Refresh after search must freeze the new relevance order")
        let token = model.prepareReconfigure(options)
        require(model.canOpen && !model.loading, "Warm open must remain synchronous")
        await model.completeReconfigure(token)
        model.selectView(.agents)
        require(!model.loading && model.canOpen)
        try await pending("agents", backend)
        await backend.reply("agents", APIResult(items: [agent("a"), agent("c"), agent("d")]))
        try await wait { !model.refreshing }
        require(model.items.map(\.id) == ["a", "c", "d"], "New presentation must reset frozen order")
        model.close()
        print("PASS: stable Agents refresh identities, content, numbered targets, removal/deferred additions, search order, instant new-open reset")
    }

    @MainActor private static func sessionsChecks() async throws {
        // Wire decoding: one flat unified list of session and directory rows.
        let decoded = try JSONDecoder().decode(APIResult.self, from: Data(#"""
        {"items":[{"id":"session:w","kind":"session","path":"session:w","label":"dotfiles","session_id":"session:w","host":"This Mac","active":true,"state":"blocked"},
                  {"id":"/tmp/raptor","kind":"dir","path":"/tmp/raptor","label":"raptor","host":"This Mac","is_pinned":true}],
         "hosts":[{"label":"This Mac","local":true,"reachable":true},{"label":"Down Host","reachable":false,"error":"ssh: host down"}],
         "targets":["tab","session"],"target":"tab"}
        """#.utf8))
        require(decoded.items?.count == 2)
        require(decoded.items?[0].kind == "session" && decoded.items?[0].sessionID == "session:w")
        require(decoded.items?[0].active == true && decoded.items?[0].activity.blocked == true)
        require(decoded.items?[1].kind == "dir" && decoded.items?[1].path == "/tmp/raptor"
                     && decoded.items?[1].isPinned == true)
        require(decoded.hosts?.count == 2)
        require(decoded.hosts?[0] == HostHeader(label: "This Mac", local: true, reachable: true, error: nil))
        require(decoded.hosts?[1].local == nil && decoded.hosts?[1].reachable == false
                     && decoded.hosts?[1].error == "ssh: host down",
                     "Unreachable host headers must carry their transport error")
        require(decoded.targets == ["tab", "session"] && decoded.target == "tab",
                     "The launcher response carries open targets like the repositories page did")

        let payload = APIResult(
            items: [
                PickerItem(path: "session:x", label: "dotfiles", kind: "session", sessionID: "session:x",
                           state: "working", working: true, active: true, host: "This Mac"),
                PickerItem(path: "/tmp/plain", label: "plain", kind: "dir", isPinned: true, host: "This Mac"),
                PickerItem(path: "session:y", label: "build", kind: "session", sessionID: "session:y", host: "Demo Host"),
                PickerItem(path: "/Volumes/Demo/tree", label: "tree", kind: "dir", host: "Demo Host"),
            ],
            hosts: [
                HostHeader(label: "This Mac", local: true, reachable: true, error: nil),
                HostHeader(label: "Demo Host", local: false, reachable: true, error: nil),
                HostHeader(label: "Down Host", local: false, reachable: false, error: "ssh: host down"),
            ],
            targets: ["session", "tab", "here", "pane_right", "pane_below"], target: "session")
        let options = try LaunchOptions(arguments: ["--demo", "--mode", "sessions", "--session", "S"])
        let backend = CachedListBackend()
        let model = PickerModel(options: options, backend: backend)
        require(model.view == .sessions && model.page == .directories && model.loading,
                     "Direct Sessions mode must open the unified launcher")
        require(model.shouldToggle(for: options), "A repeated Sessions request with the same context toggles closed")
        model.start()
        try await pending("sessions", backend)
        let coldDirectories = await backend.count("directories")
        require(coldDirectories == 0, "The launcher must not load directories")
        await backend.reply("sessions", payload)
        try await wait { !model.refreshing }
        // One flat list: live sessions first (origin on top), then directories per host.
        require(model.items.map(\.id) == ["session:x", "/tmp/plain", "session:y", "/Volumes/Demo/tree"],
                     "The launcher must render one flat list in backend order")
        require(model.sessionHosts.map(\.label) == ["This Mac", "Demo Host", "Down Host"],
                     "Every configured host must be decoded, including unreachable ones")
        require(model.numberedPosition(of: model.items[3]) == 4, "Directory rows take real numbered positions")
        model.selectedID = "/tmp/plain"
        model.cycleTarget(backward: false)
        require(model.target == "tab", "Ctrl+O must choose Tab immediately after Session")
        model.cycleTarget(backward: true)
        require(model.target == "session", "Reverse cycling must restore Session")
        // A query re-ranks rows, but the backend always pins the origin
        // session first; the mac renders backend order as-is.
        model.query = "dot"
        try await pending("sessions", backend)
        await backend.reply("sessions", payload)
        try await wait { !model.refreshing }
        require(model.items.first?.id == "session:x",
                     "Filtered results must lead with the origin session")
        model.selectedID = "session:x"
        require(model.canOpen)
        let sessionsBefore = await backend.count("sessions")
        model.selectView(.sessions)
        let sessionsCalls = await backend.count("sessions")
        require(sessionsCalls == sessionsBefore, "Active Sessions shortcut must be idempotent")

        model.choose()
        try await wait { !model.busy }
        let jumpParams = await backend.parameters("sessions.jump")
        if case .text("session") = jumpParams["kind"],
           case .text("session:x") = jumpParams["session_id"],
           case .text("This Mac") = jumpParams["host"] {} else {
            testFailure("Sessions jump must target the exact session and host")
        }
        require(model.notice?.contains("No Rex call") == true, "Demo jumps stay visible with their notice")

        // A directory row with the Session target creates and switches.
        model.selectedID = "/Volumes/Demo/tree"
        model.target = "session"
        model.choose()
        try await wait { !model.busy }
        let createParams = await backend.parameters("sessions.create")
        if case .text("Demo Host") = createParams["host"],
           case .text("/Volumes/Demo/tree") = createParams["dir"] {} else {
            testFailure("Directory rows must create on the row's own host")
        }
        require(model.notice?.contains("No Rex call") == true)

        // A directory row with an overridden open target dispatches instead.
        model.target = "tab"
        model.selectedID = "/tmp/plain"
        model.choose()
        try await wait { !model.busy }
        let dispatchParams = await backend.parameters("dispatch")
        if case .text("tab") = dispatchParams["target"],
           case .text("/tmp/plain") = dispatchParams["path"] {} else {
            testFailure("Directory rows must dispatch the path with the chosen target")
        }
        require(model.notice?.contains("No Rex call") == true)

        // Close flow mirrors removal: confirm first, then sessions.close + refresh.
        model.selectedID = "session:x"
        model.askCloseSession()
        require(model.removalCandidate?.id == "session:x", "Close must confirm like removal")
        model.escape()
        require(model.removalCandidate != nil, "Esc must not navigate behind the confirmation")
        await backend.hold("sessions.close")
        model.confirmCloseSession(model.removalCandidate!)
        try await pending("sessions.close", backend)
        let failedCloseParams = await backend.parameters("sessions.close")
        if case .text("session") = failedCloseParams["kind"],
           case .text("session:x") = failedCloseParams["session_id"],
           case .text("This Mac") = failedCloseParams["host"] {} else {
            testFailure("Close must send kind, session id and host")
        }
        await backend.fail("sessions.close")
        try await wait { !model.busy }
        require(model.removalCandidate == nil && model.error != nil,
                     "A failed close must surface the backend error without refreshing")
        model.askCloseSession()
        model.confirmCloseSession(model.removalCandidate!)
        try await pending("sessions.close", backend)
        await backend.reply("sessions.close", APIResult())
        try await pending("sessions", backend)
        await backend.reply("sessions", payload)
        try await wait { !model.busy && !model.refreshing }
        require(model.items.count == 4 && model.error == nil, "A completed close must refresh the list")

        // Tab cycles only between Sessions and Agents now.
        require(!model.showsPills, "Internal view helpers must not imply a visible tab row")
        model.selectView(.agents)
        try await pending("agents", backend)
        await backend.reply("agents", APIResult(items: [PickerItem(path: "a", kind: "agent", sessionID: "s", windowID: "w", blockID: "a")]))
        try await wait { !model.refreshing }
        require(!model.shouldToggle(for: options), "A routed Sessions request must not hide another view")
        model.selectView(.sessions)
        try await pending("sessions", backend)
        await backend.reply("sessions", payload)
        try await wait { !model.refreshing }
        require(model.items.map(\.id) == ["session:x", "/tmp/plain", "session:y", "/Volumes/Demo/tree"],
                     "Returning to the launcher must restore its rows")

        // ⌃T on a directory row opens its worktrees; Escape walks back to the launcher.
        model.selectedID = "/tmp/plain"
        model.showWorktrees()
        require(model.page == .worktrees && model.repo == "/tmp/plain" && model.view == .sessions,
                     "Worktrees must open for the selected launcher directory")
        try await pending("worktrees.list", backend)
        await backend.reply("worktrees.list", APIResult(items: [PickerItem(path: "/tmp/plain/main", branch: "main", isMain: true)],
            targets: ["tab"], target: "tab", repo: "/tmp/plain", branches: ["main"], baseBranch: "main"))
        try await wait { !model.refreshing }
        model.escape()
        try await pending("sessions", backend)
        await backend.reply("sessions", payload)
        try await wait { !model.refreshing }
        require(model.page == .directories && model.query.isEmpty,
                     "Escape must walk back from worktrees to the launcher")
        model.selectedID = "session:y"
        model.showWorktrees()
        require(model.page == .directories, "Worktrees require a selected directory row")

        // Direct Sessions opens own the panel: Escape dismisses.
        var dismissals = 0
        model.onDismiss = { dismissals += 1 }
        model.escape()
        require(dismissals == 1 && model.page == .directories,
                     "Escape from the launcher dismisses the panel")
        model.close()

        // Mode "dirs" is the legacy alias for the same launcher.
        let alias = PickerModel(options: try LaunchOptions(arguments: ["--demo", "--mode", "dirs", "--session", "S"]), backend: CachedListBackend())
        require(alias.view == .sessions && alias.page == .directories && alias.loading,
                     "Mode dirs must open the unified launcher")
        alias.close()
        print("PASS: flat launcher decoding, hosts, session/directory open, jump/create/dispatch, refresh, retained internal browser helper isolation, Escape and dirs alias")
    }

    @MainActor private static func agentsChecks() async throws {
        let payload = Data("""
        {"path":"record-unique","kind":"agent","label":"Plan","app":"Pi","state":"working","agent_id":"a","session_id":"s","session_label":"Project","window_id":"w","window_label":"Build","block_id":"b","active":true}
        """.utf8)
        let item = try JSONDecoder().decode(PickerItem.self, from: payload)
        require(item.id == "record-unique" && item.agentID == "a" && item.windowID == "w" && item.blockID == "b")
        require(item.app == "Pi" && item.state == "working" && item.windowLabel == "Build" && !item.isSessionEntry)
        require(PickerStyle.agentRowHeight == 32 && PickerStyle.agentRowHeight == PickerStyle.rowHeight)
        var compact = item
        compact.label = ".dotfiles"; compact.sessionLabel = "personal"; compact.windowLabel = "dotfiles"
        require(compact.agentContext == "personal")
        compact.windowLabel = "namedtest"
        require(compact.agentContext == "personal / namedtest")
        compact.state = "idle"
        require(compact.agentActivity == nil && !compact.agentAccessibility.lowercased().contains("idle") && !compact.agentHelp.lowercased().contains("idle"))
        require(compact.agentAccessibility.contains("Pi") && compact.agentHelp.contains("Current pane"))
        for state in ["blocked", "needs_input", "needs-input", "waiting"] {
            compact.state = state
            require(compact.agentActivity == "Blocked" && compact.agentAccessibility.contains("Blocked"))
        }
        compact.state = "working"
        require(compact.agentActivity == "Working")
        let backend = DemoBackend()
        let options = try LaunchOptions(arguments: ["--demo"])
        let model = PickerModel(options: options, backend: backend)
        model.start()
        try await wait { !model.refreshing }
        require(!model.showsPills, "Retained internal activity helpers have no visible pills")
        for expected: PickerModel.ViewKind in [.agents, .sessions, .agents] {
            model.switchView()
            require(model.view == expected)
            try await wait { !model.refreshing }
        }
        for expected: PickerModel.ViewKind in [.sessions, .agents, .sessions] {
            model.switchView(backward: true)
            require(model.view == expected)
            try await wait { !model.refreshing }
        }
        model.selectView(.agents)
        require(model.view == .agents && !model.loading && model.canOpen)
        try await wait { !model.refreshing }
        require(model.items.count == 3 && Set(model.items.map(\.id)).count == 3)
        model.query = "picker"
        try await wait { !model.refreshing }
        require(model.items.count == 2)
        model.selectedID = model.items[1].id; model.scrollID = model.items[1].id
        let selected = model.selectedID
        model.selectView(.sessions)
        model.selectView(.agents)
        require(model.view == .agents && model.query == "picker" && model.selectedID == selected && model.scrollID == selected && model.canOpen)
        model.selectView(.agents)
        require(model.view == .agents, "Selecting the same internal view must not cycle")
        model.togglePin(); model.askRemove(); model.beginCreate(); model.showWorktrees(); model.toggleSplit()
        require(model.removalCandidate == nil && !model.splitMode && model.page == .directories && !model.busy)
        model.openNumbered(2)
        try await wait { !model.busy }
        var params = await backend.parameters("agents.jump")
        require(params.count == 3)
        if case .text("session:demo-1") = params["session_id"],
           case .text("window:demo-1a") = params["window_id"],
           case .text("block:demo-left") = params["block_id"] {} else {
            testFailure("Agents jump must focus the exact pane, not record identity")
        }
        model.selectedID = model.items[0].id
        var dismissed = false
        model.onDismiss = { dismissed = true }
        model.choose()
        model.escape()
        require(dismissed && model.busy, "Busy Escape must hide without cancelling navigation")
        try await wait { !model.busy }
        params = await backend.parameters("agents.jump")
        if case .text("block:demo-right") = params["block_id"] {} else { testFailure("Enter must jump to selected agent") }
        for method in ["sessions.close", "sessions.rename", "pins.toggle", "worktrees.remove", "worktrees.create", "dispatch"] {
            let count = await backend.count(method)
            require(count == 0, "Agents are navigation only: \(method)")
        }
        try await wait { !model.refreshing }
        model.selectedID = selected
        let token = model.prepareReconfigure(options)
        require(model.contextReady && !model.loading && model.view == .sessions,
                     "reopen context: contextReady=\(model.contextReady) loading=\(model.loading)")
        require(model.canOpen, "reopen canOpen: selected=\(model.selectedID ?? "nil") items=\(model.items.count) target=\(model.target) targets=\(model.targets.count)")
        await model.completeReconfigure(token)
        model.selectView(.agents)
		require(!model.loading && model.query == "" && model.items.count == 3 && model.canOpen,
										 "reopen reset: query=\(model.query) items=\(model.items.count) canOpen=\(model.canOpen)")
        dismissed = false
        model.escape()
        require(dismissed && model.view == .agents && model.query == "",
                     "Escape must dismiss, not clear search or select Agents")
        let changed = model.prepareReconfigure(try LaunchOptions(arguments: ["--demo", "--session", "changed"]))
        await model.completeReconfigure(changed)
        try await wait { !model.refreshing }
        model.selectView(.agents)
        require(model.loading && model.items.isEmpty, "Changed context must discard the Agents cache")
        try await wait { !model.refreshing }
        model.close()
        print("PASS: internal agent decoding/navigation/cache helpers, context invalidation, exact-pane jump, no destructive actions, busy dismissal (no visible tabs)")
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
                require(dismissals == 1 && model.view == view && model.query == query,
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
        require(agents.view == .sessions && agents.page == .directories && !agents.showsPills)
        require(agents.items.contains { $0.kind == "session" } && agents.items.contains { $0.kind == "dir" },
                     "The launcher must mix session and directory rows in one flat list")
        require(agents.items.first?.active == true, "The origin session must float to the top")
        agents.switchView()
        try await wait { !agents.loading }
        require(agents.view == .agents && agents.items.count == 3 && agents.items.allSatisfy { $0.kind == "agent" })
        require(agents.items.contains { $0.active == true }, "Active agents must be marked")
        agents.openNumbered(2)
        try await wait { !agents.busy }
        let jumpCount = await agentsBackend.count("agents.jump")
        require(jumpCount == 1, "Numbered open must jump to the agent")
        agents.selectView(.sessions)
        try await wait { !agents.refreshing }
        require(agents.view == .sessions && agents.page == .directories, "Reverse switch must return to the launcher")
        require(agents.items.contains { $0.kind == "session" }, "Reverse switch must restore the launcher rows")
        agents.close()

        // Pins round-trip through the backend for launcher directory rows.
        let pinsBackend = DemoBackend()
        let pinned = PickerModel(options: try LaunchOptions(arguments: ["--demo"]), backend: pinsBackend)
        pinned.start()
        try await wait { !pinned.loading }
        pinned.selectedID = pinned.items.first { $0.kind == "dir" }?.id
        pinned.togglePin()
        try await wait { !pinned.busy && !pinned.refreshing }
        require(pinned.items.first { $0.path == "/Users/demo/.dotfiles" }?.isPinned == true,
                     "Toggled pins must come back from the backend")
        let pinCount = await pinsBackend.count("pins.toggle")
        require(pinCount == 1, "Pinning must ask the backend once")
        pinned.close()

        // Resident reconfigure: one model serves repeated opens.
        let backend = DemoBackend()
        let resident = PickerModel(options: try LaunchOptions(arguments: ["--demo"]), backend: backend)
        resident.start()
        try await wait { !resident.loading }
        let contexts = await backend.contextUpdateCount
        await resident.reconfigure(try LaunchOptions(arguments: ["--demo", "--mode", "wt", "--repo", "/Users/demo/Projects/example-kit"]))
        try await wait { !resident.loading }
        require(resident.page == .directories && resident.view == .sessions,
                     "Legacy wt reopen must normalize to Sessions")
        let contextsAfter = await backend.contextUpdateCount
        require(contextsAfter == contexts,
                     "Same-origin normalized reopen keeps the warm backend")
        await resident.reconfigure(try LaunchOptions(arguments: ["--demo"]))
        try await wait { !resident.loading }
        require(resident.page == .directories && resident.view == .sessions)
        resident.close()
        print("PASS: resident launcher/current rows, internal agent navigation helpers, numbered jump, pins and normalized resident reconfigure")
    }

    @MainActor private static func cachedListChecks() async throws {
        let backend = CachedListBackend()
        let model = PickerModel(options: try LaunchOptions(arguments: ["--demo"]), backend: backend)
        let launcherRows = APIResult(items: ["/a", "/b", "/c"].map { PickerItem(path: $0, kind: "dir") }, targets: ["tab", "session"], target: "tab")
        let agents = APIResult(items: ["A1", "A2", "A3"].map { PickerItem(path: $0, kind: "agent", sessionID: "S", windowID: "W", blockID: $0) })
        model.start()
        try await pending("sessions", backend)
        await backend.reply("sessions", launcherRows)
        try await wait { !model.refreshing }
        model.selectedID = "/b"; model.scrollID = "/c"; model.target = "tab"
        model.selectView(.agents)
        require(model.loading && model.items.isEmpty && model.selectedID == nil && model.scrollID == nil,
                     "An uncached view must clear the other view before its request starts")
        try await pending("agents", backend)
        await backend.reply("agents", agents)
        try await wait { !model.refreshing }
        model.selectedID = "A2"; model.scrollID = "A3"
        model.selectView(.sessions)
        require(!model.loading && model.refreshing && model.canOpen && model.selectedID == "/b" && model.scrollID == "/c" && model.target == "tab",
                     "Cached launcher rows must restore selection, scroll and target before refreshing, with Open enabled")
        try await pending("sessions", backend)
        model.selectView(.agents)
        require(!model.loading && model.canOpen && model.selectedID == "A2" && model.scrollID == "A3")
        try await pending("agents", backend)
        await backend.reply("sessions", APIResult(items: [PickerItem(path: "/obsolete")]))
        await backend.reply("agents", APIResult(items: [agents.items![0]]))
        try await wait { !model.refreshing }
        require(model.selectedID == "A1" && model.scrollID == nil,
                     "Refresh must repair selection and scroll when their rows disappear")
        model.selectView(.sessions)
        require(model.items == launcherRows.items && model.selectedID == "/b" && model.scrollID == "/c",
                     "A cancelled reply must not overwrite the inactive cache")
        try await pending("sessions", backend)
        await backend.fail("sessions")
        try await wait { !model.refreshing }
        require(model.canOpen && model.items == launcherRows.items && model.error != nil,
                     "A failed background refresh must keep cached rows usable")

        model.query = "filtered"
        require(!model.loading && model.items == launcherRows.items && !model.canOpen,
                "Uncached queries must retain the display snapshot without enabling stale actions")
        try await pending("sessions", backend)
        await backend.reply("sessions", launcherRows)
        try await wait { !model.refreshing }
        model.selectedID = "/c"; model.scrollID = "/b"
        model.selectView(.agents)
        try await pending("agents", backend)
        model.selectView(.sessions)
        require(model.query == "filtered" && model.selectedID == "/c" && model.scrollID == "/b" && model.canOpen,
                     "Each view must retain its own query and list position")
        try await pending("sessions", backend)
        model.openNumbered(2)
        try await wait { !model.busy }
        let cachedDispatches = await backend.count("dispatch")
        require(cachedDispatches == 1, "Cached numbered Open must not wait for refresh")
        // Dispatch invalidates both lists: new agent metadata may now exist.
        await backend.reply("agents", agents)
        await backend.reply("sessions", launcherRows)
        model.selectView(.agents)
        require(model.loading && model.items.isEmpty, "Dispatch must invalidate the Agents cache too")
        try await pending("agents", backend)
        await backend.fail("agents")
        try await wait { !model.refreshing }
        require(model.items.isEmpty && model.error != nil, "Failed post-mutation refresh must not restore stale rows")
        model.selectView(.sessions)
        require(model.loading && model.items.isEmpty, "Mutation must invalidate the launcher cache too")
        try await pending("sessions", backend)

        // Reconfigure while an old-origin reply is pending. No old rows can
        // appear either during the context request or on a subsequent switch.
        let internalContext = model.prepareReconfigure(try LaunchOptions(arguments: ["--demo", "--session", "new-origin", "--repo", "/new-repo"]))
        model.page = .worktrees // Internal cache isolation helper coverage.
        await model.completeReconfigure(internalContext)
        require(model.items.isEmpty && model.scrollID == nil && model.loading && !model.canOpen)
        await backend.reply("sessions", launcherRows)
        try await pending("worktrees.list", backend)
        let worktrees = APIResult(items: [PickerItem(path: "/new-repo/main", branch: "main")], targets: ["tab"], target: "tab", repo: "/new-repo", branches: ["main"], baseBranch: "main")
        await backend.reply("worktrees.list", worktrees)
        try await wait { !model.refreshing }
        model.selectView(.agents)
        require(model.loading && model.items.isEmpty, "New origin must not reuse old agent rows")
        try await pending("agents", backend)
        await backend.reply("agents", agents)
        try await wait { !model.refreshing }
        require(model.repo == "/new-repo" && model.base == "main",
                     "Agents replies on the worktree page must not replace repository metadata")
        model.selectView(.sessions)
        require(model.items == worktrees.items && model.canOpen)
        try await pending("worktrees.list", backend)
        model.beginCreate()
        await backend.reply("worktrees.list", APIResult(items: [PickerItem(path: "/late")], repo: "/wrong"))
        try await Task.sleep(for: .milliseconds(30))
        require(model.page == .create && model.repo == "/new-repo", "Late background list must not change Create metadata")
        model.close()

        // The first open may overtake startup's directory warmup. Its reply
        // must not leak into a worktree open or restart the model afterwards.
        let warmBackend = CachedListBackend()
        let warm = PickerModel(options: try LaunchOptions(arguments: ["--demo"]), backend: warmBackend)
        warm.start()
        try await pending("sessions", warmBackend)
        await warmBackend.hold("context")
        let firstContext = warm.prepareReconfigure(try LaunchOptions(arguments: ["--demo", "--mode", "wt", "--repo", "/first", "--session", "first"]))
        warm.page = .worktrees // Internal metadata isolation helper coverage.
        let firstOpen = Task { await warm.completeReconfigure(firstContext) }
        try await pending("context", warmBackend)
        await warmBackend.reply("sessions", launcherRows)
        warm.start()
        try await Task.sleep(for: .milliseconds(30))
        require(warm.items.isEmpty && warm.page == .worktrees && warm.repo == "/first" && !warm.contextReady,
                     "A late startup reply or repeated start must not overwrite the first open")
        await warmBackend.reply("context", APIResult())
        await firstOpen.value
        try await pending("worktrees.list", warmBackend)
        await warmBackend.reply("worktrees.list", APIResult(items: [PickerItem(path: "/first/main")], targets: ["tab"], target: "tab", repo: "/first"))
        try await wait { !warm.refreshing }
        require(warm.contextReady && warm.canOpen && warm.repo == "/first")
        warm.close()

        let mutationBackend = CachedListBackend()
        let mutation = PickerModel(options: try LaunchOptions(arguments: ["--demo"]), backend: mutationBackend)
        mutation.start()
        try await pending("sessions", mutationBackend)
        await mutationBackend.reply("sessions", launcherRows)
        try await wait { !mutation.refreshing }
        await mutationBackend.hold("pins.toggle")
        mutation.togglePin()
        try await pending("pins.toggle", mutationBackend)
        await mutationBackend.hold("context")
        let context = mutation.prepareReconfigure(try LaunchOptions(arguments: ["--demo", "--session", "changed"]))
        require(mutation.items == launcherRows.items && !mutation.loading && !mutation.busy && !mutation.contextReady && !mutation.canOpen,
                     "Prepare must synchronously show the cached launcher, but gate all actions")
        require(mutation.targets.isEmpty && mutation.target.isEmpty && mutation.repo == nil && mutation.branches.isEmpty,
                     "Cached launcher rows must not restore old-origin targets or repository state")
        mutation.openNumbered(2); mutation.choose(); mutation.togglePin()
        mutation.showWorktrees(); mutation.beginCreate(); mutation.switchView()
        mutation.askRemove(); mutation.confirmRemove(PickerItem(path: "/old", isMain: false))
        mutation.create(); mutation.openCreated(); mutation.cycleTarget(backward: false); mutation.toggleSplit()
        require(mutation.page == .directories && mutation.view == .sessions && mutation.repo == nil && !mutation.busy && mutation.removalCandidate == nil,
                     "Actions must not change navigation or candidates before context is ready")
        let reopen = Task { await mutation.completeReconfigure(context) }
        try await pending("context", mutationBackend)
        mutation.start() // Startup warmup cannot reset or query a pending open.
        let callsWhileBlocked = await mutationBackend.count("sessions")
        let dispatchesWhileBlocked = await mutationBackend.count("dispatch")
        let pinsWhileBlocked = await mutationBackend.count("pins.toggle")
        require(callsWhileBlocked == 1 && dispatchesWhileBlocked == 0 && pinsWhileBlocked == 1,
                     "Blocked actions and late start must not send requests using the old context")
        await mutationBackend.reply("pins.toggle", APIResult())
        await mutationBackend.reply("context", APIResult())
        await reopen.value
        try await pending("sessions", mutationBackend)
        await mutationBackend.reply("sessions", APIResult(items: [PickerItem(path: "/new-origin")], targets: ["tab"], target: "tab"))
        try await wait { !mutation.refreshing }
        let sessionsCalls = await mutationBackend.count("sessions")
        require(sessionsCalls == 2 && mutation.selectedID == "/new-origin" && mutation.error == nil,
                     "Old mutation completion must not refresh or modify a new context")
        let failedContext = mutation.prepareReconfigure(try LaunchOptions(arguments: ["--demo", "--session", "failed"]))
        let failedOpen = Task { await mutation.completeReconfigure(failedContext) }
        try await pending("context", mutationBackend)
        await mutationBackend.fail("context")
        await failedOpen.value
        require(!mutation.contextReady && !mutation.canOpen && !mutation.canCreate && !mutation.canSubmitForm && mutation.error != nil && !mutation.refreshing,
                     "Context failure must be explicit and must never enable stale-backend actions")
        mutation.openNumbered(1); mutation.togglePin(); mutation.beginCreate(); mutation.switchView()
        require(!mutation.busy && mutation.page == .directories && mutation.view == .sessions)
        let worktreeContext = mutation.prepareReconfigure(try LaunchOptions(arguments: ["--demo", "--mode", "wt-create", "--repo", "/different", "--session", "third"]))
        require(mutation.items.isEmpty && mutation.loading && mutation.repo == "/different" && mutation.branches.isEmpty && mutation.base.isEmpty,
                     "A worktree open must never show cached directories or old contextual metadata")
        let directoryContext = mutation.prepareReconfigure(try LaunchOptions(arguments: ["--demo", "--session", "fourth"]))
        await mutation.completeReconfigure(worktreeContext)
        require(mutation.items.first?.path == "/new-origin" && !mutation.contextReady,
                     "A superseded completion must not send context or enable actions")
        let recovered = Task { await mutation.completeReconfigure(directoryContext) }
        try await pending("context", mutationBackend)
        await mutationBackend.reply("context", APIResult())
        await recovered.value
        try await pending("sessions", mutationBackend)
        require(mutation.contextReady && mutation.target.isEmpty && !mutation.canOpen,
                     "Targets must come from the refreshed origin, not the global directory cache")
        await mutationBackend.reply("sessions", launcherRows)
        try await wait { !mutation.refreshing }
        require(mutation.canOpen, "A successful retry and list refresh must restore actions")
        mutation.close()
        print("PASS: instant cached switching, per-view query/selection/scroll, cached Open, cancelled replies, refresh failure, mutation invalidation, origin/repo/page isolation, synchronous directory reopen, blocked context action gates, context failure/retry, startup warmup race")
    }

    @MainActor private static func residentNavigationWarmthChecks() async throws {
        for action in ["sessions.jump", "sessions.create", "agents.jump", "dispatch"] {
            let backend = CachedListBackend()
            await backend.hold(action)
            let isAgent = action == "agents.jump"
            let options = try LaunchOptions(arguments: ["--mode", isAgent ? "agents" : "sessions", "--session", "S", "--block", "B"])
            let model = PickerModel(options: options, backend: backend)
            model.keepsBackendWarmOnNavigation = true
            var dismissals = 0
            var closes = 0
            model.onDismiss = { dismissals += 1 }
            model.onClose = { closes += 1 }
            if isAgent { model.view = .agents } // Internal navigation helper only.
            let listMethod = isAgent ? "agents" : "sessions"
            let kind = isAgent ? "agent" : (action == "sessions.jump" ? "session" : "dir")
            let item = PickerItem(path: "/repo", kind: kind, sessionID: "S", windowID: "W", blockID: "B")
            let result = APIResult(items: [item], targets: ["session", "tab"], target: action == "dispatch" ? "tab" : "session")
            model.start()
            try await pending(listMethod, backend)
            await backend.reply(listMethod, result)
            try await wait { !model.refreshing }
            model.choose()
            try await pending(action, backend)
            await backend.reply(action, APIResult())
            try await wait { dismissals == 1 && !model.busy }
            require(!model.backendIsClosed && closes == 0, "Resident navigation must hide, not restart the backend: \(action)")
            if action == "sessions.jump" {
                let count = await backend.count("sessions")
                let token = model.prepareReconfigure(options)
                await model.completeReconfigure(token)
                require(model.contextReady && model.canOpen && model.items == [item], "Resident reopen must retain actionable cached rows")
                try await Task.sleep(for: .milliseconds(20))
                require(await backend.count("sessions") == count, "Warm navigation reopen must not rescan the list")
            }
            model.close()
        }
        print("PASS: resident session/agent jumps, Create and dispatch hide without closing the backend; cached reopen stays immediate")
    }

    @MainActor private static func dismissalChecks() async throws {
        let options = try LaunchOptions(arguments: []) // Real success path, not demo notices.
        let rows = APIResult(items: [PickerItem(path: "/repo", kind: "dir")], targets: ["tab"], target: "tab")
        for method in ["agents.jump", "dispatch"] {
            let backend = CachedListBackend()
            await backend.hold(method)
            let model = PickerModel(options: options, backend: backend)
            var closes = 0
            var dismissals = 0
            model.onClose = { closes += 1 }
            model.onDismiss = { dismissals += 1 }
            model.start()
            try await pending("sessions", backend)
            await backend.reply("sessions", rows)
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
            model.dismissForOutsideClick()
            model.choose()
            require(model.busy && dismissals == 3 && closes == 0 && !model.backendIsClosed,
                         "Dismiss must hide without closing or cancelling a live operation")
            await backend.reply(method, APIResult())
            try await wait { closes == 1 }
            require(!model.busy && model.backendIsClosed,
                         "Successful non-demo jump/dispatch must close without sticky busy; resident recovery must be eligible")
            let calls = await backend.count(method)
            require(calls == 1, "Dismiss and repeated Open must not replay an operation")
            // The resident delegate replaces a closed backend before reconfiguration.
            let freshBackend = CachedListBackend()
            let fresh = PickerModel(options: options, backend: freshBackend)
            await fresh.reconfigure(options)
            try await pending("sessions", freshBackend)
            await freshBackend.reply("sessions", rows)
            try await wait { fresh.canOpen }
            require(!fresh.busy && !fresh.backendIsClosed)
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
        require(create.busy && hidden == 2 && !create.backendIsClosed)
        await backend.reply("worktrees.create", APIResult(path: "/repo-new"))
        try await pending("dispatch", backend)
        create.dismissForOutsideClick() // Outside clicks also preserve an in-flight committed create.
        let busyReopen = create.prepareReconfigure(createOptions)
        await create.completeReconfigure(busyReopen)
        require(create.busy && create.createdPath == "/repo-new")
        await backend.fail("dispatch")
        try await wait { !create.busy }
        require(create.createdPath == "/repo-new" && create.error != nil,
                     "Hidden create must finish and retain its path after dispatch failure")
        let savedError = create.error
        let reopen = create.prepareReconfigure(createOptions)
        await create.completeReconfigure(reopen)
        require(create.page == .create && create.createdPath == "/repo-new"
                     && create.error == savedError && create.canSubmitForm && !create.canCreate,
                     "Actual resident reopen must restore Retry opening and its failure")
        create.escape()
        require(hidden == 4 && create.createdPath == "/repo-new",
                     "Escape must hide recovery without discarding it")
        let unrelated = try LaunchOptions(arguments: ["--mode", "wt-create", "--repo", "/other", "--session", "new", "--block", "new", "--client", "new", "--title", "New"])
        for incoming in [unrelated, try LaunchOptions(arguments: ["--mode", "agents"])] {
            let changed = create.prepareReconfigure(incoming)
            await create.completeReconfigure(changed)
            require(create.options.matches(createOptions) && create.repo == "/repo"
                         && create.target == "tab" && create.createdPath == "/repo-new"
                         && create.error?.contains("original context") == true && !create.canCreate,
                         "Unrelated requests must show recovery, not retarget its repo or origin")
        }
        let contexts = await backend.count("context")
        let lists = await backend.count("worktrees.list")
        require(contexts == 0 && lists == 1,
                     "Recovery reopen must not reconfigure the backend or regenerate the form")
        create.submitBranch() // Retry opens only, never creates again.
        try await pending("dispatch", backend)
        await backend.reply("dispatch", APIResult())
        try await wait { create.backendIsClosed }
        let creates = await backend.count("worktrees.create")
        let opens = await backend.count("dispatch")
        let openParams = await backend.parameters("dispatch")
        if case .text("/repo-new") = openParams["path"], case .text("tab") = openParams["target"] {} else {
            testFailure("Retry must open the committed path with the retained target")
        }
        require(creates == 1 && opens == 2 && !create.busy && create.createdPath == nil,
                     "Successful retry must clear recovery so the resident can replace the closed backend")

        // Worktree-origin Create recovery. Neither a hide nor an unrelated
        // launch may navigate away and erase it; only explicit discard may.
        let discardBackend = CachedListBackend()
        await discardBackend.hold("worktrees.create")
        await discardBackend.hold("dispatch")
        let discardOptions = try LaunchOptions(arguments: ["--mode", "wt", "--repo", "/repo", "--session", "origin", "--block", "B", "--client", "C", "--title", "Origin"])
        let discard = PickerModel(options: discardOptions, backend: discardBackend)
        discard.page = .worktrees // Internal parent/recovery helper coverage.
        discard.start()
        try await pending("worktrees.list", discardBackend)
        await discardBackend.reply("worktrees.list", APIResult(items: [PickerItem(path: "/repo/main", branch: "main", isMain: true)], targets: ["tab"], target: "tab", repo: "/repo", branches: ["main"], baseBranch: "main"))
        try await wait { !discard.loading }
        discard.beginCreate()
        require(discard.page == .create)
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
        require(discard.page == .create && discard.createdPath == "/repo-discard" && discard.repo == "/repo")
        discard.discardCreatedRecovery()
        discard.submitBranch(); discard.create(); discard.openCreated()
        require(discard.createdPath == nil && !discard.contextReady && !discard.canCreate,
                     "Explicit discard must gate all old-context actions until a new request")
        let freshContext = discard.prepareReconfigure(unrelated)
        await discard.completeReconfigure(freshContext)
        try await pending("worktrees.list", discardBackend)
        require(discard.options.matches(unrelated) && discard.repo == "/other")
        let contextParams = await discardBackend.parameters("context")
        if case .text("new") = contextParams["session"], case .text("new") = contextParams["block"] {} else {
            testFailure("Only explicit discard may install the new origin")
        }
        await discardBackend.reply("worktrees.list", APIResult(targets: ["tab"], target: "tab", repo: "/other", branches: ["main"], baseBranch: "main"))
        try await wait { !discard.loading }
        let discardedCreates = await discardBackend.count("worktrees.create")
        let discardedOpens = await discardBackend.count("dispatch")
        require(discardedCreates == 1 && discardedOpens == 1)
        discard.close()

        let pinBackend = CachedListBackend()
        await pinBackend.hold("pins.toggle")
        let pin = PickerModel(options: options, backend: pinBackend)
        pin.onDismiss = { hidden += 1 }
        pin.start()
        try await pending("sessions", pinBackend)
        await pinBackend.reply("sessions", rows)
        try await wait { !pin.loading }
        pin.togglePin()
        try await pending("pins.toggle", pinBackend)
        pin.escape(); pin.dismiss(); pin.togglePin()
        require(pin.busy && !pin.backendIsClosed)
        await pinBackend.reply("pins.toggle", APIResult())
        try await pending("sessions", pinBackend)
        await pinBackend.reply("sessions", APIResult(items: []))
        try await wait { !pin.busy && !pin.refreshing }
        let pins = await pinBackend.count("pins.toggle")
        require(pins == 1 && pin.items.isEmpty && pin.error == nil,
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
                require(PickerPalette.apply(payload))
                require(NSColor(PickerStyle.background) == NSColor(hexColor("#303030")!) &&
                             NSColor(PickerStyle.selection) == NSColor(hexColor("#aaccaa")!) &&
                             NSColor(PickerStyle.selectionText) == NSColor(hexColor("#102030")!) &&
                             PickerPalette.selectionOpacity == 0.75,
                             "Native roles must not reuse terminal canvas, selection or selected text")
                let label = NSColor(PickerStyle.foreground).usingColorSpace(.sRGB)!
                if style == "useTheme" {
                    require(NSColor(PickerStyle.foreground) == NSColor(hexColor("#ddbbcc")!),
                                 "Full-theme chrome must use UI content, not terminal foreground")
                } else {
                    require(abs(label.redComponent - label.greenComponent) < 0.01 &&
                                 abs(label.greenComponent - label.blueComponent) < 0.01 &&
                                 (dark ? label.redComponent > 0.8 : label.redComponent < 0.2),
                                 "Native labels must follow Rex appearance, not system or terminal colors")
                }
                let tinted = style == "blendTheme" || style == "useTheme"
                require(PickerPalette.usesThemeTint == tinted)
                if #available(macOS 26.0, *) {
                    let glass = NSGlassEffectView(frame: .zero)
                    glass.wantsLayer = true
                    PickerStyle.applyPanelTheme(to: glass)
                    require(glass.tintColor == (tinted ? PickerStyle.glassTint : nil),
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
        let rows = APIResult(items: [PickerItem(path: "/a", kind: "dir"), PickerItem(path: "/b", kind: "dir")],
                             targets: ["tab", "session"], target: "session")
        let dark = ThemePayload(name: "Forest", isDark: true, background: "#102030",
                                foreground: "#eeeeee", selection: "#aaccee",
                                selectionForeground: "#203040", surface: "#223344")
        let light = ThemePayload(name: "Light", isDark: false, background: "#f0e0d0",
                                 foreground: "#203040", selection: "#556677",
                                 selectionForeground: "#ffeedd", surface: "#ddccbb")
        model.start()
        try await pending("sessions", backend)
        require(await backend.count("theme") == 0, "Initial theme must not queue ahead of the list")
        await backend.reply("sessions", rows)
        try await pending("theme", backend)
        try await wait { !model.refreshing }
        require(model.canOpen && !model.themeLoaded,
                     "A slow theme lookup must not block loaded rows")
        let first = model.refreshTheme()
        await backend.reply("theme", APIResult(theme: dark))
        await first?.value
        require(model.themeLoaded && model.themeRevision == 1 && PickerPalette.isDark)
        require(NSColor(PickerStyle.selectionText) == NSColor(hexColor("#203040")!),
                     "Selected text must use Rex's selected-theme color, not hardcoded white")
        let material = NSView()
        material.wantsLayer = true
        PickerStyle.applyPanelTheme(to: material)
        require(material.appearance?.name == .darkAqua &&
                     material.layer?.backgroundColor == NSColor(PickerPalette.background).cgColor,
                     "Asynchronous theme loading must repaint the native material")

        model.query = "keep"
        try await pending("sessions", backend)
        await backend.reply("sessions", rows)
        try await wait { !model.refreshing }
        model.selectedID = "/b"; model.scrollID = "/a"; model.target = "session"
        let refresh = model.refreshTheme()
        model.refreshTheme()
        try await pending("theme", backend)
        let themeCalls = await backend.count("theme")
        require(themeCalls == 2 && model.canOpen && !model.busy,
                     "Theme refresh must coalesce requests without gating cached Open")
        await backend.reply("theme", APIResult(theme: light))
        await refresh?.value
        require(model.themeRevision == 2 && !PickerPalette.isDark)
        require(model.query == "keep" && model.selectedID == "/b" && model.scrollID == "/a" &&
                     model.target == "session" && model.items == rows.items,
                     "Theme changes must preserve query, rows, selection, scroll and target")
        PickerStyle.applyPanelTheme(to: material)
        require(material.appearance?.name == .aqua &&
                     material.layer?.backgroundColor == NSColor(PickerPalette.background).cgColor &&
                     material.layer?.borderColor == PickerStyle.hairline.cgColor,
                     "Native surface, border and appearance must follow a changed Rex theme")
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: .zero)
            glass.wantsLayer = true
            glass.tintColor = .red
            PickerStyle.applyPanelTheme(to: glass)
            require(glass.tintColor == PickerStyle.glassTint && glass.appearance?.name == .aqua,
                         "Glass must replace the previous tint with the loaded Rex theme")
        }
        let effect = NSVisualEffectView(frame: .zero)
        effect.wantsLayer = true
        PickerStyle.applyPanelTheme(to: effect)
        require(effect.layer?.backgroundColor == PickerStyle.glassTint.cgColor &&
                     effect.appearance?.name == .aqua,
                     "Pre-glass macOS material must also follow the Rex theme")

        let unchanged = model.refreshTheme()
        try await pending("theme", backend)
        await backend.reply("theme", APIResult(theme: light))
        await unchanged?.value
        require(model.themeRevision == 2, "An unchanged theme must not repaint")
        let failed = model.refreshTheme()
        try await pending("theme", backend)
        await backend.fail("theme")
        await failed?.value
        require(model.themeRevision == 2 && model.error == nil,
                     "A failed refresh must retain the palette without disrupting the picker")
        let invalid = model.refreshTheme()
        try await pending("theme", backend)
        await backend.reply("theme", APIResult(theme: ThemePayload(background: "invalid")))
        await invalid?.value
        require(model.themeRevision == 2 && !PickerPalette.isDark,
                     "Malformed colors must not replace the last valid palette")
        let retry = model.refreshTheme()
        try await pending("theme", backend)
        await backend.reply("theme", APIResult(theme: dark))
        await retry?.value
        require(model.themeRevision == 3 && PickerPalette.isDark,
                     "Theme lookup must remain retryable after an error or invalid payload")
        let late = model.refreshTheme()
        try await pending("theme", backend)
        model.close()
        await backend.reply("theme", APIResult(theme: light))
        await late?.value
        require(model.themeRevision == 3 && PickerPalette.isDark && model.refreshTheme() == nil,
                     "Closed models must reject late themes and new refreshes")
        PickerPalette.useFallback(dark: true)
        print("PASS: asynchronous Rex theme refresh, request coalescing, cached Open, stable picker state, selected text, material repaint, unchanged/error/invalid responses, retry and close")
    }

    @MainActor private static func searchLatencyChecks() async throws {
        for mode in ["wt", "wt-create"] {
            let options = try LaunchOptions(arguments: ["--demo", "--mode", mode])
            let model = PickerModel(options: options, backend: CachedListBackend())
            model.page = .create // Shared worktree metadata is still used by creation.
            require(model.queryDebounceMilliseconds == 140, "Worktree metadata debounce must stay unchanged")
            model.close()
        }
        for mode in ["sessions"] {
            let backend = CachedListBackend()
            let options = try LaunchOptions(arguments: ["--demo", "--mode", mode])
            let model = PickerModel(options: options, backend: backend)
            let old = PickerItem(path: "old", kind: mode == "agents" ? "agent" : "session")
            let latest = PickerItem(path: "latest", kind: old.kind)
            let snapshot = APIResult(items: [old], targets: ["tab"], target: "tab")
            model.start()
            try await pending(mode, backend)
            await backend.reply(mode, snapshot)
            try await wait { !model.refreshing && model.themeLoaded }
            require(model.canOpen && model.queryDebounceMilliseconds == 0)
            model.query = "l"
            try await pending(mode, backend)
            require(model.items == [old] && !model.loading && !model.canOpen)
            model.choose(); model.openNumbered(1); model.togglePin(); model.showWorktrees(); model.askCloseSession()
            require(!model.busy && model.removalCandidate == nil && model.page == .directories,
                    "Pending search rows must be display-only for every action")
            model.query = "la"
            model.query = "latest"
            let began = ContinuousClock.now
            // The obsolete in-flight read may complete after the current one.
            // Hold it until the current response has replaced the display.
            for _ in 0..<2000 {
                if await backend.count(mode) == 3 { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            require(await backend.count(mode) == 3, "Only the yielded old query and latest query should reach the mock")
            let elapsed = began.duration(to: .now)
            require(model.items == [old] && !model.loading && !model.canOpen)
            await backend.replyLatest(mode, APIResult(items: [latest], targets: ["tab"], target: "tab"))
            try await wait { !model.refreshing }
            require(model.items == [latest] && model.canOpen)
            await backend.reply(mode, APIResult(items: [PickerItem(path: "obsolete", kind: old.kind)]))
            // Let the obsolete task attempt to publish after the latest result.
            await Task.yield()
            require(model.items == [latest] && model.canOpen, "A late obsolete response must not replace matching results")
            let calls = await backend.count(mode)
            let reopen = model.prepareReconfigure(options)
            require(model.items == [old] && !model.loading && model.canOpen && model.query.isEmpty,
                    "Reopen must synchronously show the cached unfiltered snapshot")
            await model.completeReconfigure(reopen)
            if mode == "agents" {
                try await pending(mode, backend)
                await backend.reply(mode, snapshot)
                try await wait { !model.refreshing }
            }
            require(await backend.count(mode) == calls + (mode == "agents" ? 1 : 0))
            print("PASS: \(mode) search debounce=0ms; 3 list requests (initial, in-flight old, latest), intermediate query=0; observed latest dispatch=\(elapsed); cached reopen synchronous, extra list requests=\(mode == "agents" ? 1 : 0)")
            model.close()
        }
    }

    @MainActor private static func warmReopenChecks() async throws {
        let options = try LaunchOptions(arguments: ["--demo", "--session", "S", "--block", "B", "--client", "C", "--title", "T"])
        let launcherRows = APIResult(items: ["/a", "/b", "/c"].map { PickerItem(path: $0, kind: "dir") }, targets: ["tab", "session"], target: "tab")
        // Zero TTL forces an expired refresh without a wall-clock sleep.
        for ttl: TimeInterval in [30] {
            let backend = CachedListBackend()
            let model = PickerModel(options: options, backend: backend, cacheTTL: ttl)
            model.start()
            try await pending("sessions", backend)
            await backend.reply("sessions", launcherRows)
            try await wait { !model.refreshing && model.themeLoaded }
            model.selectedID = "/a"; model.scrollID = "/a"
            model.move(1)
            require(model.selectedID == "/b" && model.scrollID == "/a",
                    "Arrow navigation must not replace the viewport anchor with the selected row")
            model.scrollID = "/c"; model.target = "tab"
            let previousPresentation = model.listPresentation
            model.query = "filtered"
            try await pending("sessions", backend)
            await backend.reply("sessions", APIResult(items: [PickerItem(path: "/filtered")], targets: ["tab"], target: "tab"))
            try await wait { !model.refreshing }
            model.selectView(.agents)
            try await pending("agents", backend)
            await backend.reply("agents", APIResult(items: [PickerItem(path: "A", kind: "agent", sessionID: "S", windowID: "W", blockID: "B")]))
            try await wait { !model.refreshing }

            let token = model.prepareReconfigure(options)
            require(model.listPresentation == previousPresentation + 1,
                    "Reopen must reset the resident list viewport, not only its saved scroll ID")
            require(model.contextReady && model.canOpen && !model.loading && model.view == .sessions && model.page == .directories && model.query.isEmpty,
                         "Warm same-context reopen must enable Open synchronously, before any backend reply")
            require(model.items == launcherRows.items && model.selectedID == "/a" && model.scrollID == nil && model.targets == ["tab", "session"] && model.target == "tab",
                         "Warm reopen: items=\(model.items.count) selected=\(model.selectedID ?? "nil") scroll=\(model.scrollID ?? "nil") target=\(model.target) ttl=\(ttl)")
            await model.completeReconfigure(token)
            for _ in 0..<10 {
                await model.reconfigure(options)
                require(model.canOpen && model.target == "tab" && model.selectedID == "/a" && model.scrollID == nil)
                await Task.yield()
            }
            let contexts = await backend.count("context")
            let themes = await backend.count("theme")
            require(contexts == 0 && themes == 1,
                         "Warm reopen must skip context/theme RPCs and honor TTL")
            model.choose()
            try await wait { !model.busy }
            let opens = await backend.count("dispatch")
            require(opens == 1, "Cached Open must dispatch before the background directory reply")
            if ttl == 0 { await backend.reply("sessions", launcherRows) }
            model.close()
        }

        // Each backend context component must independently disable the fast path.
        for flag in ["--session", "--block", "--client", "--title"] {
            let backend = CachedListBackend()
            let model = PickerModel(options: options, backend: backend)
            model.start()
            try await pending("sessions", backend)
            await backend.reply("sessions", launcherRows)
            try await wait { !model.refreshing && model.themeLoaded }
            await backend.hold("context")
            let changed = try LaunchOptions(arguments: ["--demo", "--session", "S", "--block", "B", "--client", "C", "--title", "T", flag, "changed"])
            let token = model.prepareReconfigure(changed)
            require(!model.contextReady && !model.canOpen && model.targets.isEmpty && model.target.isEmpty,
                         "A changed context component must gate actions and discard cached targets")
            require(model.refreshTheme() == nil, "Appearance polling must not jump ahead of context and initial rows")
            model.choose(); model.showWorktrees(); model.switchView()
            let completion = Task { await model.completeReconfigure(token) }
            try await pending("context", backend)
            let sessionsCalls = await backend.count("sessions")
            let dispatches = await backend.count("dispatch")
            require(sessionsCalls == 1 && dispatches == 0 && !model.contextReady)
            await backend.reply("context", APIResult())
            await completion.value
            try await pending("sessions", backend)
            require(!model.canOpen, "Context acknowledgement alone must not trust old-origin targets")
            await backend.reply("sessions", launcherRows)
            try await wait { !model.refreshing }
            require(model.canOpen)
            let themes = await backend.count("theme")
            require(themes == 1, "A loaded theme must not reload on reopen")
            model.close()
        }
        print("PASS: synchronous warm reopen, unfiltered launcher rows and targets, pre-reply Open, theme/context RPC bypass, refresh TTL/coalescing, all changed-context components gated")
    }

    @MainActor private static func pending(_ method: String, _ backend: CachedListBackend, line: UInt = #line) async throws {
        // Headless model calls must survive a busy machine: a short budget made
        // this flaky under load, which surfaced as a crash report instead of a
        // failure.
        for _ in 0..<750 {
            if await backend.waiting(method) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        testFailure("Timed out waiting for \(method) (caller line \(line))")
    }

    @MainActor private static func suggestedBranchChecks() async throws {
        let decoded = try JSONDecoder().decode(APIResult.self, from: Data(#"{"suggested_branch":"amber-falcon"}"#.utf8))
        require(decoded.suggestedBranch == "amber-falcon")
        let options = try LaunchOptions(arguments: ["--demo", "--mode", "wt-create", "--repo", "/demo"])
        let demo = DemoBackend()
        let direct = PickerModel(options: options, backend: demo)
        direct.start()
        direct.submitBranch() // Loading Enter must not be queued.
        try await wait { direct.canCreate }
        require(direct.branch == "amber-falcon" && direct.base == "main" && direct.target == "tab")
        require(direct.destination == "/Users/demo/Projects/example-kit-worktrees/amber-falcon")
        let before = await demo.count("worktrees.create")
        require(before == 0 && !direct.basePickerPresented)
        direct.submitBranch()
        direct.submitBranch()
        try await wait { direct.createdPath != nil && !direct.busy }
        let creates = await demo.count("worktrees.create"), opens = await demo.count("dispatch")
        require(creates == 1 && opens == 1, "One Enter creates and opens; repeated Enter cannot duplicate")
        let params = await demo.parameters("worktrees.create")
        if case .text("amber-falcon") = params["branch"], case .text("main") = params["base"],
           case .text("/Users/demo/Projects/example-kit") = params["repo"] {} else { testFailure("Wrong default create params") }
        let dispatch = await demo.parameters("dispatch")
        if case .text("tab") = dispatch["target"], case .text("/Users/demo/Projects/example-kit-worktrees/amber-falcon") = dispatch["path"] {} else { testFailure("Wrong default dispatch") }
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
            require(model.branch == (edit ?? "quiet-otter"), "Metadata must preserve early typing and explicit blank")
            if edit != "" {
                try await pending("worktrees.preview", backend)
                model.submitBranch()
                await backend.reply("worktrees.preview", APIResult(path: "/demo/new", validationError: "Branch already exists"))
                try await wait { model.previewReady }
                model.submitBranch()
                require(!model.canCreate && !model.basePickerPresented)
            }
            let count = await backend.count("worktrees.create")
            require(count == 0, "Loading or collision must block Enter")
            model.close()
        }

        let backend = CachedListBackend()
        let listOptions = try LaunchOptions(arguments: ["--demo", "--mode", "wt", "--repo", "/demo"])
        let list = PickerModel(options: listOptions, backend: backend)
        list.page = .worktrees // Retained internal metadata helper coverage.
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
        require(list.branch == "fresh-otter" && list.base == "main", "List entry must prefill synchronously with current metadata")
        list.query = "default-form-query"
        try await Task.sleep(for: .milliseconds(200))
        require(list.branch == "fresh-otter", "Query must not replace the initial default")
        list.editBranch("feat/custom")
        list.query = "ignored-form-query"
        try await Task.sleep(for: .milliseconds(200))
        require(list.branch == "feat/custom", "Query must not rename the form")
        list.escape()
        try await pending("worktrees.list", backend)
        await backend.reply("worktrees.list", metadata("next-otter"))
        try await wait { !list.refreshing }
        list.beginCreate()
        require(list.branch == "next-otter" && !list.branchWasEdited, "New form resets edit/default flags")
        list.escape()
        try await pending("worktrees.list", backend)
        await backend.reply("worktrees.list", metadata(nil))
        try await wait { !list.refreshing }
        list.beginCreate()
        require(list.branch.isEmpty && !list.canCreate, "Missing suggestion requires manual input")
        list.editBranch("feat/manual")
        require(list.branch == "feat/manual" && list.branchWasEdited)
        list.close()

        let continuation = PickerModel(options: try LaunchOptions(arguments: ["--demo", "--mode", "wt-create"]), backend: DemoBackend())
        continuation.start()
        try await wait { !continuation.loading }
        require(continuation.page == .directories && continuation.view == .sessions,
                     "A missing repository must fall back to the launcher")
        continuation.selectedID = continuation.items.first { $0.kind == "dir" }?.id
        continuation.showWorktrees()
        try await wait { !continuation.loading }
        continuation.beginCreate()
        try await wait { continuation.canCreate }
        require(continuation.branch == "amber-falcon")
        continuation.editBranch("feat/old-repo")
        let newRepoOptions = try LaunchOptions(arguments: ["--demo", "--mode", "wt-create", "--repo", "/another-repo"])
        let token = continuation.prepareReconfigure(newRepoOptions)
        require(continuation.branch.isEmpty && !continuation.branchWasEdited)
        await continuation.completeReconfigure(token)
        try await wait { continuation.canCreate }
        require(continuation.branch == "amber-falcon")
        continuation.close()
        print("PASS: suggested branch decoding, direct/list prefill, one-Enter create/open, early edits/blank, refresh, reset, missing suggestion, collision and loading gates")
    }

    @MainActor private static func directCreateChecks() async throws {
        let options = try LaunchOptions(arguments: ["--demo", "--mode", "wt-create", "--repo", "/origin"])
        require(options.mode == "wt-create" && options.repo == "/origin")
        let backend = DelayedMetadataBackend()
        let direct = PickerModel(options: options, backend: backend)
        require(direct.page == .create && direct.loading && !direct.canSubmitForm,
                     "Direct launch must render a disabled form before starting backend work")
        direct.start()
        direct.branch = "feat/typed-early"
        direct.create()
        try await Task.sleep(for: .milliseconds(230))
        let pendingMethods = await backend.methods()
        require(direct.page == .create && direct.branch == "feat/typed-early" && !direct.canCreate)
        require(pendingMethods.filter { $0 != "theme" } == ["worktrees.list"], "Metadata must precede preview and create")
        try await wait { direct.canCreate }
        let origin = await backend.requestedRepo()
        require(origin == "/origin" && direct.repo == "/resolved" && direct.items.isEmpty)
        require(direct.branch == "feat/typed-early" && direct.base == "main")
        require(PickerStyle.height(for: direct) == 240)
        direct.validationError = "Branch already exists"
        require(!direct.canSubmitForm && PickerStyle.height(for: direct) == 264)
        direct.error = "Backend error"
        require(PickerStyle.height(for: direct) == 296)
        direct.validationError = nil
        direct.error = nil
        let targets = ["tab", "session", "here", "pane_right", "pane_below"]
        let labels = ["New tab", "Session", "cd here", "Split right", "Split below"]
        require(direct.targets == targets)
        for (target, label) in zip(targets, labels) {
            require(direct.target == target && PickerModel.targetLabel(target) == label)
            direct.cycleTarget(backward: false)
        }
        require(direct.target == "tab", "Ctrl+O must wrap through all five targets")
        for target in targets.reversed() {
            direct.cycleTarget(backward: true)
            require(direct.target == target)
        }
        var closed = false
        direct.onClose = { closed = true }
        direct.onDismiss = { direct.close() } // Nonresident idle dismissal.
        direct.basePickerPresented = true
        direct.escape()
        require(!direct.basePickerPresented && !closed && direct.page == .create)
        direct.escape()
        require(closed, "Direct Escape must close, not show a worktree list")

        let slow = PickerModel(options: options, backend: DelayedMetadataBackend())
        var slowClosed = false
        slow.onClose = { slowClosed = true }
        slow.onDismiss = { slow.close() } // Nonresident idle dismissal.
        slow.start()
        slow.branch = "feat/typed-early"
        try await Task.sleep(for: .milliseconds(40))
        slow.escape()
        require(slowClosed && !slow.canCreate, "Escape must work while metadata loads")
        try await Task.sleep(for: .milliseconds(350))
        require(slow.repo == "/origin" && slow.base.isEmpty && !slow.previewReady,
                     "Late metadata must not update a closed picker")

        let fallback = PickerModel(options: try LaunchOptions(arguments: ["--demo", "--mode", "wt-create"]), backend: DemoBackend())
        fallback.start()
        require(fallback.page == .create)
        try await wait { !fallback.loading }
        require(fallback.page == .directories && fallback.view == .sessions && !fallback.items.isEmpty,
                     "A missing repository must fall back to the launcher")
        fallback.selectedID = fallback.items.first { $0.kind == "dir" }?.id
        fallback.showWorktrees()
        try await wait { !fallback.loading }
        fallback.beginCreate()
        require(fallback.page == .create && !fallback.canCreate,
                     "Create must wait for metadata before accepting input")
        fallback.branch = "feat/repository"
        try await wait { fallback.canCreate }
        require(fallback.page == .create && fallback.items.isEmpty && fallback.branch == "feat/repository")
        fallback.close()
        print("PASS: immediate direct form, origin metadata, early typing, disabled submit, close during load, stale metadata, launcher fallback continuation, direct Escape/popover, five target labels and bidirectional cycling")
    }

    @MainActor private static func wait(_ condition: () -> Bool, label: String = "model", line: UInt = #line) async throws {
        for _ in 0..<1500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        testFailure("Timed out waiting for \(label) (caller line \(line))")
    }

    @MainActor private static func themeIntegrationChecks() async throws {
        let options = try LaunchOptions(arguments: [])
        let backend = ProcessBackend(options: options)
        let result = try await backend.request("theme", params: [:])
        require(result.theme?.name == "Wire Forest" && result.theme?.background == "#102030" &&
                     result.theme?.ui?.selection == "#bfbfbf",
                     "Real backend NDJSON must decode result.theme, not silently drop a flat palette")
        let model = PickerModel(options: options, backend: backend)
        await model.refreshTheme()?.value
        require(model.themeRevision == 1 && model.themeLoaded && PickerPalette.isDark,
                     "The real backend must update the native model's palette")
        require(NSColor(PickerStyle.background) == NSColor(hexColor("#333333")!) &&
                     NSColor(PickerStyle.selection) == NSColor(hexColor("#bfbfbf")!) &&
                     NSColor(PickerStyle.selectionText) == NSColor(hexColor("#1a191a")!) &&
                     PickerPalette.selectionOpacity == 0.75,
                     "Native selection must use UI tokens, not terminal selection colors")
        let label = NSColor(PickerStyle.foreground).usingColorSpace(.sRGB)!
        require(abs(label.redComponent - label.greenComponent) < 0.01 &&
                     abs(label.greenComponent - label.blueComponent) < 0.01,
                     "Glass chrome must keep native neutral labels, not green terminal text")
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: .zero)
            glass.wantsLayer = true
            PickerStyle.applyPanelTheme(to: glass)
            require(glass.tintColor == NSColor(hexColor("#333333")!).withAlphaComponent(0.35),
                         "Real backend colors must reach the panel material")
        }
        model.close()
        print("PASS: real backend → NDJSON → Swift decoding → model → selected text and native panel tint")
    }

    private static func queuedSearchChecks(_ options: LaunchOptions) async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("aux/native-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = directory.appendingPathComponent("gate").path
        let backend = ProcessBackend(options: options)
        defer { backend.close() }
        let inFlight = Task { try await backend.request("sessions", params: ["query": .text("in-flight"), "gate": .text(gate)]) }
        for _ in 0..<2000 {
            if FileManager.default.fileExists(atPath: gate + ".ready") { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        require(FileManager.default.fileExists(atPath: gate + ".ready"), "Fixture must hold an issued read")
        inFlight.cancel() // It must still drain its own response ID.
        let obsolete = (0..<20).map { index in
            let task = Task { try await backend.request(index % 3 == 0 ? "pullrequests.resolve" : (index % 2 == 0 ? "sessions" : "agents"), params: ["query": .text("old-\(index)")]) }
            task.cancel()
            return task
        }
        let latest = Task { try await backend.request("agents", params: ["query": .text("latest")]) }
        let mutation = Task { try await backend.request("sessions.jump", params: [:]) }
        mutation.cancel() // Never suppress or duplicate a queued mutation.
        let began = ContinuousClock.now
        FileManager.default.createFile(atPath: gate + ".release", contents: Data())
        require(try await inFlight.value.items?.first?.path == "in-flight")
        for task in obsolete {
            do { _ = try await task.value; testFailure("Canceled queued search reached the wire") }
            catch is CancellationError {} // No connection teardown or ID allocation.
        }
        require(try await latest.value.items?.first?.path == "latest")
        let elapsed = began.duration(to: .now)
        _ = try await mutation.value
        let audit = try await backend.request("audit", params: [:]).branches ?? []
        require(audit.count == 4 && audit.filter { $0.contains(":sessions.jump:") }.count == 1,
                "Wire must contain one in-flight read, latest read, one mutation, and audit: \(audit)")
        require(!audit.contains { $0.contains("old-") })
        for (index, entry) in audit.enumerated() {
            require(entry.hasPrefix("\(index + 1):"), "Skipped reads must not consume protocol IDs")
        }
        print("PASS: blocked transport: 20 canceled queued searches=0 wire requests; in-flight drained, latest=1, canceled mutation=1, contiguous IDs; release-to-latest=\(elapsed)")
    }

    @MainActor private static func pullRequestReconnectChecks() async throws {
        for input in ["12", "13"] {
            let options = try LaunchOptions(arguments: ["--mode", "pr", "--repo", "/ambient",
                "--session", "S", "--block", "B", "--client", "C", "--title", "A title"])
            let backend = ProcessBackend(options: options)
            let model = PickerModel(options: options, backend: backend)
            model.keepsBackendWarmOnNavigation = true
            model.start()
            model.prInput = "https://github.com/o/r/pull/\(input)"
            try await wait { model.canOpenPullRequest }
            model.target = input == "13" ? "tab" : "session"
            model.openPullRequest()
            try await wait { !model.busy && model.createdPath != nil && model.backendIsClosed }
            require(model.canOpenPullRequest && model.error != nil, "Closed PR recovery must allow Retry")
            model.escape()
            require(model.createdPath == "/pr-\(input)" && model.page == .pr)
            let unrelated = try LaunchOptions(arguments: ["--session", "unrelated", "--client", "other", "--repo", "/other"])
            let token = model.prepareReconfigure(unrelated)
            await model.completeReconfigure(token)
            let savedError = model.error
            require(model.target == (input == "13" ? "tab" : "session") && model.options.matches(options))
            if input == "12" {
                // Resident reopen rebinds without changing any recovery fields.
                require(model.reconnectPullRequestBackend())
                require(model.error == savedError && model.target == "session" && model.repo == "/ambient")
                require(model.createdPath == "/pr-12" && model.options.matches(options))
                require(!model.reconnectPullRequestBackend(), "Live backend must not be replaced")
            }
            // Second case reconnects directly from Retry, without a resident reopen.
            model.openPullRequest()
            try await wait { !model.busy }
            require(model.createdPath == nil && model.error == nil && !model.backendIsClosed,
                    "Reconnected Open must succeed without Prepare in the original context")
            model.close()
        }
        print("PASS: PR structured-error/EOF recovery reconnects in place; original context, path, target, error retained; Retry never prepares")
    }

    private static func transportChecks() async throws {
        let options = try LaunchOptions(arguments: ["--session", "S", "--block", "B", "--client", "C", "--title", "A title"])
        try await queuedSearchChecks(options)
        try await pullRequestReconnectChecks()
        let dismissed = ProcessBackend(options: options)
        dismissed.close() // Closing before the first request must not start a child.
        do {
            _ = try await dismissed.request("ok", params: [:])
            testFailure("Closed connection survived close")
        } catch {}
        let backend = ProcessBackend(options: options)
        _ = try await backend.request("ok", params: [:])
        do {
            _ = try await backend.request("error", params: [:])
            testFailure("API error accepted")
        } catch { require(error.localizedDescription == "fixture error", "Unexpected error: \(error.localizedDescription)") }
        _ = try await backend.request("ok", params: [:])
        let events = EventCounter()
        _ = try await backend.setChangeHandler { Task { await events.increment() } }
        var idleSeen = false
        for _ in 0..<200 {
            if await events.count() >= 1 { idleSeen = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        require(idleSeen, "Idle notifications must be read without a request")
        _ = try await backend.request("interleaved", params: [:])
        try await Task.sleep(for: .milliseconds(30))
        require(await events.count() == 2, "Interleaved notifications must not consume a response ID")
        _ = try await backend.setChangeHandler(nil)
        _ = try await backend.request("interleaved", params: [:])
        try await Task.sleep(for: .milliseconds(30))
        require(await events.count() == 2, "Unsubscribed notifications must not reach the consumer")
        backend.close()
        for _ in 0..<8 {
            let finalReply = ProcessBackend(options: options)
            _ = try await finalReply.request("reply-and-eof", params: [:])
            do {
                _ = try await finalReply.request("ok", params: [:])
                testFailure("EOF connection accepted a later request")
            } catch {}
            finalReply.close()
        }
        let graceful = ProcessBackend(options: options)
        let identity = try await graceful.request("graceful-close", params: [:])
        guard let path = identity.path, let pid = Int32(path) else { testFailure("Missing fixture process ID") }
        graceful.close()
        let shutdown = Date()
        while kill(pid, 0) == 0 && Date().timeIntervalSince(shutdown) < 0.9 {
            try await Task.sleep(for: .milliseconds(10))
        }
        require(kill(pid, 0) != 0, "Backend must receive EOF and exit before signal escalation")
        for method in ["bad-id", "malformed", "eof", "both", "no-result", "event-id", "unknown-event"] {
            let connection = ProcessBackend(options: options)
            do {
                _ = try await connection.request(method, params: [:])
                testFailure("Invalid transport accepted: \(method)")
            } catch {}
            do {
                _ = try await connection.request("ok", params: [:])
                testFailure("Broken connection reused: \(method)")
            } catch {}
            connection.close()
        }
        let blocked = ProcessBackend(options: options)
        let pending = Task { try await blocked.request("hang", params: [:]) }
        try await Task.sleep(for: .milliseconds(100))
        blocked.close()
        do {
            _ = try await pending.value
            testFailure("In-flight request survived close")
        } catch {}
        let timed = ProcessBackend(options: options)
        let began = Date()
        do {
            _ = try await timed.request("hang", params: [:])
            testFailure("Request exceeded its deadline without failing")
        } catch {}
        require(timed.isClosed && Date().timeIntervalSince(began) >= 29 && Date().timeIntervalSince(began) < 35,
                "Request timeout must close and wake the connection at 30 seconds")
        print("PASS: persistent NDJSON, split reads, idle/interleaved notifications, unsubscribe, valid API error recovery, strict IDs/envelopes, malformed JSON, EOF, closed connection, final reply before EOF, graceful EOF shutdown and 30-second timeout")
    }
}
