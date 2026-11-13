import AppKit
import SwiftUI

struct DeletionLayoutChecks {
    @MainActor static func run() throws {
        let options = try LaunchOptions(arguments: ["--demo", "--mode", "sessions"])
        let model = PickerModel(options: options, backend: DemoBackend())
        defer { model.close() }
        let candidate = PickerItem(path: "session:new", label: "new", kind: "session", sessionID: "session:new", host: "mac")
        let error = "fatal: not a git repository (or any of the parent directories): .git"
        var blocked = PickerModel.SessionDeletion(candidate: candidate)
        blocked.phase = .confirm
        blocked.plan = APIResult(worktrees: [DeletionWorktree(path: "/Users/demo", error: error)])
        try check(PickerStyle.deletionErrorSummary(error) == "Not a Git repository.", "Short Git error summary")
        try check(!PickerStyle.hasDeletionSelection(blocked), "Protected paths must not expose unusable delete controls")
        try check(PickerStyle.deletionHeight(blocked) <= 210, "A blocked-only review must fit a compact page")

        var selected = PickerModel.SessionDeletion(candidate: candidate)
        selected.phase = .confirm
        let row = DeletionWorktree(repo: "/Users/demo/Projects/app", path: "/Users/demo/Projects/app.feature", branch: "feat/remittance")
        selected.plan = APIResult(deleteToken: "fixture", worktrees: [row])
        selected.selectedPaths = [row.path]
        try check(PickerStyle.hasDeletionSelection(selected), "Keep the explicit close consent and delete action for eligible rows")
        let selectedHeight = PickerStyle.deletionHeight(selected)
        try check(selectedHeight <= 260, "Single-worktree review must not reserve 380pt")
        var inline = selected
        inline.plan?.worktrees?[0].prepared = false
        inline.automaticallyVerifies = true
        inline.phase = .loading
        try check(PickerStyle.deletionPendingStatus(inline) == "Queued for automatic checks…",
                  "An identified row waiting for automatic checks must show a queue, not a verification failure")
        inline.phase = .review
        let selectionHeight = PickerStyle.deletionHeight(inline)
        inline.phase = .preparing
        inline.preparationSelection = inline.selectedPaths
        try check(PickerStyle.deletionPendingStatus(inline) == "Queued for automatic checks…",
                  "A later batch must use the same automatic queued status")
        inline.checkingPath = row.path
        try check(PickerStyle.deletionHeight(inline) == selectionHeight && selectionHeight == selectedHeight,
                  "Selection, inline verification and clean confirmation must keep the same page layout")
        selected.phase = .forceConfirm
        try check(PickerStyle.deletionHeight(selected) > selectedHeight, "Force deletion must reserve room for its irreversible-loss warning")
        selected.phase = .confirm
        selected.plan?.worktrees = (0..<20).map { index in
            DeletionWorktree(repo: row.repo, path: row.path + "-\(index)", branch: "feat/topic-\(index)")
        }
        let manyHeight = PickerStyle.deletionHeight(selected)
        let visibleRows = Array(selected.plan!.worktrees!.prefix(5))
        selected.plan?.worktrees = visibleRows
        try check(PickerStyle.deletionHeight(selected) == manyHeight && manyHeight > selectedHeight,
                  "Large selections should scroll after five rows, not grow the window indefinitely")

        if let directory = ProcessInfo.processInfo.environment["RAPTOR_DELETE_SCREENSHOTS"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try export(blocked, model: model, to: directory + "/blocked.png")
            selected.plan?.worktrees = [row]
            try export(selected, model: model, to: directory + "/selected.png")
            selected.phase = .forceConfirm
            try export(selected, model: model, to: directory + "/force.png")
        }
        print("PASS: compact deletion height, concise errors, blocked-only controls, force-warning space and bounded multi-row scrolling")
    }

    @MainActor private static func export(_ deletion: PickerModel.SessionDeletion, model: PickerModel, to path: String) throws {
        let view = DeleteSessionPage(model: model, deletion: deletion)
            .frame(width: PickerStyle.width, height: PickerStyle.deletionHeight(deletion))
            .background(PickerStyle.background)
            .preferredColorScheme(PickerPalette.isDark ? .dark : .light)
        // ImageRenderer omits native ScrollView content. Use an inert fixture
        // window so visual checks include the real AppKit controls and layout.
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: PickerStyle.width,
                              height: PickerStyle.deletionHeight(deletion)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        window.displayIfNeeded()
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(window.windowNumber), path]
        capture.standardInput = FileHandle.nullDevice
        try capture.run()
        capture.waitUntilExit()
        try check(capture.terminationStatus == 0, "Could not capture deletion fixture")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw APIError.message(message) }
    }
}
