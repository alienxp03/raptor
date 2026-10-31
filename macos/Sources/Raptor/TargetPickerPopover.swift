import SwiftUI

@MainActor
struct TargetPickerPopover: View {
    let targets: [String]
    let current: String
    let choose: @MainActor (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: String

    init(targets: [String], current: String, choose: @escaping @MainActor (String) -> Void) {
        self.targets = targets
        self.current = current
        self.choose = choose
        _selected = State(initialValue: targets.contains(current) ? current : (targets.first ?? ""))
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(targets, id: \.self) { target in
                row(target).id(target)
            }
        }
        .padding(.vertical, 4)
        .frame(width: 170)
        .pickerGlass()
        .onKeyPress(keys: [.upArrow, .downArrow, .return, .escape], phases: [.down, .repeat], action: handleKey)
        .accessibilityIdentifier("target-picker")
    }

    private func row(_ target: String) -> some View {
        let isSelected = selected == target
        let isCurrent = target == current
        return Button { accept(target) } label: {
            HStack(spacing: 8) {
                Text(PickerModel.targetLabel(target))
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? PickerStyle.selectionText : Color.primary)
                Spacer(minLength: 8)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isSelected ? PickerStyle.selectionText : Color.primary.opacity(0.6))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 30)
            .background {
                if isSelected { RoundedRectangle(cornerRadius: 8).fill(PickerStyle.selection) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(target)
        .accessibilityLabel(PickerModel.targetLabel(target))
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityIdentifier("target-option:\(target)")
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .upArrow: move(-1)
        case .downArrow: move(1)
        case .return:
            if press.phase == .down, targets.contains(selected) { accept(selected) }
        case .escape:
            if press.phase == .down { dismiss() }
        default: return .ignored
        }
        return .handled
    }

    private func move(_ delta: Int) {
        guard !targets.isEmpty else { return }
        let index = targets.firstIndex(of: selected) ?? (delta < 0 ? targets.count : -1)
        selected = targets[min(max(index + delta, 0), targets.count - 1)]
    }

    private func accept(_ target: String) {
        guard targets.contains(target) else { return }
        selected = target
        choose(target)
    }
}
