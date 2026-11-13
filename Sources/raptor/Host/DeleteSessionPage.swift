import SwiftUI

struct DeleteSessionPage: View {
    @ObservedObject var model: PickerModel
    let deletion: PickerModel.SessionDeletion
    @FocusState private var keyboardFocus: PickerModel.DeletionFocus?

    private var forceConfirmation: Bool { deletion.phase == .forceConfirm }
    private var reviewing: Bool {
        !model.busy && (deletion.automaticallyVerifies || deletion.preparationSelection == nil)
            && [.loading, .review, .preparing, .confirm].contains(deletion.phase)
    }
    private var hasDeletableWorktrees: Bool {
        PickerStyle.hasDeletionSelection(deletion)
    }
    private var title: String {
        if forceConfirmation { return "Force delete worktrees?" }
        return "Delete worktrees"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.escape() } label: {
                    Label(title, systemImage: "arrow.left")
                        .font(.system(size: PickerStyle.titleFontSize, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("delete-session-back")
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: PickerStyle.searchHeight)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Label(deletion.candidate.label ?? deletion.candidate.path, systemImage: "terminal")
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1).truncationMode(.middle)
                                .help(deletion.candidate.label ?? deletion.candidate.path)
                            Text("· " + (deletion.candidate.host ?? "This Mac"))
                                .foregroundStyle(PickerStyle.secondaryText)
                                .fixedSize()
                            Spacer(minLength: 4)
                            if deletion.phase == .preparing || deletion.phase == .confirm, let rows = deletion.plan?.worktrees {
                                let selected = deletion.preparationSelection ?? deletion.selectedPaths
                                Text("\(rows.filter { selected.contains($0.path) && $0.isPrepared }.count)/\(selected.count) verified")
                                    .foregroundStyle(PickerStyle.secondaryText)
                                    .accessibilityIdentifier("worktree-prepare-count")
                            } else if deletion.phase == .loading, let rows = deletion.plan?.worktrees {
                                Text("\(rows.filter(\.isChecked).count)/\(rows.count) identified")
                                    .foregroundStyle(PickerStyle.secondaryText)
                                    .accessibilityIdentifier("worktree-check-count")
                            }
                        }
                        .font(.system(size: 11))
                        .frame(height: 20)

