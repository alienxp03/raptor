import SwiftUI
import AppKit

struct PickerView: View {
    @ObservedObject var model: PickerModel
    @FocusState private var field: Field?
    @State private var baseReturnFocus: Field = .base
    @State private var selectedInitialDefault = false
    @State private var errorDetailsPresented = false
    private enum Field { case search, branch, base, target, submit, pullRequest }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.page == .pr { pullRequestForm }
            else if model.page == .create { createForm } else { results }
            status
            footer
        }
        .font(.system(size: PickerStyle.bodyFontSize))
        .foregroundStyle(PickerStyle.foreground)
        .frame(width: PickerStyle.width, height: PickerStyle.height(for: model))
        .tint(PickerStyle.selection)
        // Color.primary and system controls follow the Rex theme, not the app's own appearance.
        .preferredColorScheme(PickerPalette.isDark ? .dark : .light)
        .id(ObjectIdentifier(model))
        .task(id: ObjectIdentifier(model)) {
            guard !Task.isCancelled else { return }
            model.onFocusSearch = { field = .search }
            model.onAdvanceFormFocus = { advanceFormFocus(backward: $0) }
        }
        .onChange(of: model.basePickerPresented) { _, shown in
            if !shown && model.page == .create { field = baseReturnFocus }
        }
        .onChange(of: model.page) { _, page in
            model.basePickerPresented = false
            selectedInitialDefault = false
            field = page == .pr ? .pullRequest : (page == .create ? .branch : .search)
        }
        .onChange(of: model.renameCandidate?.id) { _, id in
            if id == nil { field = .search }
        }
        .alert("Check out PR commit?", isPresented: $model.prCommitConfirmationPresented) {
            Button("Cancel", role: .cancel) { model.cancelPullRequestCommitCheckout() }
                .keyboardShortcut(.defaultAction)
            Button("Check out PR commit") { model.confirmPullRequestCommitCheckout() }
                .accessibilityIdentifier("confirm-pr-commit")
        } message: {
            Text(model.pullRequestCommitExplanation)
        }
        .alert("Close session?", isPresented: Binding(
            get: { model.removalCandidate != nil && model.view == .sessions && model.page == .directories },
            set: { if !$0 { model.removalCandidate = nil } }
        ), presenting: model.view == .sessions && model.page == .directories ? model.removalCandidate : nil) { candidate in
            Button("Cancel", role: .cancel) { model.removalCandidate = nil }
                .keyboardShortcut(.defaultAction)
            Button("Close", role: .destructive) { model.confirmCloseSession(candidate) }
                .accessibilityIdentifier("confirm-remove")
        } message: { candidate in
            Text("Close \(candidate.label ?? candidate.path)? Every pane in it closes.")
        }
    }

    private var header: some View {
        Group {
            if model.isForm {
                HStack(spacing: 8) {
                    Text(model.page == .pr ? "Open pull request" : "New worktree")
                        .font(.system(size: PickerStyle.rowFontSize, weight: .semibold))
                    if model.options.demo { demoBadge }
                    Spacer()
                }
                .padding(.horizontal, PickerStyle.horizontalInset)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(PickerStyle.foreground.opacity(0.5))
                    TextField(searchPrompt, text: $model.query,
                              prompt: Text(searchPrompt).foregroundColor(PickerStyle.foreground.opacity(0.45)))
                        .textFieldStyle(.plain)
                        .font(.system(size: PickerStyle.rowFontSize))
                        .focused($field, equals: .search)
                        .task { await Task.yield(); field = .search }
                        .disabled(model.busy || model.renameCandidate != nil)
                        .accessibilityLabel("Search \(model.heading.lowercased())")
                        .accessibilityIdentifier("picker-search")
                    if model.loading {
                        ProgressView().controlSize(.mini).accessibilityLabel("Loading results")
                    }
                    if model.options.demo { demoBadge }
                }
                .padding(.horizontal, 9)
                .frame(height: PickerStyle.searchFieldHeight)
                .background(PickerStyle.fieldBackground, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, PickerStyle.listInset)
            }
        }
        .frame(height: model.isForm ? PickerStyle.createHeaderHeight : PickerStyle.searchHeight)
    }

    private var searchPrompt: String {
        if model.view == .agents { return "Search agents…" }
        if model.page == .worktrees { return "Search worktrees…" }
        return "Search sessions and directories…"
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.view == .agents && model.items.first?.kind != "pr" {
                        ForEach(model.agentSections) { section in
                            Text(section.group.rawValue)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(PickerStyle.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, PickerStyle.rowInset)
                                .frame(height: PickerStyle.agentGroupHeight)
                                .padding(.top, section.id == model.agentSections.first?.id ? 0 : PickerStyle.agentGroupSpacing)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier("agent-group:\(section.id)")
                            ForEach(section.items) { item in
                                row(item, position: model.numberedPosition(of: item)).id(item.id)
                            }
                        }
                    } else {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            row(item, position: index + 1).id(item.id)
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, PickerStyle.listInset).padding(.vertical, 4)
            }
            .scrollPosition(id: $model.scrollID)
            .overlay {
                if model.items.isEmpty {
                    Text(model.loading ? "Loading…" : (model.error == nil ? emptyMessage : "No results"))
                        .foregroundStyle(PickerStyle.secondaryText)
                }
            }
            .frame(maxHeight: .infinity)
            .accessibilityIdentifier("picker-results")
            .onChange(of: model.selectedID, initial: true) { _, id in
                // No anchor: keep visible rows still; reveal only clipped rows.
                if let id { proxy.scrollTo(id) }
            }
        }
        .id(model.listPresentation)
    }

    /// Small helpers keep each branch's type-checking surface tiny; the CI
    /// toolchain times out on the monolithic ViewBuilder.
    private func cmdBadge(_ position: Int, selected: Bool) -> some View {
        let font = Font.system(size: 10, weight: .medium).monospacedDigit()
        let color = selected ? PickerStyle.selectionText.opacity(0.55) : PickerStyle.foreground.opacity(0.45)
        return Text("⌘\(position)")
            .font(font)
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }

    private func pinnedIcon(selected: Bool) -> some View {
        let color = selected ? PickerStyle.selectionText.opacity(0.85) : PickerStyle.selection
        return Image(systemName: "pin.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .accessibilityLabel("Pinned")
    }

    private func agentContextLabel(_ text: String, selected: Bool) -> some View {
        let color = selected ? PickerStyle.selectionText.opacity(0.7) : PickerStyle.secondaryText
        return Text(text)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: 220, alignment: .trailing)
            .layoutPriority(2)
    }

    private func agentAgeLabel(_ age: String, updated: String?, selected: Bool) -> some View {
        let color = selected ? PickerStyle.selectionText.opacity(0.7) : PickerStyle.secondaryText
        return Text(age)
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(color)
            .fixedSize()
            .help(updated ?? "")
    }

    private func sessionMarker(selected: Bool) -> some View {
        Circle().fill(selected ? PickerStyle.selectionText : PickerStyle.selection)
            .frame(width: 5, height: 5)
            .opacity(0.9)
            .accessibilityLabel("Active")
    }

    private func hostLabel(_ host: String, selected: Bool) -> some View {
        let color = selected ? PickerStyle.selectionText.opacity(0.7) : PickerStyle.secondaryText
        // Never truncates: the label yields its space instead.
        return Text("· " + host)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .layoutPriority(2)
            .accessibilityLabel("On \(host)")
    }

    @ViewBuilder
    private func rowContent(_ item: PickerItem, position: Int, selected: Bool, isAgent: Bool, isSessionRow: Bool, isLauncherDir: Bool) -> some View {
            if position >= 1, position <= 9 {
                cmdBadge(position, selected: selected)
            }
            if !isAgent && item.isPinned == true {
                pinnedIcon(selected: selected)
            }
            if item.kind == "pr" {
                Text(item.label ?? item.path).lineLimit(1).truncationMode(.middle)
            } else if isAgent {
                AgentIcon(app: item.app)
                    .frame(width: 16, height: 16).accessibilityHidden(true)
                Text(item.label ?? item.agentID ?? "Agent")
                    .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                ActivityIndicator(activity: item.activity, workingColor: selected ? PickerStyle.selectionText : PickerStyle.foreground)
                Spacer(minLength: 8)
                if !item.agentContext.isEmpty {
                    agentContextLabel(item.agentContext, selected: selected)
                }
                if let age = item.updatedAge() {
                    agentAgeLabel(age, updated: item.updatedAt, selected: selected)
                }
            } else if isSessionRow {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? PickerStyle.selectionText.opacity(0.85) : PickerStyle.sessionText)
                    .accessibilityHidden(true)
                if item.active == true {
                    sessionMarker(selected: selected)
                }
                if model.renameCandidate?.id == item.id {
                    InlineSessionNameField(text: $model.renameLabel,
                        onSubmit: { model.confirmRenameSession() },
                        onCancel: { model.cancelRenameSession() })
                        .layoutPriority(1)
                    Text("↵ Save · Esc Cancel")
                        .font(.system(size: 10))
                        .foregroundStyle(PickerStyle.selectionText.opacity(0.7))
                        .fixedSize()
                } else {
                    Text(item.label ?? item.path)
                        .foregroundStyle(selected ? PickerStyle.selectionText : PickerStyle.sessionText)
                        .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                }
            } else if let branch = item.branch {
                Text(branch + (item.isMain == true ? " · primary" : ""))
                    .lineLimit(selected ? 2 : 1).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isLauncherDir {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? PickerStyle.selectionText.opacity(0.85) : PickerStyle.directoryText)
                    .accessibilityHidden(true)
                // Use hue, not disabled text, to distinguish folders from sessions.
                Text(displayPath(item.path))
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(selected ? PickerStyle.selectionText : PickerStyle.directoryText)
            } else {
                Text(displayPath(item.path))
                    .lineLimit(1).truncationMode(.middle)
            }
            if !isAgent {
                ActivityIndicator(activity: item.activity, workingColor: selected ? PickerStyle.selectionText : PickerStyle.foreground)
            }
            if !isAgent, item.isLocal == false, let host = item.host, !host.isEmpty {
                hostLabel(host, selected: selected)
            }
        }

    private func rowHeight(_ item: PickerItem, isAgent: Bool, selected: Bool) -> CGFloat {
        if isAgent { return PickerStyle.agentRowHeight }
        if model.page == .worktrees {
            return PickerStyle.worktreeRowHeight * CGFloat(selected ? PickerStyle.branchLines(for: item) : 1)
        }
        return PickerStyle.rowHeight
    }

    private func rowHelp(_ item: PickerItem, isAgent: Bool) -> String {
        if isAgent {
            return [item.agentHelp, item.updatedAt].compactMap { $0 }.joined(separator: " · ")
        }
        return launcherRowHelp(item)
    }

    private func rowAccessibility(_ item: PickerItem, isAgent: Bool, isSessionRow: Bool) -> String {
        let primary: String
        if isAgent {
            primary = item.agentAccessibility
        } else if item.kind == "pr" || isSessionRow {
            primary = item.label ?? item.path
        } else {
            primary = displayPath(item.path) + (item.branch.map { ", branch \($0)" } ?? "")
        }
        let active = item.active == true && !isAgent ? ", Active" : ""
        let activity = item.activityAccessibility.isEmpty ? "" : ", " + item.activityAccessibility
        return primary + active + activity
    }

    private func row(_ item: PickerItem, position: Int = 0) -> some View {
        let selected = model.selectedID == item.id
        let isAgent = model.view == .agents && item.kind != "pr"
        let isSessionRow = model.view == .sessions && item.isSessionEntry
        let isLauncherDir = model.view == .sessions && item.kind == "dir"
        return HoverRow(selected: selected, enabled: true) {
            rowContent(item, position: position, selected: selected, isAgent: isAgent, isSessionRow: isSessionRow, isLauncherDir: isLauncherDir)
        }
        .font(.system(size: PickerStyle.rowFontSize, weight: selected ? .medium : .regular))
        .foregroundStyle(selected ? PickerStyle.selectionText : PickerStyle.foreground)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PickerStyle.rowInset)
        .frame(height: rowHeight(item, isAgent: isAgent, selected: selected))
        .background {
            if selected { RoundedRectangle(cornerRadius: 9).fill(PickerStyle.selectionBackground) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard !model.busy, !model.loading, model.renameCandidate == nil else { return }
            model.selectedID = item.id
            model.choose()
        }
        .onTapGesture {
            guard !model.busy, !model.loading, model.renameCandidate == nil else { return }
            model.selectedID = item.id
        }
        .help(rowHelp(item, isAgent: isAgent))
        .accessibilityElement(children: model.renameCandidate?.id == item.id ? .contain : .ignore)
        .accessibilityLabel(rowAccessibility(item, isAgent: isAgent, isSessionRow: isSessionRow))
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("path-row:\(item.path)")
        .accessibilityAction {
            guard model.renameCandidate == nil else { return }
            model.selectedID = item.id; model.choose()
        }
    }

    private var selectedWorktreePath: some View {
        Group {
            if let selected = model.selected {
                Text(displayPath(selected.path))
                    .font(.system(size: 12)).foregroundStyle(PickerStyle.secondaryText)
                    .textSelection(.enabled)
                    .lineLimit(2).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(selected.path)
            }
        }
        .padding(.horizontal, PickerStyle.listInset + PickerStyle.rowInset)
        .frame(height: PickerStyle.selectedPathHeight, alignment: .leading)
        .accessibilityIdentifier("selected-worktree-path")
    }

    private var pullRequestForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                formLabel("Pull request")
                TextField("GitHub pull request URL", text: $model.prInput,
                          prompt: Text(verbatim: "https://github.com/owner/repo/pull/123")
                            .foregroundColor(PickerStyle.foreground.opacity(0.45)))
                    .textFieldStyle(.plain).disableAutocorrection(true)
                    .foregroundStyle(PickerStyle.foreground)
                    .padding(.horizontal, 9).frame(height: PickerStyle.controlHeight)
                    .modifier(PickerFormField(focused: field == .pullRequest))
                    .focused($field, equals: .pullRequest)
                    .task { await Task.yield(); field = .pullRequest }
                    .onSubmit { model.openPullRequest() }
                    .disabled(model.busy || model.createdPath != nil)
                    .accessibilityLabel("GitHub pull request URL")
                    .accessibilityIdentifier("pr-input")
            }
            pathRow("Title", value: model.pullRequest?.title ?? "—", path: nil, identifier: "pr-title")
            if let state = model.pullRequest?.state, !state.isEmpty {
                pathRow("Status", value: state.capitalized + (model.pullRequest?.headDeleted == true ? " · branch deleted" : ""),
                        path: nil, identifier: "pr-state")
            }
            pathRow("Repo", value: pullRequestRepoLabel, path: model.pullRequest?.repo)
            pathRow("Branch", value: model.pullRequest?.branch ?? "—", path: nil, identifier: "pr-branch")
            pathRow("Destination", value: (model.createdPath ?? model.pullRequest?.path).map(displayPath) ?? "Resolved by Worktrunk", path: model.createdPath ?? model.pullRequest?.path)
            openTargetControl
            if let stage = model.prStage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(stage).font(.system(size: 12))
                }
                .accessibilityIdentifier("pr-progress")
            }
        }
        .padding(.horizontal, PickerStyle.horizontalInset).padding(.vertical, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var pullRequestRepoLabel: String {
        let path = model.pullRequest?.repo.map(displayPath) ?? "From PR URL"
        return model.pullRequest?.cloneRequired == true ? "Will clone to \(path)" : path
    }

    private var pullRequestActionLabel: String {
        if model.busy { return model.prStage ?? "Opening session" }
        if model.createdPath != nil { return "Retry opening" }
        if model.requiresPullRequestCommitChoice { return "Check out PR commit…" }
        return model.pullRequest?.existing == true ? "Open existing" : "Open PR"
    }

    private var pullRequestSubmitButton: some View {
        Button { model.openPullRequest() } label: {
            formActionLabel(model.busy ? "Opening…" : pullRequestActionLabel, enabled: model.canOpenPullRequest)
        }
        .buttonStyle(.plain).focusable().focused($field, equals: .submit)
        .keyboardShortcut(.return, modifiers: .command)
        .onKeyPress(.return) { model.openPullRequest(); return .handled }
        .disabled(!model.canOpenPullRequest)
        .accessibilityIdentifier("pr-submit")
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            pathRow("Repo", value: model.repo.map(displayPath) ?? "Loading…", path: model.repo)
            HStack(spacing: 10) {
                formLabel("Branch")
                TextField("feat/my-change", text: Binding(get: { model.branch }, set: { model.editBranch($0) }))
                    .disableAutocorrection(true)
                    .textFieldStyle(.plain).padding(.horizontal, 9)
                    .frame(height: PickerStyle.controlHeight)
                    .modifier(PickerFormField(focused: field == .branch))
                    .focused($field, equals: .branch)
                    .task { await Task.yield(); field = .branch; selectInitialBranchDefault() }
                    .onChange(of: model.branch) { _, _ in selectInitialBranchDefault() }
                    .onSubmit { model.submitBranch() }
                    .disabled(model.createdPath != nil)
                    .accessibilityLabel("New branch name").accessibilityIdentifier("create-branch")
            }
            HStack(spacing: 10) {
                formLabel("Base")
                Button { presentBasePicker() } label: {
                    HStack {
                        Text(model.base.isEmpty ? "Choose a local branch…" : model.base)
                            .foregroundStyle(model.base.isEmpty ? PickerStyle.foreground.opacity(0.45) : PickerStyle.foreground)
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(PickerStyle.foreground.opacity(0.5))
                    }
                    .padding(.horizontal, 9)
                    .frame(height: PickerStyle.controlHeight)
                    .modifier(PickerFormField(focused: field == .base))
                }
                .buttonStyle(.plain).focusable().focused($field, equals: .base)
                .onKeyPress(.return) { presentBasePicker(); return .handled }
                .disabled(model.createdPath != nil || model.loading)
                .help("Search local branches. Enter selects a branch.")
                .accessibilityLabel("Base branch: \(model.base)")
                .accessibilityIdentifier("create-base")
                .popover(isPresented: $model.basePickerPresented, arrowEdge: .bottom) {
                    BranchPickerPopover(current: model.base, initialBranches: model.branches,
                        search: { try await model.searchBaseBranches($0) },
                        choose: { value in
                            model.base = value
                            baseReturnFocus = .target
                            model.basePickerPresented = false
                        })
                }
            }
            openTargetControl
            pathRow("Destination", value: destinationLabel, path: model.createdPath ?? model.destination ?? model.destinationRoot)
            if !model.branch.isEmpty, model.previewReady, let validation = model.validationError {
                Text(validation).font(.system(size: 12)).foregroundStyle(.orange).lineLimit(2)
                    .accessibilityIdentifier("create-validation")
            }
        }
        .padding(.horizontal, PickerStyle.horizontalInset).padding(.vertical, 8)
        .disabled(model.busy).frame(maxHeight: .infinity, alignment: .top)
    }

    private func formLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 12)).foregroundStyle(PickerStyle.secondaryText)
            .frame(width: 90, alignment: .leading)
    }

    private func pathRow(_ title: String, value: String, path: String?, identifier: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            formLabel(title)
            Text(value).font(.system(size: 12))
                .foregroundStyle(path == nil ? PickerStyle.secondaryText : PickerStyle.foreground.opacity(0.85))
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(path ?? value)
                .accessibilityIdentifier(identifier ?? (title == "Repo" ? "create-repo" : "create-destination"))
        }
    }

    private var destinationLabel: String {
        if let path = model.createdPath ?? model.destination { return displayPath(path) }
        if model.loading { return "Loading…" }
        if model.branch.isEmpty, let root = model.destinationRoot { return displayPath(root) }
        return model.branch.isEmpty ? "Loading destination…" : "Checking destination…"
    }

    private var createActionLabel: String {
        if model.busy { return model.createdPath == nil ? "Creating…" : "Opening…" }
        if model.createdPath != nil { return model.error == nil ? "Open worktree" : "Retry opening" }
        return "Create"
    }

    private var createSubmitButton: some View {
        Button { model.create() } label: {
            formActionLabel(createActionLabel, enabled: model.canSubmitForm)
        }
        .buttonStyle(.plain)
        .focusable().focused($field, equals: .submit)
        .keyboardShortcut(.return, modifiers: .command)
        .onKeyPress(.return) {
            if model.canSubmitForm { model.create() }
            return .handled
        }
        .disabled(!model.canSubmitForm)
        .accessibilityLabel(createActionLabel)
        .accessibilityIdentifier(model.createdPath == nil ? "create-submit" : "open-created")
    }

    private func formActionLabel(_ title: String, enabled: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title).fontWeight(.medium)
            Text("⌘↵").opacity(0.65)
        }
        .foregroundStyle(enabled ? PickerStyle.selectionText : PickerStyle.secondaryText)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(enabled ? PickerStyle.selectionBackground : PickerStyle.foreground.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(field == .submit ? PickerStyle.selection : Color.clear))
    }

    private func selectInitialBranchDefault() {
        // macOS 14 has no TextField selection binding. Use only its active editor;
        // never move focus or select after the user has changed the value.
        let value = model.branch
        guard !selectedInitialDefault, !model.branchWasEdited, !value.isEmpty, field == .branch else { return }
        DispatchQueue.main.async {
            guard !selectedInitialDefault, field == .branch, !model.branchWasEdited,
                  model.branch == value, let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                  editor.isFieldEditor, editor.string == value else { return }
            editor.selectAll(nil)
            selectedInitialDefault = true
        }
    }

    private func presentBasePicker() {
        guard !model.loading, !model.busy, model.createdPath == nil else { return }
        baseReturnFocus = .base
        field = .base
        model.basePickerPresented = true
    }

    private func advanceFormFocus(backward: Bool) {
        guard model.isForm, !model.busy, !model.basePickerPresented else { return }
        if model.page == .pr {
            var fields: [Field] = model.createdPath == nil ? [.pullRequest, .target] : [.target]
            if model.canOpenPullRequest { fields.append(.submit) }
            let current = fields.firstIndex(of: field ?? .pullRequest) ?? (backward ? 0 : -1)
            field = fields[(current + (backward ? fields.count - 1 : 1)) % fields.count]
            return
        }
        var fields: [Field] = model.createdPath == nil ? (model.loading ? [.branch] : [.branch, .base]) : []
        if !model.targets.isEmpty { fields.append(.target) }
        if model.canSubmitForm { fields.append(.submit) }
        let current = fields.firstIndex(of: field ?? .branch) ?? (backward ? 0 : -1)
        field = fields[(current + (backward ? fields.count - 1 : 1)) % fields.count]
    }

    @ViewBuilder private var status: some View {
        if let error = model.error {
            HStack(alignment: .top, spacing: 8) {
                Text(verbatim: PickerStyle.errorSummary(error))
                    .foregroundStyle(.red).accessibilityIdentifier("picker-error")
                    .lineLimit(2).textSelection(.enabled).help(error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Details…") { errorDetailsPresented = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(PickerStyle.foreground)
                    .accessibilityIdentifier("picker-error-details")
                    .popover(isPresented: $errorDetailsPresented, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Operation failed").fontWeight(.semibold)
                                Spacer()
                                Button("Copy error") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(error, forType: .string)
                                }
                            }
                            ScrollView {
                                Text(verbatim: error)
                                    .font(.system(size: 12, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(PickerStyle.foreground)
                        .padding(16).frame(width: 560, height: 280)
                        .pickerGlass()
                    }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10).padding(.vertical, 4)
        } else if let notice = model.notice {
            Text(notice).foregroundStyle(PickerStyle.secondaryText).accessibilityIdentifier("picker-notice")
                .font(.system(size: 11)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 4)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                if model.splitMode {
                    Text("Split ⌃P   j↓  l→").accessibilityIdentifier("keyboard-hint")
                } else if model.view == .agents {
                    EmptyView()
                } else if model.isForm {
                    if model.createdPath != nil {
                        Button("Discard recovery") { model.discardCreatedRecovery() }
                            .disabled(model.busy)
                            .help("Keep the worktree, but forget Retry opening and dismiss the picker.")
                            .accessibilityIdentifier("discard-created-recovery")
                    } else {
                        Text("Tab fields · ⌃O target").accessibilityIdentifier("keyboard-hint")
                    }
                } else {
                    openTargetControl
                }
                Spacer(minLength: 0)
                if !model.isForm && !model.splitMode {
                    Button("⇧⌘P PR") { model.beginPullRequest() }
                        .font(.system(size: 10))
                        .disabled(model.busy || !model.contextReady || model.createdPath != nil)
                        .help("Open pull request (⇧⌘P)")
                        .accessibilityLabel("Open pull request")
                        .accessibilityIdentifier("open-pull-request")
                }
                if model.view == .agents {
                    Button("↵") { model.choose() }.disabled(!model.canOpen)
                        .help("Open selected result (Return)")
                        .accessibilityLabel("Open selected result")
                        .accessibilityIdentifier("open-selected")
                } else if model.page == .directories && !model.splitMode {
                    sessionActions
                }
                if model.page == .create { createSubmitButton }
                if model.page == .pr { pullRequestSubmitButton }
            }
            .frame(height: PickerStyle.footerHeight)
        }
        .disabled(model.renameCandidate != nil)
        .font(.system(size: 11)).foregroundStyle(PickerStyle.foreground.opacity(0.65))
        .lineLimit(1)
        .buttonStyle(.plain)
        .padding(.horizontal, PickerStyle.horizontalInset)
        .frame(height: PickerStyle.footerHeight)
        .overlay(alignment: .top) {
            Divider().overlay(PickerPalette.stroke)
        }
    }

    private var sessionActions: some View {
        HStack(spacing: 12) {
            Button("↵") { model.choose() }.disabled(!model.canOpen)
                .help("Open selected result (Return)")
                .accessibilityLabel("Open selected result")
                .accessibilityIdentifier("open-selected")
            if model.selected?.kind == "session" {
                Button("⌃R Rename") { model.beginRenameSession() }
                    .disabled(!model.canOpen)
                    .accessibilityIdentifier("rename-session")
                Button("⌃X Close") { model.askCloseSession() }
                    .disabled(model.busy || model.loading || model.selected?.kind != "session")
                    .accessibilityIdentifier("remove-session")
            }
        }
        .font(.system(size: 10))
        .fixedSize()
        .accessibilityIdentifier("session-actions")
    }

    private var openTargetControl: some View {
        HStack(spacing: model.isForm ? 10 : 6) {
            if model.isForm { formLabel("Open in") }
            else { Text("Open in:").font(.system(size: 11)).foregroundStyle(PickerStyle.foreground.opacity(0.75)) }
            Button {
                guard !model.targetPickerPresented else { return }
                model.targetPickerPresented = true
            } label: {
                HStack(spacing: 6) {
                    Text(PickerModel.targetLabel(model.target))
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                }
                .font(.system(size: model.isForm ? PickerStyle.bodyFontSize : 11, weight: .medium))
                .foregroundStyle(PickerStyle.foreground.opacity(0.85))
                .padding(.horizontal, 8)
                .frame(height: model.isForm ? PickerStyle.controlHeight : 22)
                .background(PickerStyle.foreground.opacity(0.06), in: Capsule())
                .overlay(Capsule().strokeBorder(field == .target ? PickerStyle.selection : Color.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable().focused($field, equals: .target)
            .focusEffectDisabled()
            .fixedSize().disabled(model.busy || model.targets.isEmpty)
            .onKeyPress(.return) {
                model.targetPickerPresented = true
                return .handled
            }
            .help("Choose where to open. Press Ctrl+O or Ctrl+Shift+O to change.")
            .accessibilityLabel("Open in: \(PickerModel.targetLabel(model.target))")
            .accessibilityIdentifier("open-target")
            .popover(isPresented: $model.targetPickerPresented, arrowEdge: .bottom) {
                TargetPickerPopover(targets: model.targets, current: model.target, choose: { value in
                    model.target = value
                    model.targetPickerPresented = false
                })
            }
            if !model.isForm {
                Text("⌃O").font(.system(size: 10)).foregroundStyle(PickerStyle.foreground.opacity(0.65))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var demoBadge: some View {
        Text("Demo").font(.system(size: 10)).foregroundStyle(.tertiary)
            .accessibilityIdentifier("demo-indicator")
    }

    private func displayPath(_ path: String) -> String {
        PathDisplay.abbreviate(path, home: model.options.demo ? "/Users/demo" : NSHomeDirectory())
    }

    /// Row tooltip: host and open context — never the raw session id.
    private func launcherRowHelp(_ item: PickerItem) -> String {
        if model.view != .sessions {
            return item.path
        }
        var parts: [String] = []
        if item.kind == "session" {
            parts.append("Session")
            if item.active == true { parts.append("Current session") }
        } else {
            parts.append("Directory")
            if let host = item.host, host != "This Mac" { parts.append("on \(host)") }
        }
        if let host = item.host, host != "This Mac" { parts.append("via \(host)") }
        return parts.joined(separator: " · ")
    }

    private var emptyMessage: String {
        if model.view == .agents { return "No matching agents" }
        if model.page == .worktrees { return "No matching worktrees" }
        return "No matching sessions or directories"
    }
}

// Use the search surface for every editable form control; amber only marks focus.
private struct PickerFormField: ViewModifier {
    let focused: Bool

    func body(content: Content) -> some View {
        content
            .background(PickerStyle.fieldBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(focused ? PickerStyle.selection.opacity(0.7) : Color.clear))
    }
}

// Rows brighten under the cursor without stealing the selection.
private struct HoverRow<Content: View>: View {
    let selected: Bool
    let enabled: Bool
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) { content() }
            .background {
                if hovering, !selected, enabled {
                    RoundedRectangle(cornerRadius: 9).fill(PickerStyle.foreground.opacity(0.05))
                }
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: hovering)
    }
}
