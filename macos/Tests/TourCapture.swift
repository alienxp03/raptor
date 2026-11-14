import AppKit
import SwiftUI

@main
@MainActor
struct TourCapture {
    private static let sessionID = "session:demo-2"
    private static let prURL = "https://github.com/example-labs/orbit-web/pull/4821"

    static func main() async throws {
        let output = CommandLine.arguments.dropFirst().first ?? "/tmp/raptor-tour"
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        PickerPalette.useFallback(dark: true)

        let overview = makeModel()
        overview.start()
        try await wait { !overview.loading && overview.items.count >= 5 }
        try await capture(overview, title: "Open the session list", detail: "Sessions, projects, and Rex hosts in one place.", step: "01 / OVERVIEW", name: "01-overview.png", in: output)
        overview.close()

        let search = makeModel()
        search.query = "atlas"
        search.start()
        try await wait { !search.loading && search.items.contains(where: { $0.label == "atlas-notes" }) }
        try await capture(search, title: "Find a session or project", detail: "Search names across local and remote work.", step: "02 / FIND", name: "02-find.png", in: output)
        search.close()

        let rename = makeModel()
        rename.start()
        try await wait { !rename.loading && rename.items.contains(where: { $0.sessionID == sessionID }) }
        guard let renameRow = rename.items.first(where: { $0.sessionID == sessionID }) else {
            throw tourError("Synthetic session missing for rename.")
        }
        rename.selectedID = renameRow.id
        rename.beginRenameSession()
        rename.renameLabel = "cinder-labs-api"
        try await capture(rename, title: "Rename a session", detail: "Give active work a name you’ll recognize.", step: "03 / RENAME", name: "03-rename.png", in: output)
        rename.confirmRenameSession()
        try await wait { !rename.busy && rename.items.contains(where: { $0.label == "cinder-labs-api" }) }
        try await capture(rename, title: "Name updated", detail: "The change stays with this session.", step: "03 / RENAME", name: "04-renamed.png", in: output)
        rename.close()

        let close = makeModel()
        close.start()
        try await wait { !close.loading && close.items.contains(where: { $0.sessionID == sessionID }) }
        guard let closeRow = close.items.first(where: { $0.sessionID == sessionID }) else {
            throw tourError("Synthetic session missing for close.")
        }
        close.selectedID = closeRow.id
        close.askCloseSession()
        try await capture(close, title: "Close a session safely", detail: "Confirm the close; keep its worktree and branch.", step: "04 / CLOSE", name: "05-close-confirm.png", in: output)
        guard let candidate = close.sessionCloseCandidate else { throw tourError("Close confirmation did not appear.") }
        close.confirmCloseSession(candidate)
        try await wait { !close.busy && !close.items.contains(where: { $0.sessionID == sessionID }) }
        try await capture(close, title: "Session closed", detail: "The project checkout is still there when you need it.", step: "04 / CLOSE", name: "06-closed.png", in: output)
        close.close()

        let pullRequest = makeModel()
        pullRequest.start()
        try await wait { !pullRequest.loading && !pullRequest.items.isEmpty }
        pullRequest.beginPullRequest(input: prURL)
        try await wait { pullRequest.pullRequest?.title != nil }
        try await capture(pullRequest, title: "Open a GitHub pull request", detail: "Review the branch and destination before opening.", step: "05 / PULL REQUEST", name: "07-pull-request.png", in: output)
        pullRequest.close()

        let worktree = makeModel(mode: "wt-create", repo: "/Users/demo/Projects/orbit-web")
        worktree.start()
        try await wait { !worktree.loading && worktree.previewReady && !worktree.agentCatalogLoading }
        try await capture(worktree, title: "Create a new worktree", detail: "Choose a branch, base, target—and optionally launch Pi.", step: "06 / WORKTREE", name: "08-worktree.png", in: output)
        worktree.close()

        let outro = makeModel()
        outro.start()
        try await wait { !outro.loading && !outro.items.isEmpty }
        try await capture(outro, title: "Raptor for Rex", detail: "Find it. Open it. Get back to work.", step: "RAPTOR", name: "09-outro.png", in: output)
        outro.close()
    }

    private static func makeModel(mode: String = "sessions", repo: String? = nil) -> PickerModel {
        var args = ["--demo", "--mode", mode, "--session", "session:demo-1"]
        if let repo { args += ["--repo", repo] }
        return PickerModel(options: try! LaunchOptions(arguments: args), backend: DemoBackend(showcase: true),
                           pullRequestClipboard: { nil })
    }

