import AppKit
import SwiftUI

// SwiftUI's plain TextField inherits the row's dark text color but AppKit's
// dark text-selection highlight. Own both selection colors for this field.
struct InlineSessionNameField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NameField {
        let field = NameField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: PickerStyle.rowFontSize, weight: .medium)
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Session name")
        field.setAccessibilityIdentifier("session-name")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NameField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.textColor = NSColor(PickerStyle.selectionText)
        if let editor = field.currentEditor() as? NSTextView { context.coordinator.configureEditor(editor) }
    }

    static func dismantleNSView(_ field: NameField, coordinator: Coordinator) {
        coordinator.restoreEditor()
    }

    static func applyColors(to editor: NSTextView) {
        editor.textColor = NSColor(PickerStyle.selectionText)
        editor.insertionPointColor = NSColor(PickerStyle.selectionText)
        editor.selectedTextAttributes = [
            .foregroundColor: NSColor(PickerStyle.foreground),
            .backgroundColor: NSColor(PickerStyle.background),
        ]
    }

    final class NameField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
                self.selectText(nil)
                if let editor = self.currentEditor() as? NSTextView {
                    (self.delegate as? Coordinator)?.configureEditor(editor)
                }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineSessionNameField
        private var originalSelection: [NSAttributedString.Key: Any]?
        private var originalCaret: NSColor?
        private weak var editor: NSTextView?

        init(_ parent: InlineSessionNameField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView else { return }
            configureEditor(editor)
        }

        func configureEditor(_ editor: NSTextView) {
            if self.editor !== editor {
                restoreEditor()
                self.editor = editor
                originalSelection = editor.selectedTextAttributes
                originalCaret = editor.insertionPointColor
            }
            InlineSessionNameField.applyColors(to: editor)
        }

        func restoreEditor() {
            if let originalSelection { editor?.selectedTextAttributes = originalSelection }
            if let originalCaret { editor?.insertionPointColor = originalCaret }
            editor = nil
            originalSelection = nil
            originalCaret = nil
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            restoreEditor()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
            default: return false
            }
        }
    }
}

// The accessory panel can be key while Rex remains the active application.
// With no Edit menu, AppKit does not route these shortcuts to the field editor.
@MainActor
enum TextEditingShortcuts {
    static func perform(_ event: NSEvent, responder: NSResponder?) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags == .command, let editor = responder as? NSTextView,
              editor.isEditable else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v": editor.paste(nil)
        case "c": editor.copy(nil)
        case "x": editor.cut(nil)
        case "a": editor.selectAll(nil)
        default: return false
        }
        return true
    }
}
