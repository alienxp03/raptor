import SwiftUI

struct DeleteSessionPage: View {
    @ObservedObject var model: PickerModel
    let deletion: PickerModel.SessionDeletion

    private var forceConfirmation: Bool { deletion.phase == .forceConfirm }
    private var reviewing: Bool {
        deletion.preparationSelection == nil && !model.busy
            && (deletion.phase == .confirm || deletion.phase == .loading || deletion.phase == .review)
    }
    private var hasDeletableWorktrees: Bool {
        PickerStyle.hasDeletionSelection(deletion)
    }
    private var title: String {
        if forceConfirmation { return "Force delete worktrees?" }
        if deletion.phase == .preparing { return "Verify worktrees" }
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
                        if deletion.phase == .preparing, let rows = deletion.plan?.worktrees, let selected = deletion.preparationSelection {
                            Text("\(rows.filter { selected.contains($0.path) && $0.isPrepared }.count)/\(selected.count) verified")
                                .foregroundStyle(PickerStyle.secondaryText)
                                .accessibilityIdentifier("worktree-prepare-count")
                        } else if deletion.phase == .loading, let rows = deletion.plan?.worktrees {
                            Text("\(rows.filter(\.isChecked).count)/\(rows.count) checked")
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
                                    worktreeRow(worktree)
                                    if worktree.id != worktrees.last?.id {
                                        Divider().overlay(PickerPalette.stroke)
                                    }
                                }
                            }
                        }

                        if hasDeletableWorktrees,
                           deletion.phase == .confirm || deletion.phase == .forceOffered || forceConfirmation || deletion.phase == .deleting {
                            Toggle("Close session, including unselected tabs/panes", isOn: Binding(
                                get: { deletion.closeSessionConfirmed },
                                set: { model.confirmDeletionSessionClose($0) }
                            ))
                            .toggleStyle(.checkbox)
                            .disabled(model.busy || deletion.phase != .confirm)
                            .help("Closes every tab and pane, including those for unselected worktrees.")
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
            Divider().overlay(PickerPalette.stroke)
            HStack(spacing: 12) {
                Spacer()
                Button(model.busy ? "Hide" : "Cancel") { model.escape() }
                    .accessibilityIdentifier("cancel-delete-session")
                if deletion.phase == .forceOffered {
                    Button("Force delete…") { model.offerForceDeleteSession() }
                        .accessibilityIdentifier("offer-force-delete-session")
                        .help("Cmd+Shift+X. Requires a separate confirmation.")
                } else if deletion.phase == .failed {
                    Button("Refresh review") { model.refreshDeletionReview() }
                        .accessibilityIdentifier("refresh-worktree-review")
                } else if hasDeletableWorktrees, deletion.phase == .review || deletion.plan != nil && deletion.phase == .loading {
                    Button { model.prepareSessionDeletion() } label: {
                        Text("Continue")
                            .fontWeight(.medium)
                            .foregroundStyle(model.canPrepareSessionDeletion ? PickerStyle.selectionText : PickerStyle.secondaryText)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(model.canPrepareSessionDeletion ? PickerStyle.selectionBackground : PickerStyle.foreground.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .disabled(!model.canPrepareSessionDeletion)
                    .help("Verify selected files before deletion. Nothing is deleted yet.")
                    .accessibilityIdentifier("prepare-session-deletion")
                } else if hasDeletableWorktrees, deletion.phase == .confirm || forceConfirmation {
                    Button { model.confirmDeleteSession() } label: {
                        Text(forceConfirmation ? "Force delete selected" : "Delete selected")
                            .fontWeight(.medium)
                            .foregroundStyle(actionColor)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(model.canConfirmSessionDeletion ? PickerStyle.selectionBackground : PickerStyle.foreground.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
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
    }

    private var explanation: String {
        if deletion.phase == .loading || deletion.phase == .review {
            return "Choose worktrees. Continue verifies files; nothing is deleted yet."
        }
        if deletion.phase == .preparing {
            return "Verifying selected files; nothing is being deleted. Large folders may take longer."
        }
        if !hasDeletableWorktrees { return "No deletable worktrees in this session." }
        return "Deletes selected worktrees and local branches. Other worktrees and remote branches stay."
    }

    private var actionColor: Color {
        guard model.canConfirmSessionDeletion else { return PickerStyle.secondaryText }
        return forceConfirmation ? .red : PickerStyle.selectionText
    }

    private func worktreeRow(_ worktree: DeletionWorktree) -> some View {
        let removed = deletion.deletedPaths.contains(worktree.path)
        return HStack(alignment: .top, spacing: 8) {
            if deletion.checkingPath == worktree.path {
                ProgressView().controlSize(.small).tint(PickerStyle.foreground).frame(width: 16)
                    .accessibilityLabel("Checking \(worktree.path)")
            } else if worktree.deletable && !removed {
                Toggle(worktree.branch, isOn: Binding(
                    get: { deletion.selectedPaths.contains(worktree.path) },
                    set: { model.selectDeletionWorktree(worktree.path, selected: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
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
                Button(worktree.error == nil ? (deletion.phase == .preparing ? "Verify" : "Check") : "Retry") { model.retryDeletionWorktree(worktree.path) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .accessibilityIdentifier("retry-worktree:\(worktree.path)")
            }
        }
        .padding(.vertical, 7)
    }

    @ViewBuilder private func worktreeStatus(_ worktree: DeletionWorktree, removed: Bool) -> some View {
        if removed {
            Text("Removed")
        } else if deletion.checkingPath == worktree.path {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(deletion.checkStartedAt ?? context.date)))
                Text("\(deletion.phase == .preparing ? "Verifying files" : "Reading Git details")… \(seconds)s")
            }
        } else if let error = worktree.error {
            Text(PickerStyle.deletionErrorSummary(error))
                .lineLimit(2)
                .help(error)
                .accessibilityLabel(error)
        } else if !worktree.isChecked {
            Text("Waiting to check…")
        } else if deletion.phase == .preparing, deletion.preparationSelection?.contains(worktree.path) == true {
            Text(worktree.isPrepared ? "Files verified" : "Waiting to verify files…")
        } else if worktree.needsForce == true {
            Text("Needs force confirmation")
        }
    }

    private func displayPath(_ path: String) -> String {
        PathDisplay.abbreviate(path, home: model.options.demo ? "/Users/demo" : NSHomeDirectory())
    }
}
