import Foundation
import CoreVideo
import QuartzCore

/// One physically integrated spring driving a single CGFloat, repainted every
/// display refresh via CVDisplayLink (vsync-locked). The link callback arrives
/// on a background thread and hops to the main queue, where all state lives.
/// Retargeting mid-flight preserves velocity — the property that makes motion
/// feel connected instead of layered tweens.
@MainActor
final class PanelSpring: NSObject {
    struct Config {
        var stiffness: CGFloat
        var damping: CGFloat
        /// Mass-spring defaults tuned for panel-scale motion: slight overshoot
        /// (zeta ~0.7) that settles in ~0.3s.
        static let panel = Config(stiffness: 190, damping: 21)
        /// Near-critical for height morphs: no bounce, just fluid catch-up.
        static let height = Config(stiffness: 190, damping: 26)
    }

    private var displayLink: CVDisplayLink?
    private var fallbackTimer: DispatchSourceTimer?
    private var last: CFTimeInterval = 0
    private let snapDistance: CGFloat
    private let snapSpeed: CGFloat
    private(set) var value: CGFloat
    private(set) var velocity: CGFloat = 0
    private var target: CGFloat
    private let config: Config
    private let tick: (CGFloat) -> Void
    private let settle: (() -> Void)?

    init(value: CGFloat, target: CGFloat, config: Config,
         tick: @escaping (CGFloat) -> Void, settle: (() -> Void)? = nil) {
        self.value = value
        self.target = target
        self.config = config
        self.tick = tick
        self.settle = settle
        // The snap threshold must scale with the travel distance: a 4% scale
        // range would otherwise "settle" on the first frame.
        self.snapDistance = max(0.002, abs(target - value) * 0.02)
        self.snapSpeed = max(4, abs(target - value) * 30)
        super.init()
        startDisplayLink()
    }

    deinit {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
        fallbackTimer?.cancel()
    }

    /// Retarget without losing velocity.
    func settle(to newTarget: CGFloat) {
        target = newTarget
    }

    func invalidate() {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
        displayLink = nil
        fallbackTimer?.cancel()
        fallbackTimer = nil
    }

    private func startDisplayLink() {
        // CVDisplayLink cannot allocate in every launchd context; degrade to a
        // high-frequency main timer rather than losing the spring.
        var link: CVDisplayLink?
        var created = CVDisplayLinkCreateWithActiveCGDisplays(&link)
        if created != kCVReturnSuccess {
            created = CVDisplayLinkCreateWithCGDisplay(CGMainDisplayID(), &link)
        }
        if created == kCVReturnSuccess, let link {
            let context = Unmanaged.passRetained(self).toOpaque()
            CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, userData in
                guard let userData else { return kCVReturnSuccess }
                let spring = Unmanaged<PanelSpring>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    spring.refresh(CACurrentMediaTime())
                }
                return kCVReturnSuccess
            }, context)
            let started = CVDisplayLinkStart(link)
            guard started == kCVReturnSuccess else {
                CVDisplayLinkStop(link)
                startFallbackTimer()
                return
            }
            displayLink = link
            return
        }
        startFallbackTimer()
    }

    private func startFallbackTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 120.0)
        timer.setEventHandler { [weak self] in
            self?.refresh(CACurrentMediaTime())
        }
        timer.resume()
        fallbackTimer = timer
    }

    /// Integrate one step on the main thread. `now` comes from the display
    /// link; CACurrentMediaTime shares its epoch (mach_absolute_time based).
    private func refresh(_ now: CFTimeInterval) {
        guard displayLink != nil || fallbackTimer != nil else { return }
        var dt = last == 0 ? 1 / 120 : now - last
        last = now
        dt = min(max(dt, 0), 1 / 30)
        let acceleration = -config.stiffness * (value - target) - config.damping * velocity
        velocity += acceleration * CGFloat(dt)
        value += velocity * CGFloat(dt)
        // Snap when both the error and the speed are below visual perception,
        // relative to how far this spring travels.
        if abs(value - target) < snapDistance, abs(velocity) < snapSpeed {
            value = target
            velocity = 0
            tick(value)
            invalidate()
            settle?()
            return
        }
        tick(value)
    }
}
