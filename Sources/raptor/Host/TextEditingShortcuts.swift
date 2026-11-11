import AppKit

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
