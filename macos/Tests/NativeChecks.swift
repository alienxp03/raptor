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
        let screen = CGRect(x: -1200, y: 200, width: 1200, height: 800)
        let frame = PickerStyle.panelFrame(in: screen, height: 220)
        let taller = PickerStyle.panelFrame(in: screen, height: 400)
        precondition(frame.midX == screen.midX && frame.maxY == screen.maxY - 72,
                     "Picker must anchor below the top of the active screen")
        precondition(taller.maxY == frame.maxY, "Content growth must preserve the top anchor")
        let decoded = try JSONDecoder().decode(APIResult.self, from: Data("{\"needs_repo\":false,\"base_branch\":\"main\",\"items\":[{\"path\":\"/a\",\"branch\":\"main\",\"is_main\":true}]}".utf8))
        precondition(decoded.items?.first?.isMain == true && decoded.baseBranch == "main")

        precondition(PickerModel.targetLabel("tab") == "New tab")
        precondition(PickerModel.targetLabel("session") == "Session")
        precondition(PickerModel.targetLabel("here") == "Current shell")
        let backend = DemoBackend()
        let model = PickerModel(options: options, backend: backend)
        model.start()
        try await wait { !model.loading }
        precondition(model.page == .worktrees && model.items.count == 3)
        precondition(PickerStyle.width == 440 && PickerStyle.height(for: model) == 220,
                     "The picker must keep Rex-sized, content-fitted proportions")
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
        precondition(PickerStyle.height(for: model) == 400, "Creation form grew beyond the compact layout")
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
        precondition(model.items.count == 3, "Create submitted more than once")
        model.toggleSplit()
        precondition(model.splitMode)
        model.escape()
        precondition(!model.splitMode && model.page == .worktrees)
        let previousTarget = model.target
        model.cycleTarget(backward: false)
        model.cycleTarget(backward: true)
        precondition(model.target == previousTarget)
        model.close()

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
        precondition(PickerStyle.height(for: stale) == 146, "Filtered results must shrink the panel")
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
        let retry = PickerModel(options: options, backend: retryBackend)
        retry.start()
        try await wait { !retry.loading }
        retry.beginCreate()
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
