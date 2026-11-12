import SwiftUI

struct DeleteSessionPage: View {
    @ObservedObject var model: PickerModel
    let deletion: PickerModel.SessionDeletion

    private var forceConfirmation: Bool { deletion.phase == .forceConfirm }
    private var reviewing: Bool {
        deletion.preparationSelection == nil && !model.busy
            && (deletion.phase == .confirm || deletion.phase == .loading || deletion.phase == .review)
    }
    private var title: String {
        if forceConfirmation { return "Force delete worktrees?" }
        if deletion.phase == .preparing { return "Prepare deletion" }
        return deletion.preparationSelection == nil ? "Delete worktrees" : "Delete selected worktrees?"
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
                VStack(alignment: .leading, spacing: 16) {
                    Label(deletion.candidate.label ?? deletion.candidate.path, systemImage: "terminal")
                        .font(.system(size: PickerStyle.titleFontSize, weight: .semibold))
                    HStack {
                        Text(deletion.candidate.host ?? "This Mac")
                        Spacer()
                        if deletion.phase == .preparing, let rows = deletion.plan?.worktrees, let selected = deletion.preparationSelection {
                            Text("\(rows.filter { selected.contains($0.path) && $0.isPrepared }.count) of \(selected.count) verified")
                                .accessibilityIdentifier("worktree-prepare-count")
                        } else if deletion.phase == .loading, let rows = deletion.plan?.worktrees {
                            Text("\(rows.filter(\.isChecked).count) of \(rows.count) checked")
                                .accessibilityIdentifier("worktree-check-count")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(PickerStyle.secondaryText)

                    if let worktrees = deletion.plan?.worktrees {
                        VStack(spacing: 0) {
                            ForEach(worktrees) { worktree in
                                worktreeRow(worktree)
                                if worktree.id != worktrees.last?.id {
                                    Divider().overlay(PickerPalette.stroke).padding(.horizontal, 12)
                                }
                            }
                        }
                        .background(PickerStyle.fieldBackground, in: RoundedRectangle(cornerRadius: 8))

                        if deletion.phase == .confirm || deletion.phase == .forceOffered || forceConfirmation || deletion.phase == .deleting {
                            Toggle("Close this session and all its tabs and panes", isOn: Binding(
                                get: { deletion.closeSessionConfirmed },
                                set: { model.confirmDeletionSessionClose($0) }
                            ))
                            .toggleStyle(.checkbox)
                            .disabled(model.busy || deletion.phase != .confirm)
                            .accessibilityIdentifier("confirm-close-deletion-session")
                        }

                        Text(explanation)
                            .font(.system(size: 12))
                            .foregroundStyle(PickerStyle.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if forceConfirmation {
                        Text("Discards uncommitted files and unmerged commits in the selected worktrees. This cannot be undone.")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = deletion.error {
                        Text(error)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("delete-session-error")
                    }
                    if deletion.plan == nil && deletion.phase == .loading || deletion.phase == .deleting {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            if deletion.phase == .deleting {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    let seconds = max(0, Int(context.date.timeIntervalSince(deletion.checkStartedAt ?? context.date)))
                                    Text("Revalidating selected files and deleting… \(seconds)s")
                                }
                                .foregroundStyle(PickerStyle.secondaryText)
                            } else {
                                Text("Loading pane directories…").foregroundStyle(PickerStyle.secondaryText)
                            }
                        }
                        .accessibilityIdentifier("delete-session-progress")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
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
                } else if deletion.phase == .review || deletion.plan != nil && deletion.phase == .loading {
                    Button { model.prepareSessionDeletion() } label: {
                        Text("Prepare deletion")
                            .fontWeight(.medium)
                            .foregroundStyle(model.canPrepareSessionDeletion ? PickerStyle.selectionText : PickerStyle.secondaryText)
                            .padding(.horizontal, 12)
                            .frame(height: PickerStyle.controlHeight)
                            .background(model.canPrepareSessionDeletion ? PickerStyle.selectionBackground : PickerStyle.foreground.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(!model.canPrepareSessionDeletion)
                    .accessibilityIdentifier("prepare-session-deletion")
                } else if deletion.phase == .confirm || forceConfirmation {
                    Button { model.confirmDeleteSession() } label: {
                        Text(forceConfirmation ? "Force delete selected" : "Delete selected")
                            .fontWeight(.medium)
                            .foregroundStyle(actionColor)
                            .padding(.horizontal, 12)
                            .frame(height: PickerStyle.controlHeight)
                            .background(model.canConfirmSessionDeletion ? PickerStyle.selectionBackground : PickerStyle.foreground.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(!model.canConfirmSessionDeletion)
                    .accessibilityIdentifier("confirm-delete-session")
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .frame(height: 44)
        }
        .font(.system(size: PickerStyle.bodyFontSize))
        .foregroundStyle(PickerStyle.foreground)
        .accessibilityIdentifier("delete-session-page")
    }

    private var explanation: String {
        if deletion.phase == .loading || deletion.phase == .review {
            return "Choose worktrees, then prepare deletion to verify their files. Nothing is deleted yet."
        }
        if deletion.phase == .preparing {
            return "Verifying only selected worktrees. Large dependency folders can take time. Nothing is being deleted."
        }
        return "Selected worktrees and local branches will be deleted. Unselected worktrees and remote branches are kept. All tabs close, including tabs for unselected repos."
    }

    private var actionColor: Color {
        guard model.canConfirmSessionDeletion else { return PickerStyle.secondaryText }
        return forceConfirmation ? .red : PickerStyle.selectionText
    }

    private func worktreeRow(_ worktree: DeletionWorktree) -> some View {
        let removed = deletion.deletedPaths.contains(worktree.path)
        return HStack(alignment: .top, spacing: 10) {
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
            VStack(alignment: .leading, spacing: 4) {
                Text(worktree.branch.isEmpty ? (worktree.path.isEmpty ? "Unknown directory" : URL(fileURLWithPath: worktree.path).lastPathComponent) : worktree.branch)
                    .fontWeight(.medium)
                Text(displayPath(worktree.path))
                    .font(.system(size: 11))
                    .foregroundStyle(PickerStyle.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if removed {
                    Text("Worktree removed").font(.system(size: 11)).foregroundStyle(PickerStyle.secondaryText)
                } else if deletion.checkingPath == worktree.path {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(0, Int(context.date.timeIntervalSince(deletion.checkStartedAt ?? context.date)))
                        Text("\(deletion.phase == .preparing ? "Verifying selected files" : "Reading Git worktree details")… \(seconds)s")
                            .font(.system(size: 11)).foregroundStyle(PickerStyle.secondaryText)
                    }
                } else if let error = worktree.error {
                    Text(error).font(.system(size: 11)).foregroundStyle(PickerStyle.secondaryText)
                        .help(error)
                } else if !worktree.isChecked {
                    Text("Waiting to check…").font(.system(size: 11)).foregroundStyle(PickerStyle.secondaryText)
                } else if deletion.phase == .preparing, deletion.preparationSelection?.contains(worktree.path) == true {
                    Text(worktree.isPrepared ? "Files verified" : "Waiting for file verification…")
                        .font(.system(size: 11)).foregroundStyle(PickerStyle.secondaryText)
                } else if worktree.needsForce == true {
                    Text("Needs force confirmation").font(.system(size: 11)).foregroundStyle(PickerStyle.secondaryText)
                }
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
        .padding(12)
    }

    private func displayPath(_ path: String) -> String {
        PathDisplay.abbreviate(path, home: model.options.demo ? "/Users/demo" : NSHomeDirectory())
    }
}
