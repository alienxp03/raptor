import AppKit
import QuartzCore

/// Visual bridge between the source window and the search field. The source
/// is an estimate: Rex does not provide a terminal caret position here.
@MainActor
final class CaretFlight {
    private var overlay: NSPanel?
    private var revision = UUID()

    func cancel() {
        revision = UUID()
        overlay?.orderOut(nil)
        overlay = nil
    }

    func play(from start: CGPoint, to end: CGPoint, color: NSColor) {
        cancel()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              hypot(end.x - start.x, end.y - start.y) > 4 else { return }
        let token = revision
        let frame = CGRect(x: min(start.x, end.x) - 24, y: min(start.y, end.y) - 24,
                           width: abs(end.x - start.x) + 48, height: abs(end.y - start.y) + 48)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        panel.contentView = view
        let ink = CAShapeLayer()
        ink.fillColor = color.cgColor
        ink.shadowColor = color.cgColor
        ink.shadowOpacity = 0.35
        ink.shadowRadius = 3
        view.layer?.addSublayer(ink)
        let a = CGPoint(x: start.x - frame.minX, y: start.y - frame.minY)
        let b = CGPoint(x: end.x - frame.minX, y: end.y - frame.minY)
        func point(_ t: CGFloat) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        let paths: [CGPath] = (0...30).map { step in
            let t = CGFloat(step) / 30
            let progress = t * t * (3 - 2 * t)
            let head = point(progress)
            let tail = point(max(0, progress - 0.22 * sin(.pi * t)))
            // Broaden during flight, then settle back to a thin text caret.
            let swell = sin(.pi * t)
            let halfWidth = 1 + 6 * swell
            let halfHeight = 7 + 6 * swell
            let path = CGMutablePath()
            path.move(to: CGPoint(x: tail.x - halfWidth, y: tail.y - halfHeight))
            path.addLine(to: CGPoint(x: head.x + halfWidth, y: head.y - halfHeight))
            path.addLine(to: CGPoint(x: head.x + halfWidth, y: head.y + halfHeight))
            path.addLine(to: CGPoint(x: tail.x - halfWidth, y: tail.y + halfHeight))
            path.closeSubpath()
            return path
        }
        ink.path = paths.last
        let flight = CAKeyframeAnimation(keyPath: "path")
        flight.values = paths
        flight.duration = 0.12
        ink.add(flight, forKey: "flight")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + 0.09
        fade.duration = 0.04
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        ink.add(fade, forKey: "fade")
        overlay = panel
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.revision == token else { return }
            self.cancel()
        }
    }
}