                        if let worktrees = deletion.plan?.worktrees {
                            if !worktrees.isEmpty {
                                VStack(spacing: 0) {
                                    ForEach(worktrees) { worktree in
                                        worktreeRow(worktree).id(PickerModel.DeletionFocus.worktree(worktree.path))
                                        if worktree.id != worktrees.last?.id {
                                            Divider().overlay(PickerPalette.stroke)
                                        }
                                    }
                                }
                            }

                            if deletion.forceWarningCount > 0 {
                                Label(forceWarningSummary, systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(warningColor)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 8).padding(.vertical, 7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(warningColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                                    .accessibilityIdentifier("deletion-force-warning")
                            }

                            if hasDeletableWorktrees {
                                Toggle("Close session, including unselected tabs/panes", isOn: Binding(
                                    get: { deletion.closeSessionConfirmed },
                                    set: {
                                        model.focusDeletionControl(.closeSession)
                                        model.confirmDeletionSessionClose($0)
                                    }
                                ))
                                .toggleStyle(DeletionCheckboxStyle())
                                .padding(.horizontal, 5).padding(.vertical, 4)
                                .background(focusBackground(.closeSession), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(focusBorder(.closeSession))
                                .focusable()
                                .focused($keyboardFocus, equals: .closeSession)
                                .focusEffectDisabled()
                                .id(PickerModel.DeletionFocus.closeSession)
                                .disabled(model.busy || deletion.phase != .confirm)
                                .help(deletion.phase == .confirm
                                      ? "Closes every tab and pane, including those for unselected worktrees."
                                      : "Checks run automatically. Wait for the results before giving close-session consent.")
                                .accessibilityIdentifier("confirm-close-deletion-session")
                            }

                            Text(explanation)
                                .font(.system(size: 11))
                                .foregroundStyle(PickerStyle.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if forceConfirmation {
                            Text("Discards uncommitted files and unmerged commits. Cannot be undone.")
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let error = deletion.error {
                            Text(PickerStyle.deletionErrorSummary(error))
                                .font(.system(size: 11))
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .help(error)
                                .accessibilityLabel(error)
                                .accessibilityIdentifier("delete-session-error")
                        }
                        if deletion.plan == nil && deletion.phase == .loading || deletion.phase == .deleting {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                if deletion.phase == .deleting {
                                    TimelineView(.periodic(from: .now, by: 1)) { context in
                                        let seconds = max(0, Int(context.date.timeIntervalSince(deletion.checkStartedAt ?? context.date)))
                                        Text("Revalidating and deleting… \(seconds)s")
                                    }
                                } else {
                                    Text("Reading pane directories…")
                                }
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(PickerStyle.secondaryText)
                            .accessibilityIdentifier("delete-session-progress")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                }
                .onChange(of: model.deletionKeyboardFocus, initial: true) { _, focus in
                    guard let focus else { return }
                    switch focus {
                    case .worktree(let path), .retry(let path):
                        proxy.scrollTo(PickerModel.DeletionFocus.worktree(path), anchor: .center)
                    case .closeSession:
                        proxy.scrollTo(focus)
                    case .action, .cancel: break
                    }
                }
            }
            Divider().overlay(PickerPalette.stroke)
            HStack(spacing: 10) {
                Text(keyboardHint)
                    .font(.system(size: 10))
                    .foregroundStyle(PickerStyle.secondaryText)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityIdentifier("deletion-keyboard-hint")
                Spacer(minLength: 4)
                Button(model.busy ? "Hide" : "Cancel") {
                    model.focusDeletionControl(.cancel)
                    model.escape()
                }
                    .padding(.horizontal, 8).frame(height: 28)
                    .overlay(focusBorder(.cancel))
                    .focusable().focused($keyboardFocus, equals: .cancel).focusEffectDisabled()
                    .accessibilityIdentifier("cancel-delete-session")
                if deletion.phase == .forceOffered {
                    Button("Force delete…") {
                        model.focusDeletionControl(.action)
                        model.offerForceDeleteSession()
                    }
                        .padding(.horizontal, 8).frame(height: 28)
                        .foregroundStyle(destructiveColor)
                        .overlay(focusBorder(.action, destructive: true))
                        .focusable().focused($keyboardFocus, equals: .action).focusEffectDisabled()
                        .accessibilityIdentifier("offer-force-delete-session")
                        .help("Cmd+Shift+X. Requires a separate confirmation.")
                } else if deletion.phase == .failed {
                    Button("Refresh review") {
                        model.focusDeletionControl(.action)
                        model.refreshDeletionReview()
                    }
                        .padding(.horizontal, 8).frame(height: 28)
                        .overlay(focusBorder(.action))
                        .focusable().focused($keyboardFocus, equals: .action).focusEffectDisabled()
                        .accessibilityIdentifier("refresh-worktree-review")
                } else if hasDeletableWorktrees {
                    Button {
                        model.focusDeletionControl(.action)
                        model.confirmDeleteSession()
                    } label: {
                        HStack(spacing: 8) {
                            Text(forceConfirmation ? "Force delete selected" : "Delete selected").fontWeight(.medium)
                            Text("⌘↵").font(.system(size: 10)).opacity(0.7)
                        }
                            .foregroundStyle(actionColor)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(model.canConfirmSessionDeletion ? destructiveColor.opacity(0.12) : PickerStyle.foreground.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .overlay(focusBorder(.action, destructive: true))
                    .focusable().focused($keyboardFocus, equals: .action).focusEffectDisabled()
                    .help("Cmd+Enter confirms deletion after explicit close-session consent.")
                    .disabled(!model.canConfirmSessionDeletion)
                    .accessibilityIdentifier("confirm-delete-session")
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .frame(height: 38)
        }
        .font(.system(size: PickerStyle.bodyFontSize))
        .foregroundStyle(PickerStyle.foreground)
        .accessibilityIdentifier("delete-session-page")
        .onChange(of: model.deletionKeyboardFocus, initial: true) { _, focus in keyboardFocus = focus }
    }

    private var keyboardHint: String {
        if model.busy { return "Esc hide" }
        if [.loading, .review, .preparing].contains(deletion.phase) { return "Space select · Checking automatically…" }
        if forceConfirmation { return "⌘↵ confirm Force · Esc cancel" }
        if deletion.phase == .forceOffered || deletion.phase == .failed {
            return "Tab move · ↵ activate · Esc cancel"
        }
        return "Tab move · Space consent · ⌘↵ delete"
    }

    private func focusBorder(_ focus: PickerModel.DeletionFocus, destructive: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(model.deletionKeyboardFocus == focus
                ? (destructive ? destructiveColor : PickerStyle.selection) : Color.clear, lineWidth: 1)
    }

    private func focusBackground(_ focus: PickerModel.DeletionFocus) -> Color {
        model.deletionKeyboardFocus == focus ? PickerStyle.selectionBackground : .clear
    }

    private var explanation: String {
        if deletion.phase == .loading || deletion.phase == .review {
            return "Checks run automatically. Select the worktrees you want to delete."
        }
        if deletion.phase == .preparing {
            return "Checking worktrees automatically. Nothing is being deleted."
        }
        if !hasDeletableWorktrees { return "No deletable worktrees in this session." }
        return "Review results, check Close session, then Delete selected. Other worktrees and remote branches stay."
    }

    private var forceWarningSummary: String {
        let count = deletion.forceWarningCount
        return "\(count) selected worktree\(count == 1 ? " requires" : "s require") Force. Review warnings before deleting."
    }

    private var warningColor: Color {
        PickerPalette.isDark ? Color(red: 0.96, green: 0.73, blue: 0.35) : Color(red: 0.54, green: 0.32, blue: 0.02)
    }

    private var destructiveColor: Color {
        PickerPalette.isDark ? Color(red: 1, green: 0.42, blue: 0.38) : Color(red: 0.72, green: 0.1, blue: 0.08)
    }

    private var actionColor: Color {
        model.canConfirmSessionDeletion ? destructiveColor : PickerStyle.secondaryText
    }

    private func worktreeRow(_ worktree: DeletionWorktree) -> some View {
        let removed = deletion.deletedPaths.contains(worktree.path)
        return HStack(alignment: .top, spacing: 8) {
            if deletion.isChecking(worktree.path), !deletion.automaticallyVerifies {
                ProgressView().controlSize(.small).tint(PickerStyle.foreground).frame(width: 16)
                    .accessibilityLabel("Checking \(worktree.path)")
            } else if !removed && (worktree.deletable
                                    || (deletion.automaticallyVerifies && deletion.selectedPaths.contains(worktree.path))) {
                Toggle(worktree.branch, isOn: Binding(
                    get: { deletion.selectedPaths.contains(worktree.path) },
                    set: { model.selectDeletionWorktree(worktree.path, selected: $0) }
                ))
                .toggleStyle(DeletionCheckboxStyle(showsLabel: false))
                .focusable()
                .focused($keyboardFocus, equals: .worktree(worktree.path))
                .focusEffectDisabled()
                .disabled(!reviewing)
                .accessibilityLabel("Delete branch \(worktree.branch) at \(worktree.path)")
                .accessibilityIdentifier("delete-worktree:\(worktree.path)")
            } else {
                Image(systemName: removed ? "checkmark.circle" : (worktree.isChecked ? "lock" : "folder"))
                    .foregroundStyle(PickerStyle.secondaryText)
                    .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(worktree.branch.isEmpty ? (worktree.path.isEmpty ? "Unknown directory" : displayPath(worktree.path)) : worktree.branch)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                    .help(worktree.path)
                if !worktree.branch.isEmpty {
                    Text(displayPath(worktree.path))
                        .font(.system(size: 11))
                        .foregroundStyle(PickerStyle.secondaryText)
                        .textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                        .help(worktree.path)
                }
                worktreeStatus(worktree, removed: removed)
                    .font(.system(size: 11))
                    .foregroundStyle(PickerStyle.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if deletion.checkingPath == nil,
               (reviewing && (worktree.retryable || !worktree.isChecked)) ||
                (deletion.phase == .preparing && deletion.preparationSelection?.contains(worktree.path) == true && !worktree.isPrepared) {
                Button(worktree.error == nil ? (deletion.phase == .preparing ? "Verify" : "Check") : "Retry") {
                    model.focusDeletionControl(.retry(worktree.path))
                    model.retryDeletionWorktree(worktree.path)
                }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .overlay(focusBorder(.retry(worktree.path)))
                    .focusable()
                    .focused($keyboardFocus, equals: .retry(worktree.path))
                    .focusEffectDisabled()
                    .accessibilityIdentifier("retry-worktree:\(worktree.path)")
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 7)
        .background(focusBackground(.worktree(worktree.path)), in: RoundedRectangle(cornerRadius: 6))
        .overlay(focusBorder(.worktree(worktree.path)))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            model.focusDeletionControl(.worktree(worktree.path))
        })
    }

    @ViewBuilder private func worktreeStatus(_ worktree: DeletionWorktree, removed: Bool) -> some View {
        if removed {
            Text("Removed")
        } else if deletion.isChecking(worktree.path) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(deletion.startedChecking(worktree.path) ?? context.date)))
                HStack(spacing: 6) {
                    if deletion.automaticallyVerifies { ProgressView().controlSize(.small) }
                    Text("\(deletion.phase == .preparing ? "Checking deletion safety" : "Identifying worktree")… \(seconds)s")
                }
            }
        } else if let error = worktree.error {
            Text(PickerStyle.deletionErrorSummary(error))
                .lineLimit(2)
                .help(error)
                .accessibilityLabel(error)
        } else if !worktree.isChecked {
            Text("Waiting to identify worktree…")
        } else if worktree.deletable, !deletion.selectedPaths.contains(worktree.path) {
            Text("Not selected")
        } else if let warning = worktree.forceWarning {
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(warningColor)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("worktree-force-warning:\(worktree.path)")
        } else if worktree.deletable {
            if worktree.isPrepared {
                Label("Verified", systemImage: "checkmark.circle")
                    .foregroundStyle(PickerStyle.selection)
            } else {
                Label(PickerStyle.deletionPendingStatus(deletion), systemImage: "clock")
                    .accessibilityIdentifier("worktree-check-queued:\(worktree.path)")
            }
        }
    }

    private func displayPath(_ path: String) -> String {
        PathDisplay.abbreviate(path, home: model.options.demo ? "/Users/demo" : NSHomeDirectory())
    }
}

/// Draw selection with the Rex palette, without AppKit's blue checkbox ring.
/// The containing row or consent control already shows keyboard focus.
@MainActor
private struct DeletionCheckboxStyle: ToggleStyle {
    var showsLabel = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(configuration.isOn ? PickerStyle.selectionBackground : PickerStyle.foreground.opacity(0.03))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(
                        configuration.isOn ? PickerStyle.selection : PickerStyle.foreground.opacity(0.35), lineWidth: 1))
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(PickerStyle.selectionText)
                        }
                    }
                    .frame(width: 16, height: 16)
                if showsLabel { configuration.label }
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.checkbox)
        }
    }
}