    private static func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<120 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw tourError("Timed out waiting for a synthetic picker state.")
    }

    private static func capture(_ model: PickerModel, title: String, detail: String, step: String,
                                name: String, in directory: String) async throws {
        let size = CGSize(width: 1280, height: 720)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        let surface = NSView(frame: NSRect(origin: .zero, size: size))
        surface.wantsLayer = true
        let hosting = NSHostingView(rootView: TourStage(model: model, title: title, detail: detail, step: step))
        hosting.frame = surface.bounds
        surface.addSubview(hosting)
        window.contentView = surface
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(700))
        window.displayIfNeeded()
        guard let image = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else {
            throw tourError("Could not allocate tour scene bitmap.")
        }
        surface.cacheDisplay(in: surface.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else {
            throw tourError("Could not encode tour scene.")
        }
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        window.close()
    }

    private static func tourError(_ message: String) -> NSError {
        NSError(domain: "RaptorTour", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@MainActor
private struct TourStage: View {
    @ObservedObject var model: PickerModel
    let title: String
    let detail: String
    let step: String

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.11, blue: 0.13),
                                    Color(red: 0.055, green: 0.065, blue: 0.075)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RexMockWindow()
                .padding(.horizontal, 28)
                .padding(.top, 30)
                .padding(.bottom, 28)

            HStack(spacing: 30) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 9) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(red: 0.95, green: 0.65, blue: 0.29))
                        Text("RAPTOR FOR REX")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .tracking(1.5)
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    .padding(.bottom, 24)
                    Text(title)
                        .font(.system(size: 37, weight: .semibold, design: .rounded))
                        .tracking(-0.6)
                        .foregroundStyle(Color(red: 0.96, green: 0.95, blue: 0.91))
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)
                        .padding(.bottom, 13)
                    Text(detail)
                        .font(.system(size: 17, weight: .regular, design: .rounded))
                        .foregroundStyle(Color(red: 0.75, green: 0.77, blue: 0.77))
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(4)
                    Spacer()
                    HStack(spacing: 8) {
                        Capsule().fill(Color(red: 0.95, green: 0.65, blue: 0.29)).frame(width: 24, height: 3)
                        Text(step)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .tracking(1.0)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Text("FICTIONAL DEMO · SYNTHETIC DATA ONLY")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(0.7)
                        .foregroundStyle(.white.opacity(0.30))
                        .padding(.top, 10)
                }
                .padding(22)
                .frame(width: 470, height: 360, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.black.opacity(0.54))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.07)))
                }

                Spacer(minLength: 0)

                PickerView(model: model)
                    .frame(width: PickerStyle.width, height: PickerStyle.height(for: model))
                    .background(PickerStyle.background)
                    .clipShape(RoundedRectangle(cornerRadius: PickerStyle.radius))
                    .overlay(RoundedRectangle(cornerRadius: PickerStyle.radius).strokeBorder(PickerPalette.stroke))
                    .shadow(color: .black.opacity(0.45), radius: 28, x: 0, y: 18)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 74)
        }
        .frame(width: 1280, height: 720)
        .clipped()
    }
}

@MainActor
private struct RexMockWindow: View {
    private let muted = Color(red: 0.62, green: 0.65, blue: 0.67)
    private let surface = Color(red: 0.075, green: 0.085, blue: 0.095)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                dot(Color(red: 0.92, green: 0.34, blue: 0.31))
                dot(Color(red: 0.93, green: 0.70, blue: 0.30))
                dot(Color(red: 0.39, green: 0.72, blue: 0.44))
                Spacer()
                Text("REX  /  atlas-notes")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.43))
                Spacer()
                Image(systemName: "rectangle.split.2x1")
                    .foregroundStyle(.white.opacity(0.34))
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Color.white.opacity(0.035))

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 15) {
                    Text("WORKSPACES")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(muted.opacity(0.55))
                    sidebar("atlas-notes", icon: "terminal.fill", selected: true)
                    sidebar("cinder-labs", icon: "terminal.fill")
                    sidebar("atlas-api", icon: "terminal.fill")
                    Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.vertical, 3)
                    sidebar("orbit-web", icon: "folder")
                    sidebar("northstar-api", icon: "folder")
                    Spacer()
                    Text("FICTIONAL REX WORKSPACE")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .tracking(0.7)
                        .foregroundStyle(muted.opacity(0.32))
                }
                .padding(18)
                .frame(width: 220)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .background(Color.white.opacity(0.025))

                Rectangle().fill(.white.opacity(0.07)).frame(width: 1)

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("atlas-notes")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.62))
                        Spacer()
                        Text("LOCAL · PI")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .tracking(0.8)
                            .foregroundStyle(muted.opacity(0.38))
                    }
                    .padding(.bottom, 24)

                    VStack(alignment: .leading, spacing: 12) {
                        term("$ git status --short", color: Color(red: 0.72, green: 0.76, blue: 0.74))
                        term(" M Sources/Search/Index.swift", color: Color(red: 0.83, green: 0.66, blue: 0.42))
                        term("$ pi", color: Color(red: 0.72, green: 0.76, blue: 0.74))
                        term("Working on workspace search…", color: Color(red: 0.54, green: 0.72, blue: 0.61))
                        Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.vertical, 8)
                        term("› Ready for the next task", color: muted.opacity(0.62))
                    }
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    Spacer()
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.09)))
        .shadow(color: .black.opacity(0.25), radius: 40, x: 0, y: 18)
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color.opacity(0.7)).frame(width: 8, height: 8)
    }

    private func sidebar(_ title: String, icon: String, selected: Bool = false) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(selected ? .white.opacity(0.7) : muted.opacity(0.5))
            Text(title).font(.system(size: 11, weight: selected ? .medium : .regular, design: .rounded))
                .foregroundStyle(selected ? .white.opacity(0.78) : muted.opacity(0.52))
            Spacer()
            if selected { Circle().fill(Color(red: 0.95, green: 0.65, blue: 0.29)).frame(width: 5, height: 5) }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(selected ? Color.white.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func term(_ text: String, color: Color) -> some View {
        Text(text).foregroundStyle(color)
    }
}
