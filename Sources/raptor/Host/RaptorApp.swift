import AppKit
import SwiftUI
import Combine
import CoreGraphics

@MainActor
final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if TextEditingShortcuts.perform(event, responder: firstResponder) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class RaptorDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: PickerPanel?
    private var model: PickerModel?
    private var keyboardMonitor: Any?
    private let outsideClickMonitor = OutsideClickMonitor()
    private var sizeSubscription: AnyCancellable?
    private var themeTimer: Timer?
    private var ready = false
    // The resident host: the panel and the backend child stay alive across
    // opens, so opening never spawns a process and never activates an app.
    // Spawned under Rex's process chain (plugin → panel → serve), so the fd
    // scan inherits Rex's file-access grants instead of facing TCC alone.
    private var panelHost: PanelHost?
    private var focusTracker: RexFocusTracker?
    private lazy var receiptMonitor = RexReceiptMonitor { [weak self] in
        self?.model?.readReceiptsChanged()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installKeyboardMonitor()
        let tracker = RexFocusTracker { [weak self] observation in
            guard let model = self?.model else { return false }
            return await model.observeRexFocus(observation)
        }
        focusTracker = tracker
        tracker.start()
        ready = true
        startResident()
    }

    private func startResident() {
        // Pre-create the panel and model so the first open only has to show a
        // window; the backend child starts with the model.
        guard let options = try? LaunchOptions(arguments: []) else {
            fatalError("LaunchOptions must accept empty arguments")
        }
        let backend: any BackendClient = ProcessBackend(options: options)
        let next = PickerModel(options: options, backend: backend,
                               pullRequestClipboard: { NSPasteboard.general.string(forType: .string) })
        model = next
        bindDismissal(next)
        _ = makePanel(for: next)
        sizeSubscription = next.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizePanel() }
        }
        // Must match RaptorPaths.panelSocket(): this file is also type-checked
        // standalone (scripts/test-macos.sh) without the package modules.
        let cacheBase = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/Library/Caches"
        let host = PanelHost(path: cacheBase + "/raptor/panel.sock") { [weak self] request in
            self?.handlePanelOpen(request) ?? PanelReply(ok: false, error: "host unavailable")
        }
        panelHost = host
        do { try host.start() } catch { report(error) }
        // Queue backend and global directory warmup now. All pipe I/O is off
        // the main actor; no delayed start can reset the first open.
        next.start()
    }

    private func handlePanelOpen(_ request: PanelRequest) -> PanelReply {
        let options: LaunchOptions
        do { options = try LaunchOptions(panelRequest: request) }
        catch { return PanelReply(ok: false, error: error.localizedDescription) }
        // Same context while visible hides without cancelling an operation.
        if let panel, panel.isVisible, let model, model.shouldToggle(for: options) {
            model.dismiss()
            return PanelReply(ok: true, error: nil)
        }
        openResident(options)
        return PanelReply(ok: true, error: nil)
    }

    private func openResident(_ options: LaunchOptions) {
        guard let current = model else { return }
        if current.backendIsClosed, current.createdPath != nil {
            // Rebind PR recovery in place, using its original context, never
            // this invocation's options. Keep path, target and error visible.
            if current.page == .pr {
                current.reconnectPullRequestBackend()
            } else {
                current.error = "Worktree created, but the backend closed. Open the Destination manually, or discard recovery before opening another picker."
            }
            showResidentPanel()
            return
        }
        if current.backendIsClosed {
            // A closed connection cannot finish more work. Recover before the
            // busy gate, but never replace a live pending mutation.
            attach(PickerModel(options: options, backend: ProcessBackend(options: options)))
        }
        guard let current = model else { return }
        guard !current.busy, current.removalCandidate == nil else {
            current.error = "Finish the current operation before opening another picker."
            showResidentPanel()
            return
        }
        guard let model else { return }
        let context = model.prepareReconfigure(options)
        let anchor = invocationAnchor()
        if let panel {
            panel.title = model.heading
            if let (area, screen) = anchor {
                panel.setFrame(PickerStyle.panelFrame(in: area, height: PickerStyle.height(for: model)).clamped(to: screen.visibleFrame), display: false)
            }
        }
        // Warm same-origin directories are already actionable here, including
        // targets and list position. Only a cold/changed origin needs completion.
        // Showing the panel alone is not the warm-reopen fast path.
        showResidentPanel()
        if !model.contextReady {
            Task { [weak model] in
                await model?.completeReconfigure(context)
            }
        }
    }

    /// Swap in a fresh model (crashed backend recovery), reusing the panel.
    private func attach(_ next: PickerModel) {
        sizeSubscription?.cancel()
        model?.onClose = nil
        model?.close()
        model = next
        bindDismissal(next)
        if let host = panelPickerHost {
            host.rootView = PickerView(model: next)
        }
        sizeSubscription = next.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizePanel() }
        }
    }

    private func showResidentPanel() {
        guard let panel else { return }
        panel.animationBehavior = PickerStyle.panelAnimationBehavior(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        NSApp.unhide(nil)
        // AppKit supplies resh's panel fade; no custom delay or alpha animation.
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        model?.setPresented(true)
        receiptMonitor.start()
        startOutsideClickDismissal(for: panel)
        startThemeRefresh()
    }

    private func startOutsideClickDismissal(for picker: NSPanel) {
        outsideClickMonitor.start(panel: picker) { [weak self] in
            self?.model?.dismissForOutsideClick()
        }
    }

    private func startThemeRefresh() {
        model?.refreshTheme()
        guard themeTimer == nil else { return }
        themeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.panel?.isVisible == true else { self.stopThemeRefresh(); return }
                self.model?.refreshTheme()
            }
        }
        themeTimer?.tolerance = 0.2
    }

    private func stopThemeRefresh() {
        themeTimer?.invalidate()
        themeTimer = nil
    }

    private func dismissResidentPanel() {
        receiptMonitor.stop()
        outsideClickMonitor.stop()
        model?.setPresented(false)
        stopThemeRefresh()
        panel?.orderOut(nil)
    }

    private func makePanel(for next: PickerModel) -> PickerPanel {
        let picker = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: PickerStyle.width, height: PickerStyle.height(for: next)),
                                 styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel = picker
        picker.identifier = NSUserInterfaceItemIdentifier("raptor-panel")
        picker.delegate = self
        picker.isReleasedWhenClosed = false
        picker.isOpaque = false
        picker.backgroundColor = .clear
        picker.hasShadow = true
        // Match resh's system panel animation, unless Reduced Motion is enabled.
        picker.animationBehavior = PickerStyle.panelAnimationBehavior(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        picker.level = .floating
        picker.hidesOnDeactivate = false
        picker.isFloatingPanel = true
        picker.becomesKeyOnlyIfNeeded = false
        picker.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        picker.contentView = makeContent(for: next)
        return picker
    }

    /// resh-style liquid glass: NSGlassEffectView hosts the picker content on
    /// macOS 26+, with an NSVisualEffectView fallback and a solid surface when
    /// transparency is reduced. The material owns rounding and the hairline
    /// border; the SwiftUI content stays transparent so the glass shows.
    private func makeContent(for model: PickerModel) -> NSView {
        let size = CGSize(width: PickerStyle.width, height: PickerStyle.height(for: model))
        let hosting = NSHostingView(rootView: PickerView(model: model))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        let material: NSView
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let solid = NSView(frame: NSRect(origin: .zero, size: size))
            solid.wantsLayer = true
            solid.layer?.backgroundColor = PickerStyle.background.cgColor
            solid.addSubview(hosting)
            material = solid
        } else if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
            glass.style = .regular
            glass.cornerRadius = PickerStyle.radius
            glass.tintColor = PickerStyle.glassTint
            glass.contentView = hosting
            material = glass
        } else {
            let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            hosting.autoresizingMask = [.width, .height]
            effect.addSubview(hosting)
            material = effect
        }
        material.wantsLayer = true
        material.layer?.cornerRadius = PickerStyle.radius
        material.layer?.masksToBounds = true
        material.layer?.borderWidth = 1
        PickerStyle.applyPanelTheme(to: material)
        return material
    }

    private var panelPickerHost: NSHostingView<PickerView>? {
        guard let content = panel?.contentView else { return nil }
        if #available(macOS 26.0, *), let glass = content as? NSGlassEffectView {
            return glass.contentView as? NSHostingView<PickerView>
        }
        if let effect = content as? NSVisualEffectView {
            return effect.subviews.first as? NSHostingView<PickerView>
        }
        return (content as? NSHostingView<PickerView>)
            ?? content.subviews.first as? NSHostingView<PickerView>
    }

    private func invocationAnchor() -> (area: CGRect, screen: NSScreen)? {
        // For a warm accessory app, NSScreen.main may still refer to its previous
        // invocation. Use the foreground app's window before activating Raptor,
        // and anchor the picker to that window rather than to the whole screen.
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            for window in windows {
                guard window[kCGWindowOwnerPID as String] as? Int32 == front.processIdentifier,
                      window[kCGWindowLayer as String] as? Int == 0,
                      let bounds = window[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
                // CGWindow bounds use a top-left origin; flip to Cocoa coordinates.
                let frame = CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
                if let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }) {
                    return (frame, screen)
                }
            }
        }
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return nil }
        return (screen.visibleFrame, screen)
    }

    private func bringForward(_ picker: NSPanel) {
        picker.animationBehavior = PickerStyle.panelAnimationBehavior(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        picker.makeKeyAndOrderFront(nil)
        model?.setPresented(true)
        receiptMonitor.start()
        startOutsideClickDismissal(for: picker)
        startThemeRefresh()
    }

    private func bindDismissal(_ next: PickerModel) {
        next.keepsBackendWarmOnNavigation = true
        // Resolve self.model at delivery, never retain an old context/model.
        focusTracker?.retryDelivery()
        let dismiss: () -> Void = { [weak self, weak next] in
            guard let self, let next, self.model === next else { return }
            self.dismissPicker()
        }
        next.onClose = dismiss
        next.onDismiss = dismiss
    }

    private func dismissPicker() {
        // Keep resident state warm, whether idle or busy. Hiding pending work
        // must not close its backend or cancel its task.
        dismissResidentPanel()
    }

    private func resizePanel() {
        guard let panel, let model else { return }
        panel.title = model.heading
        if let material = panel.contentView { PickerStyle.applyPanelTheme(to: material) }
        let height = PickerStyle.height(for: model)
        guard abs(panel.frame.height - height) > 0.5 else { return }
        // resh resizes with no motion: setFrame(animate: false), top edge pinned.
        let frame = NSRect(x: panel.frame.minX, y: panel.frame.maxY - height,
                           width: panel.frame.width, height: height)
        panel.setFrame(frame, display: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model?.dismiss()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        receiptMonitor.stop()
        focusTracker?.stop()
        model?.onClose = nil
        model?.close()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        receiptMonitor.stop()
        outsideClickMonitor.stop()
        focusTracker?.stop()
        stopThemeRefresh()
        sizeSubscription?.cancel()
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        model?.onClose = nil
        model?.close()
    }

    private func report(_ error: Error) {
        fputs("Raptor: \(error.localizedDescription)\n", stderr)
    }

    private func installKeyboardMonitor() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                self?.handle(event) ?? false
            }
            return handled ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "q" {
            // A resident host must survive ⌘Q; hide the picker instead.
            model?.dismiss()
            return true
        }
        guard let panel, let model else { return false }
        if let candidate = model.sessionCloseCandidate {
            if event.keyCode == 53 { model.escape(); return true }
            if event.keyCode == 36 || event.keyCode == 76 { model.confirmCloseSession(candidate); return true }
            return true
        }
        if model.sessionDeletion != nil {
            guard panel.isKeyWindow, panel.attachedSheet == nil, NSApp.modalWindow == nil,
                  event.window == nil || event.window === panel else { return false }
            return model.handleDeletionKeyboard(code: event.keyCode,
                characters: event.charactersIgnoringModifiers ?? "", modifiers: event.modifierFlags,
                isRepeat: event.isARepeat)
        }
        if model.removalCandidate != nil {
            // The sheet owns its keys. Explicitly cancel Escape without letting
            // it navigate the picker beneath the confirmation.
            if event.keyCode == 53 { model.removalCandidate = nil; return true }
            return false
        }
        // SwiftUI popover events can still name the parent panel. Let the
        // branch picker own Escape, Return, Tab, and all editing shortcuts.
        if model.basePickerPresented || model.targetPickerPresented || model.hasPopover { return false }
        // Synthesized events can arrive without a window tag; when our panel
        // is key with no sheet or modal, its shortcuts own the keyboard.
        guard panel.isKeyWindow, panel.attachedSheet == nil, NSApp.modalWindow == nil,
              event.window == nil || event.window === panel else { return false }
        let helpFlags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let helpKey = event.charactersIgnoringModifiers ?? ""
        let editingText = panel.firstResponder is NSTextView || panel.firstResponder is NSTextField
        if (helpFlags == [.command] && helpKey == "/") ||
            (!editingText && helpFlags.subtracting(.shift).isEmpty && event.characters == "?") {
            model.toggleShortcuts()
            return true
        }
        if model.shortcutsPresented {
            if event.keyCode == 53 { model.escape(); return true }
            if helpFlags.intersection([.command, .control, .option]).isEmpty {
                if event.keyCode == 125 { model.moveShortcut(1); return true }
                if event.keyCode == 126 { model.moveShortcut(-1); return true }
            }
            if helpFlags == [.control] {
                if helpKey.lowercased() == "j" { model.moveShortcut(1); return true }
                if helpKey.lowercased() == "k" { model.moveShortcut(-1); return true }
            }
            // Search keeps text-editing keys. No picker action runs behind help.
            return false
        }
        if model.renameCandidate != nil {
            // Inline editing owns keys; never jump, move rows, or change targets.
            switch event.keyCode {
            case 53: model.cancelRenameSession(); return true
            case 36, 76: model.confirmRenameSession(); return true
            case 48: return true
            default: return false
            }
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let control = flags.contains(.control)
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 53 { model.escape(); return true }
        guard !model.busy else {
            // Escape hides; other operation shortcuts cannot submit again.
            return event.keyCode == 36 || event.keyCode == 48 || control
        }
        if command && shift && !option && !control && key == "s" {
            model.selectView(.sessions)
            return true
        }
        // Numbered rows: ⌘1–9 opens that result directly with the chosen target.
        if command && !option && !control, let number = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(number) {
            model.openNumbered(number)
            return true
        }
        if command && shift && !option && !control && key == "p" {
            model.togglePin()
            return true
        }
        if command && shift && !option && !control && key == "c" {
            model.beginPullRequest()
            return true
        }
        if model.splitMode {
            if control || command || option {
                if control && !command && !option && key == "p" { model.toggleSplit() }
                return true
            }
            switch event.keyCode {
            case 124: model.split("pane_right")
            case 125: model.split("pane_below")
            default:
                switch key {
                case "j": model.split("pane_below")
                case "l": model.split("pane_right")
                default: break
                }
            }
            return true
        }
        if model.isForm && !option && !command && !control && event.keyCode == 48 {
            model.advanceFormFocus(backward: flags.contains(.shift)); return true
        }
        if model.page == .pr && command && !option && !control && (event.keyCode == 36 || event.keyCode == 76) {
            model.openPullRequest(); return true
        }
        if model.page == .create && command && !option && !control && (event.keyCode == 36 || event.keyCode == 76) {
            if model.canSubmitForm { model.create() }
            return true
        }
        if command && shift && !option && !control && key == "x" {
            model.beginDeleteSession()
            return true
        }
        if control && !command && !option && !shift && key == "x" {
            model.askCloseSession()
            return true
        }
        if control && !command && !option {
            switch key {
            case "r" where !shift: model.beginRenameSession(); return true
            case "o": model.cycleTarget(backward: flags.contains(.shift)); return true
            case "p": model.toggleSplit(); return true
            case "j" where !model.isForm: model.move(1); return true
            case "k" where !model.isForm: model.move(-1); return true
            default: break
            }
        }
        // Agent launch shortcuts cycle values without opening a popover.
        if model.page == .create, control && option && !command && !shift {
            switch key {
            case "o": model.cycleAgent(); return true
            case "m": model.cycleAgentModel(); return true
            case "r": model.cycleAgentReasoning(); return true
            default: break
            }
        }
        if !model.isForm && !command && !option && !control {
            switch event.keyCode {
            case 125: model.move(1); return true
            case 126: model.move(-1); return true
            case 36, 76: model.choose(); return true
            default: break
            }
        }
        return false
    }
}

/// Host entry for `raptor serve`: a bare, resident AppKit process that owns
/// the panel and the backend child. No bundle, no launchd job — the Rex
/// plugin reaches it over the panel socket and the process chain stays under
/// Rex, so file-access grants are inherited rather than re-prompted.
enum HostMain {
    @MainActor static func run() -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        // Seed the palette from the system appearance; the first backend
        // connection replaces it with the active Rex theme.
        PickerPalette.useFallback(dark: application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        let delegate = RaptorDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
        exit(0)
    }
}
