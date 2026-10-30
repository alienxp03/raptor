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
    private var reopenTask: DispatchWorkItem?
    private var ready = false
    private var pendingOptions: LaunchOptions?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installKeyboardMonitor()
        ready = true
        if CommandLine.arguments.count > 1 {
            pendingOptions = nil
            do { present(try LaunchOptions(arguments: Array(CommandLine.arguments.dropFirst()))) }
            catch { report(error) }
        } else if let pendingOptions {
            self.pendingOptions = nil
            present(pendingOptions)
        }
        // URL launches arrive through application(_:open:). Do not first show a
        // picker with empty or stale context while waiting for that Apple event.
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
        next.onClose = { [weak self, weak next] in
            guard let self, let next, self.model === next else { return }
            self.dismissPicker()
        }
        let picker: RaptorPanel
        if let panel {
            picker = panel
            (panel.contentView as? NSHostingView<PickerView>)?.rootView = PickerView(model: next)
        } else {
            picker = RaptorPanel(contentRect: NSRect(x: 0, y: 0, width: PickerStyle.width, height: PickerStyle.height(for: next)),
                                 styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
            panel = picker
            picker.identifier = NSUserInterfaceItemIdentifier("raptor-panel")
            picker.delegate = self
            picker.isReleasedWhenClosed = false
            picker.isOpaque = false
            picker.backgroundColor = .clear
            picker.hasShadow = true
            picker.animationBehavior = .none
            picker.level = .floating
            picker.hidesOnDeactivate = false
            picker.isFloatingPanel = true
            picker.becomesKeyOnlyIfNeeded = false
            picker.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            picker.contentView = NSHostingView(rootView: PickerView(model: next))
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
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        picker.makeKeyAndOrderFront(nil)
    }

    private func dismissPicker() {
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
        let height = PickerStyle.height(for: model)
        guard abs(panel.frame.height - height) > 0.5 else { return }
        let frame = NSRect(x: panel.frame.minX, y: panel.frame.maxY - height,
                           width: PickerStyle.width, height: height)
        panel.setFrame(frame, display: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model?.busy != true else { return false }
        model?.close()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.onClose = nil
        model?.close()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        reopenTask?.cancel()
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
            NSApp.terminate(nil)
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
        if model.basePickerPresented { return false }
        guard event.window === panel, panel.isKeyWindow,
              panel.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let control = flags.contains(.control)
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        guard !model.busy else {
            // Keep the panel visible until a mutation finishes; do not accept repeated commands.
            return event.keyCode == 53 || event.keyCode == 36 || event.keyCode == 48 || control
        }
        if event.keyCode == 53 { model.escape(); return true }
        if model.splitMode {
            if control || command || option {
                if control && !command && !option && key == "p" { model.toggleSplit() }
                return true
            }
            switch event.keyCode {
            case 123: model.split("pane_left")
            case 124: model.split("pane")
            case 125: model.split("pane_below")
            case 126: model.split("pane_above")
            default:
                switch key {
                case "h": model.split("pane_left")
                case "j": model.split("pane_below")
                case "k": model.split("pane_above")
                case "l": model.split("pane")
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
        if (command || control) && !option && key == "n" && (model.page == .worktrees || model.page == .directories) {
            model.beginCreate(); return true
        }
        if model.page == .worktrees && ((command && event.keyCode == 51) || (control && key == "x")) {
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
        let delegate = RaptorDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
