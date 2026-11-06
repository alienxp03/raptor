import AppKit
import SwiftUI
import Combine
import CoreGraphics

@MainActor
final class RaptorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class RaptorDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: RaptorPanel?
    private var model: PickerModel?
    private var keyboardMonitor: Any?
    private var sizeSubscription: AnyCancellable?
    private var themeTimer: Timer?
    private var reopenTask: DispatchWorkItem?
    private var ready = false
    private var pendingOptions: LaunchOptions?
    // Resident mode ("Raptor serve", launched by launchd): the panel and the
    // Go backend stay alive across opens, so opening never spawns a process
    // and never activates the app.
    private var resident = false
    private var panelHost: PanelHost?

    func applicationDidFinishLaunching(_ notification: Notification) {
        var arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "serve" {
            arguments.removeFirst()
            resident = true
        }
        installKeyboardMonitor()
        ready = true
        if resident {
            startResident()
        } else if arguments.count > 0 {
            pendingOptions = nil
            do { present(try LaunchOptions(arguments: arguments)) }
            catch { report(error) }
        } else if let pendingOptions {
            self.pendingOptions = nil
            present(pendingOptions)
        }
        // URL launches arrive through application(_:open:). Do not first show a
        // picker with empty or stale context while waiting for that Apple event.
    }

    private func startResident() {
        // Pre-create the panel and model so the first ⌘S only has to show a
        // window; the backend child starts with the model.
        guard let options = try? LaunchOptions(arguments: []) else {
            fatalError("LaunchOptions must accept empty arguments")
        }
        let backend: any BackendClient = ProcessBackend(options: options)
        let next = PickerModel(options: options, backend: backend)
        model = next
        bindDismissal(next)
        _ = makePanel(for: next)
        sizeSubscription = next.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizePanel() }
        }
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
            // Replacing the model here would silently lose a committed worktree.
            current.error = "Worktree created, but the backend closed. Open the Destination manually, or discard recovery before opening another picker."
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
        startThemeRefresh()
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
        stopThemeRefresh()
        panel?.orderOut(nil)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        reopenTask?.cancel()
        guard urls.count == 1, let url = urls.first else { return }
        do { request(try LaunchOptions(pickerURL: url)) }
        catch { report(error) }
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if let panel, model != nil { bringForward(panel); return true }
        do { request(try LaunchOptions(arguments: [])) }
        catch { report(error) }
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A URL launch can also deliver a reopen event. Give its fresh Rex
        // context priority over Finder's ordinary untitled-window behavior.
        reopenTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let panel = self.panel, self.model != nil {
                self.bringForward(panel)
            } else {
                do { self.request(try LaunchOptions(arguments: [])) }
                catch { self.report(error) }
            }
        }
        reopenTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: task)
        return false
    }

    private func request(_ options: LaunchOptions) {
        if !ready { pendingOptions = options; return }
        if resident { openResident(options); return }
        present(options)
    }

    private func present(_ options: LaunchOptions) {
        // Never replace context beneath a Git mutation or removal confirmation.
        if let current = model, current.busy || current.removalCandidate != nil {
            current.error = "Finish the current operation before opening another picker."
            if let panel { bringForward(panel) }
            return
        }
        let anchor = invocationAnchor()
        sizeSubscription?.cancel()
        model?.onClose = nil
        model?.close()
        let backend: any BackendClient = options.demo ? DemoBackend() : ProcessBackend(options: options)
        let next = PickerModel(options: options, backend: backend)
        model = next
        bindDismissal(next)
        let picker: RaptorPanel
        if let panel {
            picker = panel
            if let host = panelPickerHost {
                host.rootView = PickerView(model: next)
            }
        } else {
            picker = makePanel(for: next)
        }
        picker.title = next.heading
        if let (area, screen) = anchor {
            picker.setFrame(PickerStyle.panelFrame(in: area, height: PickerStyle.height(for: next)).clamped(to: screen.visibleFrame), display: false)
        } else { picker.center() }
        sizeSubscription = next.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizePanel() }
        }
        bringForward(picker)
        next.start()
    }

    private func makePanel(for next: PickerModel) -> RaptorPanel {
        let picker = RaptorPanel(contentRect: NSRect(x: 0, y: 0, width: PickerStyle.width, height: PickerStyle.height(for: next)),
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
        startThemeRefresh()
    }

    private func bindDismissal(_ next: PickerModel) {
        let dismiss: () -> Void = { [weak self, weak next] in
            guard let self, let next, self.model === next else { return }
            self.dismissPicker()
        }
        next.onClose = dismiss
        next.onDismiss = dismiss
    }

    private func dismissPicker() {
        if resident || model?.busy == true {
            // Keep resident state warm. In either mode, hiding pending work
            // must not close its backend or cancel its task.
            dismissResidentPanel()
            return
        }
        stopThemeRefresh()
        sizeSubscription?.cancel()
        model?.onClose = nil
        model?.close()
        model = nil
        panel?.orderOut(nil)
        // Retain AppKit/SwiftUI and the panel, but stop the Go child. Never reuse
        // its Rex context: the next invocation creates a fresh model and backend.
        NSApp.hide(nil)
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
        model?.onClose = nil
        model?.close()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        reopenTask?.cancel()
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
            if resident {
                // A resident host must survive ⌘Q; hide the picker instead.
                model?.dismiss()
            } else if model?.busy == true {
                model?.dismiss()
            } else {
                NSApp.terminate(nil)
            }
            return true
        }
        guard let panel, let model else { return false }
        if model.removalCandidate != nil {
            // The sheet owns its keys. Explicitly cancel Escape without letting
            // it navigate the picker beneath the confirmation.
            if event.keyCode == 53 { model.removalCandidate = nil; return true }
            return false
        }
        // SwiftUI popover events can still name the parent panel. Let the
        // branch picker own Escape, Return, Tab, and all editing shortcuts.
        if model.basePickerPresented || model.targetPickerPresented { return false }
        // Synthesized events can arrive without a window tag; when our panel
        // is key with no sheet or modal, its shortcuts own the keyboard.
        guard panel.isKeyWindow, panel.attachedSheet == nil, NSApp.modalWindow == nil,
              event.window == nil || event.window === panel else { return false }
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
        if command && shift && !option && !control && key == "a" {
            model.selectView(.agents)
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
        // Tab switches views everywhere except the create form, which keeps
        // its field-focus behavior.
        if event.keyCode == 48 && !command && !option && !control && model.page != .create && !model.basePickerPresented && !model.targetPickerPresented {
            model.switchView(backward: shift)
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
        if model.page == .create && !option && !command && !control && event.keyCode == 48 {
            model.advanceFormFocus(backward: flags.contains(.shift)); return true
        }
        if model.page == .create && command && !option && !control && (event.keyCode == 36 || event.keyCode == 76) {
            if model.canSubmitForm { model.create() }
            return true
        }
        if model.view == .repos && (command || control) && !option && key == "n" && (model.page == .worktrees || model.page == .directories) {
            model.beginCreate(); return true
        }
        if model.view == .repos && model.page == .worktrees && ((command && event.keyCode == 51) || (control && key == "x")) {
            model.askRemove(); return true
        }
        if control && !command && !option {
            switch key {
            case "o": model.cycleTarget(backward: flags.contains(.shift)); return true
            case "p": model.toggleSplit(); return true
            case "t": model.showWorktrees(); return true
            case "j" where model.page != .create: model.move(1); return true
            case "k" where model.page != .create: model.move(-1); return true
            default: break
            }
        }
        if model.page != .create && !command && !option && !control {
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

@main
struct RaptorApplication {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        // Seed the palette from the system appearance; the first backend
        // connection replaces it with the active Rex theme.
        PickerPalette.useFallback(dark: application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        let delegate = RaptorDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
