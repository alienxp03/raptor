import SwiftUI
import AppKit

struct PickerView: View {
    @ObservedObject var model: PickerModel
    @FocusState private var field: Field?
    @State private var baseReturnFocus: Field = .base
    @State private var selectedInitialDefault = false
    private enum Field { case search, branch, base, target, submit }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.showsPills { viewPills }
            if model.page == .create { createForm } else { results }
            if model.page == .worktrees && model.view == .repos { selectedWorktreePath }
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
            field = page == .create ? .branch : .search
        }
        .alert("Remove worktree?", isPresented: Binding(
            get: { model.removalCandidate != nil && model.view == .repos },
            set: { if !$0 { model.removalCandidate = nil } }
        ), presenting: model.view == .repos ? model.removalCandidate : nil) { candidate in
            Button("Cancel", role: .cancel) { model.removalCandidate = nil }
                .keyboardShortcut(.defaultAction)
            Button("Remove", role: .destructive) { model.confirmRemove(candidate) }
                .accessibilityIdentifier("confirm-remove")
        } message: { candidate in
            Text("Remove \(displayPath(candidate.path))?\nGit checks for unsaved changes. The branch is kept.")
        }
    }

    private var header: some View {
        Group {
            if model.page == .create {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("New worktree").font(.system(size: PickerStyle.titleFontSize, weight: .semibold))
                        if model.options.demo { demoBadge }
                        Spacer()
                    }
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
                        .disabled(model.busy)
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
        .frame(height: model.page == .create ? PickerStyle.createHeaderHeight : PickerStyle.searchHeight)
    }

    private var searchPrompt: String {
        if model.view == .agents { return "Search agents…" }
        switch model.page {
        case .repositories: return "Search repositories…"
        case .worktrees: return "Search worktrees…"
        default: return "Search directories…"
        }
    }

    private var viewPills: some View {
        HStack(spacing: 6) {
            pill("Repos", active: model.view == .repos, icon: "folder", hint: nil)
                .accessibilityIdentifier("pill-repos")
                .onTapGesture { model.selectView(.repos) }
            pill("Agents", active: model.view == .agents, icon: "cpu", hint: nil)
                .accessibilityIdentifier("pill-agents")
                .accessibilityHint("Show Agents, Shift Command A")
                .help("Show Agents (⇧⌘A)")
                .onTapGesture { model.selectView(.agents) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PickerStyle.listInset)
        .padding(.bottom, 8)
        .frame(height: PickerStyle.pillsHeight)
        .accessibilityIdentifier("view-pills")
    }

    private func pill(_ title: String, active: Bool, icon: String, hint: String?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(title).font(.system(size: 12, weight: active ? .semibold : .regular))
            if let hint {
                Text(hint).font(.system(size: 10)).foregroundStyle(PickerStyle.foreground.opacity(active ? 0.7 : 0.45))
            }
        }
        .foregroundStyle(active ? PickerStyle.foreground : PickerStyle.foreground.opacity(0.55))
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(active ? PickerStyle.foreground.opacity(0.12) : PickerStyle.foreground.opacity(0.05), in: Capsule())
        .contentShape(Capsule())
    }

    private var results: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if model.view == .agents {
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
    }

    private func row(_ item: PickerItem, position: Int = 0) -> some View {
        let selected = model.selectedID == item.id
        let isAgent = model.view == .agents
        return HoverRow(selected: selected, enabled: true) {
            if position >= 1, position <= 9 {
                Text("⌘\(position)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(selected ? PickerStyle.selectionText.opacity(0.55) : PickerStyle.foreground.opacity(0.45))
                    .accessibilityHidden(true)
            }
            if !isAgent && item.isPinned == true {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(selected ? PickerStyle.selectionText.opacity(0.85) : PickerStyle.selection)
                    .accessibilityLabel("Pinned")
            }
            if isAgent {
                AgentIcon(app: item.app)
                    .frame(width: 16, height: 16).accessibilityHidden(true)
                Text(item.label ?? item.agentID ?? "Agent")
                    .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                ActivityIndicator(activity: item.activity)
                Spacer(minLength: 8)
                if !item.agentContext.isEmpty {
                    Text(item.agentContext)
                        .font(.system(size: 10))
                        .foregroundStyle(selected ? PickerStyle.selectionText.opacity(0.7) : PickerStyle.secondaryText)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: 220, alignment: .trailing)
                        .layoutPriority(2)
                }
                if let age = item.updatedAge() {
                    Text(age)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(selected ? PickerStyle.selectionText.opacity(0.7) : PickerStyle.secondaryText)
                        .fixedSize()
                        .help(item.updatedAt ?? "")
                }
            } else if let branch = item.branch {
                Text(branch + (item.isMain == true ? " · primary" : ""))
                    .lineLimit(selected ? 2 : 1).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(displayPath(item.path))
                    .lineLimit(1).truncationMode(.middle)
            }
            if !isAgent { ActivityIndicator(activity: item.activity) }
            if selected && !isAgent {
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .font(.system(size: PickerStyle.rowFontSize, weight: selected ? .medium : .regular))
        .foregroundStyle(selected ? PickerStyle.selectionText : PickerStyle.foreground)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PickerStyle.rowInset)
        .frame(height: isAgent ? PickerStyle.agentRowHeight : (model.page == .worktrees && model.view == .repos ? PickerStyle.worktreeRowHeight * CGFloat(selected ? PickerStyle.branchLines(for: item) : 1) : PickerStyle.rowHeight))
        .background {
            if selected { RoundedRectangle(cornerRadius: 9).fill(PickerStyle.selectionBackground) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard !model.busy, !model.loading else { return }
            model.selectedID = item.id
            model.choose()
        }
        .onTapGesture {
            guard !model.busy, !model.loading else { return }
            model.selectedID = item.id
        }
        .help(isAgent ? [item.agentHelp, item.updatedAt].compactMap { $0 }.joined(separator: " · ") : item.path + (item.active == true ? " · Current pane" : ""))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isAgent ? item.agentAccessibility : displayPath(item.path) + (item.branch.map { ", branch \($0)" } ?? "") + (item.activityAccessibility.isEmpty ? "" : ", " + item.activityAccessibility))
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("path-row:\(item.path)")
        .accessibilityAction { model.selectedID = item.id; model.choose() }
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

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            pathRow("Repo", value: model.repo.map(displayPath) ?? "Loading…", path: model.repo)
            HStack(spacing: 10) {
                formLabel("Branch")
                TextField("feat/my-change", text: Binding(get: { model.branch }, set: { model.editBranch($0) }))
                    .disableAutocorrection(true)
                    .textFieldStyle(.plain).padding(.horizontal, 9)
                    .frame(height: PickerStyle.controlHeight)
                    .background(field == .branch ? PickerStyle.fieldBackground : PickerStyle.foreground.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(field == .branch ? PickerStyle.selection : PickerStyle.foreground.opacity(0.1)))
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
                    .background(field == .base ? PickerStyle.fieldBackground : PickerStyle.foreground.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(field == .base ? PickerStyle.selection : PickerStyle.foreground.opacity(0.1)))
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

    private func pathRow(_ title: String, value: String, path: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            formLabel(title)
            Text(value).font(.system(size: 12)).foregroundStyle(PickerStyle.secondaryText)
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(path ?? value)
                .accessibilityIdentifier(title == "Repo" ? "create-repo" : "create-destination")
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
            HStack(spacing: 10) {
                Text(createActionLabel).fontWeight(.semibold)
                Text("⌘↵").foregroundStyle(PickerStyle.secondaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: PickerStyle.controlHeight)
            .background(PickerStyle.selection.opacity(0.25), in: Capsule())
            .overlay(Capsule().strokeBorder(PickerStyle.selection.opacity(field == .submit ? 0.9 : 0.4)))
            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .focusable().focused($field, equals: .submit)
        .keyboardShortcut(.return, modifiers: .command)
        .onKeyPress(.return) {
            if model.canSubmitForm { model.create() }
            return .handled
        }
        .disabled(!model.canSubmitForm)
        .opacity(model.canSubmitForm ? 1 : 0.45)
        .accessibilityLabel(createActionLabel)
        .accessibilityIdentifier(model.createdPath == nil ? "create-submit" : "open-created")
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
        guard model.page == .create, !model.busy, !model.basePickerPresented else { return }
        var fields: [Field] = model.createdPath == nil ? (model.loading ? [.branch] : [.branch, .base]) : []
        if !model.targets.isEmpty { fields.append(.target) }
        if model.canSubmitForm { fields.append(.submit) }
        let current = fields.firstIndex(of: field ?? .branch) ?? (backward ? 0 : -1)
        field = fields[(current + (backward ? fields.count - 1 : 1)) % fields.count]
    }

    @ViewBuilder private var status: some View {
        if let error = model.error {
            Text(error).foregroundStyle(.red).accessibilityIdentifier("picker-error")
                .font(.system(size: 11)).lineLimit(2).textSelection(.enabled).help(error)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 4)
        } else if let notice = model.notice {
            Text(notice).foregroundStyle(PickerStyle.secondaryText).accessibilityIdentifier("picker-notice")
                .font(.system(size: 11)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 4)
        }
    }

    private var isListPage: Bool { model.page == .directories || model.page == .worktrees }

    private var footer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                if model.splitMode {
                    Text("Split ⌃P   j↓  l→").accessibilityIdentifier("keyboard-hint")
                } else if model.view == .agents {
                    EmptyView()
                } else if model.page == .repositories {
                    Text("Choose repository").foregroundStyle(PickerStyle.secondaryText)
                } else if model.page == .create {
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
                if model.view == .agents {
                    Button("↵ Switch") { model.choose() }.disabled(!model.canOpen)
                        .accessibilityIdentifier("open-selected")
                } else if isListPage && !model.splitMode { listActions }
                if model.page == .create { createSubmitButton }
                if model.page == .repositories {
                    Button("Choose ↵") { model.choose() }
                        .disabled(model.selected == nil || model.busy || model.loading)
                        .accessibilityIdentifier("open-selected")
                }
            }
            .frame(height: PickerStyle.footerHeight)
        }
        .font(.system(size: 11)).foregroundStyle(PickerStyle.foreground.opacity(0.65))
        .lineLimit(1)
        .buttonStyle(.plain)
        .padding(.horizontal, PickerStyle.horizontalInset)
        .frame(height: PickerStyle.footerHeight)
        .overlay(alignment: .top) {
            if model.page != .create { Divider().overlay(PickerPalette.stroke) }
        }
    }

    private var listActions: some View {
        HStack(spacing: 12) {
            Button("↵ Open") { model.choose() }.disabled(!model.canOpen)
                .accessibilityIdentifier("open-selected")
            Button("⌃P Split") { model.toggleSplit() }.disabled(!model.canOpen)
                .accessibilityIdentifier("toggle-split")
            if model.page == .directories {
                Button("⌃T Worktrees") { model.showWorktrees() }
                    .disabled(model.busy || model.loading || model.selected == nil)
                    .accessibilityIdentifier("show-worktrees")
            } else {
                Button("⌃X Remove") { model.askRemove() }
                    .disabled(model.busy || model.loading || model.selected?.isMain != false)
                    .accessibilityIdentifier("remove-worktree")
            }
        }
        .font(.system(size: 10))
        .fixedSize()
        .accessibilityIdentifier("list-actions")
    }

    private var openTargetControl: some View {
        HStack(spacing: model.page == .create ? 10 : 6) {
            if model.page == .create { formLabel("Open in") }
            else { Text("Open in:").font(.system(size: 11)).foregroundStyle(PickerStyle.foreground.opacity(0.75)) }
            Button {
                guard !model.targetPickerPresented else { return }
                model.targetPickerPresented = true
            } label: {
                HStack(spacing: 6) {
                    Text(PickerModel.targetLabel(model.target))
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                }
                .font(.system(size: model.page == .create ? PickerStyle.bodyFontSize : 11, weight: .medium))
                .foregroundStyle(PickerStyle.foreground.opacity(0.85))
                .padding(.horizontal, 8)
                .frame(height: model.page == .create ? PickerStyle.controlHeight : 22)
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
            if model.page != .create {
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

    private var emptyMessage: String {
        if model.view == .agents { return "No matching agents" }
        switch model.page {
        case .worktrees: return "No matching worktrees"
        case .repositories: return "No matching repositories"
        default: return "No matching directories"
        }
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
