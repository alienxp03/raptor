import AppKit

/// Mouse-only dismissal: losing key status to a popover is not an outside click.
@MainActor
final class OutsideClickMonitor {
    private weak var panel: NSWindow?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var onOutsideClick: (() -> Void)?

    func start(panel: NSWindow, onOutsideClick: @escaping () -> Void) {
        stop()
        self.panel = panel
        self.onOutsideClick = onOutsideClick
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event // The clicked control/app still receives its click.
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        panel = nil
        onOutsideClick = nil
    }

    static func isOutside(_ point: NSPoint, frames: [NSRect]) -> Bool {
        !frames.contains { NSMouseInRect(point, $0, false) }
    }

    private func handle(_ event: NSEvent) {
        guard let panel, panel.isVisible else { return }
        // This accessory app owns only the picker and its auxiliary windows.
        // Include SwiftUI popovers, sheets, and their event window even when
        // AppKit does not attach them as child windows of the panel.
        var windows = NSApp.windows
        if let window = event.window, !windows.contains(where: { $0 === window }) {
            windows.append(window)
        }
        let frames = windows.filter { $0.isVisible && $0.alphaValue > 0 }.map(\.frame)
        guard Self.isOutside(NSEvent.mouseLocation, frames: frames) else { return }
        onOutsideClick?()
    }
}
