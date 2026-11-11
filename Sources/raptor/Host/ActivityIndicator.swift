import SwiftUI

/// No repeating work for idle, offscreen, hidden-panel or reduced-motion rows.
struct ActivityIndicator: View {
    let activity: ActivityProjection
    var workingColor: Color = .primary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var panelVisible = false

    var body: some View {
        HStack(spacing: 4) {
            if activity.blocked { dot(.orange) }
            if activity.working {
                if activity.shouldPulse(reduceMotion: reduceMotion, visible: visible && panelVisible) {
                    TimelineView(.animation(minimumInterval: 1 / 24)) { context in
                        workingDots(at: context.date.timeIntervalSinceReferenceDate)
                    }
                } else { workingDots(at: nil) }
            }
        }
        .background(PanelVisibilityReader { panelVisible = $0 })
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .accessibilityHidden(true)
    }

    private func workingDots(at time: TimeInterval?) -> some View {
        let opacities = ActivityProjection.workingDotOpacities(at: time)
        return HStack(spacing: 3) {
            ForEach(0..<3) { index in
                dot(workingColor).opacity(opacities[index])
            }
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 5, height: 5)
    }
}

private struct PanelVisibilityReader: NSViewRepresentable {
    let update: (Bool) -> Void
    func makeNSView(context: Context) -> VisibilityView { VisibilityView(update: update) }
    func updateNSView(_ view: VisibilityView, context: Context) {}

    final class VisibilityView: NSView {
        let update: (Bool) -> Void
        private var observer: NSObjectProtocol?
        init(update: @escaping (Bool) -> Void) { self.update = update; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            report()
            if let window {
                observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
        }
        private func report() {
            let shown = window?.occlusionState.contains(.visible) == true
            DispatchQueue.main.async { [update] in update(shown) }
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
