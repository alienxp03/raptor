import SwiftUI

/// Shared list popover for the worktree form's agent, model, and reasoning
/// fields. Same keyboard contract as TargetPickerPopover: arrows move, Return
/// selects, Escape dismisses.
@MainActor
struct AgentOptionPopover: View {
    struct Option: Identifiable {
        let id: String
        let label: String
        var detail: String? = nil

        init(id: String, label: String? = nil, detail: String? = nil) {
            self.id = id
            self.label = label ?? id
            self.detail = detail
        }
    }

    let options: [Option]
    let current: String
    var emptyMessage = ""
    var choose: @MainActor (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: String
    @FocusState private var keyboardFocused: Bool

    init(options: [Option], current: String, emptyMessage: String = "", choose: @escaping @MainActor (String) -> Void) {
        self.options = options
        self.current = current
        self.emptyMessage = emptyMessage
        self.choose = choose
        _selected = State(initialValue: options.contains(where: { $0.id == current }) ? current : (options.first?.id ?? ""))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if options.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(PickerStyle.secondaryText)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(options) { option in row(option).id(option.id) }
                        }
                    }
                    .frame(height: min(options.reduce(CGFloat.zero) {
                        $0 + PickerStyle.rowHeight + ($1.detail == nil ? 0 : 10)
                    }, 300))
                    .onChange(of: selected, initial: true) { _, id in proxy.scrollTo(id) }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: 380)
        .pickerGlass()
        .focusable()
        .focused($keyboardFocused)
        .focusEffectDisabled()
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            keyboardFocused = true
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .return, .escape], phases: [.down, .repeat], action: handleKey)
        .accessibilityIdentifier("agent-option-picker")
    }

    private func row(_ option: Option) -> some View {
        let isSelected = selected == option.id
        let isCurrent = option.id == current
        return Button { accept(option.id) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .lineLimit(1).truncationMode(.middle)
                        .help(option.label)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? PickerStyle.selectionText : PickerStyle.foreground)
                    if let detail = option.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle((isSelected ? PickerStyle.selectionText : PickerStyle.foreground).opacity(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle((isSelected ? PickerStyle.selectionText : PickerStyle.foreground).opacity(0.6))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: option.detail == nil ? PickerStyle.rowHeight : PickerStyle.rowHeight + 10)
            .background {
                Rectangle().fill(isSelected ? PickerStyle.selection.opacity(0.9) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { selected = option.id }
        }
    }

    private func move(_ delta: Int) {
        guard !options.isEmpty else { return }
        let index = options.firstIndex(where: { $0.id == selected }) ?? 0
        selected = options[(index + delta + options.count) % options.count].id
    }

    private func handleKey(_ key: KeyPress) -> KeyPress.Result {
        switch key.key {
        case .upArrow: move(-1); return .handled
        case .downArrow: move(1); return .handled
        case .return: accept(selected); return .handled
        case .escape: dismiss(); return .handled
        default: return .ignored
        }
    }

    private func accept(_ id: String) {
        choose(id)
        dismiss()
    }
}
