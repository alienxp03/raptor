import AppKit
import SwiftUI

@main
@MainActor
struct ShowcaseCapture {
    static func main() async throws {
        let output = CommandLine.arguments.dropFirst().first ?? "docs/screenshots"
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        PickerPalette.useFallback(dark: true)

        let launcher = makeModel(mode: "sessions", session: "session:demo-1")
        launcher.start()
        try await wait { !launcher.loading && !launcher.items.isEmpty }
        try await capture(launcher, name: "sessions.png", in: output)
        launcher.close()

        let search = makeModel(mode: "sessions", session: "session:demo-1")
        search.query = "atlas"
        search.start()
        try await wait { !search.loading && search.items.count == 2 && search.selected?.label == "atlas-notes" }
        try await capture(search, name: "search.png", in: output)
        search.close()

        let worktree = makeModel(mode: "wt-create", repo: "/Users/demo/Projects/orbit-web")
        worktree.start()
        try await wait { !worktree.loading && worktree.previewReady }
        try await capture(worktree, name: "worktree-create.png", in: output)
        worktree.close()

        let list = makeModel(mode: "sessions", session: "session:demo-1")
        list.start()
        try await wait { !list.loading && !list.items.isEmpty }
        if let directory = list.items.first(where: { $0.label == "orbit-web" && $0.kind == "dir" }) {
            list.selectedID = directory.id
            list.showWorktrees()
            try await wait { !list.loading && list.page == .worktrees && !list.items.isEmpty }
            try await capture(list, name: "worktrees.png", in: output)
            list.beginCreate()
            try await wait { list.page == .create && list.previewReady }
            try await capture(list, name: "worktree-create.png", in: output)
        }
        list.close()

        let review = makeModel(mode: "sessions", session: "session:demo-1")
        review.start()
        try await wait { !review.loading && !review.items.isEmpty }
        if let session = review.items.first(where: { $0.sessionID == "session:demo-2" }) {
            review.selectedID = session.id
            review.beginDeleteSession()
            try await wait { review.sessionDeletion?.phase == .confirm || review.sessionDeletion?.phase == .forceOffered }
            try await capture(review, name: "delete-review.png", in: output)
        }
        review.close()

        let split = makeModel(mode: "sessions", session: "session:demo-1")
        split.start()
        try await wait { !split.loading && !split.items.isEmpty }
        split.splitMode = true
        try await capture(split, name: "split-mode.png", in: output)
        split.close()

        let pr = makeModel(mode: "sessions", session: "session:demo-1")
        pr.start()
        try await wait { !pr.loading && !pr.items.isEmpty }
        pr.beginPullRequest(input: "https://github.com/example-labs/orbit-web/pull/4821")
        try await wait { pr.pullRequest?.title != nil }
        try await capture(pr, name: "pull-request.png", in: output)
        pr.close()
    }

    private static func makeModel(mode: String, session: String = "", repo: String? = nil) -> PickerModel {
        var args = ["--demo", "--mode", mode]
        if !session.isEmpty { args += ["--session", session] }
        if let repo { args += ["--repo", repo] }
        return PickerModel(options: try! LaunchOptions(arguments: args), backend: DemoBackend(showcase: true),
                           pullRequestClipboard: { nil })
    }

    private static func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "ShowcaseCapture", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for synthetic UI state"])
    }

    private static func capture(_ model: PickerModel, name: String, in directory: String) async throws {
        let size = CGSize(width: PickerStyle.width, height: PickerStyle.height(for: model))
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 80, y: 80), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        let hosting = NSHostingView(rootView: PickerView(model: model))
        hosting.frame = NSRect(origin: .zero, size: size)
        let surface = NSView(frame: NSRect(origin: .zero, size: size))
        surface.wantsLayer = true
        surface.layer?.backgroundColor = NSColor(PickerStyle.background).cgColor
        surface.layer?.cornerRadius = PickerStyle.radius
        surface.layer?.masksToBounds = true
        surface.addSubview(hosting)
        window.contentView = surface
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(350))
        window.displayIfNeeded()
        let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(window.windowNumber), path]
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ShowcaseCapture", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Screenshot failed: \(path)"])
        }
        window.close()
    }
}
