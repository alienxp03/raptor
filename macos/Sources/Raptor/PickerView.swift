import SwiftUI

struct PickerView: View {
    @ObservedObject var model: PickerModel
    @FocusState private var field: Field?
    @State private var baseReturnFocus: Field = .base
    private enum Field { case search, branch, base, target, cancel, submit }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.page == .create { createForm } else { results }
            status
            footer
        }
        .font(.system(size: 14))
        .frame(width: PickerStyle.width, height: PickerStyle.height(for: model))
        .pickerGlass()
        .tint(PickerStyle.selection)
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
            field = page == .create ? .branch : .search
        }
        .alert("Remove worktree?", isPresented: Binding(
            get: { model.removalCandidate != nil },
            set: { if !$0 { model.removalCandidate = nil } }
        ), presenting: model.removalCandidate) { candidate in
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
                        Text("Create worktree").font(.system(size: 16, weight: .semibold))
                        if model.options.demo { demoBadge }
                        Spacer()
                    }
                    Text(displayPath(model.repo ?? ""))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(model.repo ?? "")
                }
                .padding(.horizontal, 16)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(searchPrompt, text: $model.query)
                        .textFieldStyle(.plain)
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
                .frame(height: 30)
                .background(.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.045)))
                .padding(.horizontal, 5)
            }
        }
        .frame(height: model.page == .create ? PickerStyle.createHeaderHeight : PickerStyle.searchHeight)
    }

    private var searchPrompt: String {
        switch model.page {
        case .repositories: return "Search repositories…"
        case .worktrees: return "Search worktrees…"
        default: return "Search directories…"
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.items) { item in row(item).id(item.id) }
                }
                .padding(.horizontal, 5).padding(.vertical, 4)
            }
            .overlay {
                if model.items.isEmpty {
                    Text(model.loading ? "Loading…" : (model.error == nil ? emptyMessage : "No results"))
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: model.selectedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityIdentifier("picker-results")
    }

    private func row(_ item: PickerItem) -> some View {
        let selected = model.selectedID == item.id
        let primary = selected ? Color.black.opacity(0.9) : Color.primary
        return VStack(alignment: .leading, spacing: 2) {
            if let branch = item.branch {
                Text(branch + (item.isMain == true ? " · primary" : ""))
                    .foregroundStyle(primary)
                Text(displayPath(item.path)).font(.system(size: 12))
                    .foregroundStyle(selected ? Color.black.opacity(0.6) : Color.secondary)
            } else {
                Text(displayPath(item.path)).foregroundStyle(primary)
            }
        }
        .lineLimit(1).truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .frame(height: model.page == .worktrees ? PickerStyle.worktreeRowHeight : PickerStyle.rowHeight)
        .background {
            if selected { RoundedRectangle(cornerRadius: 8).fill(PickerStyle.selection) }
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
        .help(item.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displayPath(item.path) + (item.branch.map { ", branch \($0)" } ?? ""))
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("path-row:\(item.path)")
        .accessibilityAction { model.selectedID = item.id; model.choose() }
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Branch name").font(.system(size: 12, weight: .medium)).foregroundStyle(.primary.opacity(0.65))
                TextField("feat/my-change", text: $model.branch)
                    .disableAutocorrection(true)
                    .textFieldStyle(.plain).padding(.horizontal, 9).padding(.vertical, 7)
                    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(field == .branch ? PickerStyle.selection : Color.primary.opacity(0.12)))
                    .focused($field, equals: .branch)
                    .task { await Task.yield(); field = .branch }
                    .onSubmit { presentBasePicker() }
                    .disabled(model.createdPath != nil)
                    .accessibilityLabel("New branch name").accessibilityIdentifier("create-branch")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("From branch").font(.system(size: 12, weight: .medium)).foregroundStyle(.primary.opacity(0.65))
                Button { presentBasePicker() } label: {
                    HStack {
                        Text(model.base.isEmpty ? "Choose a local branch…" : model.base)
                            .foregroundStyle(model.base.isEmpty ? Color.secondary : Color.primary)
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(field == .base ? PickerStyle.selection : Color.primary.opacity(0.12)))
                }
                .buttonStyle(.plain).focusable().focused($field, equals: .base)
                .onKeyPress(.return) { presentBasePicker(); return .handled }
                .disabled(model.createdPath != nil)
                .help("Search local branches. Enter selects a branch.")
                .accessibilityLabel("From branch: \(model.base)")
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
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.createdPath == nil ? "Destination" : "Created at")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.primary.opacity(0.65))
                    HStack(alignment: .top, spacing: 8) {
                        Text(destinationLabel)
                            .font(.system(size: 12)).foregroundStyle(model.destination == nil && model.createdPath == nil ? Color.secondary : Color.primary)
                            .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                            .frame(maxWidth: .infinity, minHeight: 16, alignment: .topLeading)
                        if !model.branch.isEmpty && !model.previewReady && model.createdPath == nil {
                            ProgressView().controlSize(.mini).accessibilityLabel("Checking destination")
                        }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("create-destination")
                    .help(model.createdPath ?? model.destination ?? "")
                    if !model.branch.isEmpty, model.previewReady, let validation = model.validationError {
                        Text(validation).font(.system(size: 12)).foregroundStyle(.orange).lineLimit(2)
                            .accessibilityIdentifier("create-validation")
                    }
                }
                HStack {
                    openTargetControl
                    Spacer()
                    Text("⌃O").font(.system(size: 11)).foregroundStyle(.secondary)
                        .help("Ctrl+O changes the open target")
                }
            }
            HStack {
                Button(model.createdPath == nil ? "Cancel" : "Back") { model.escape() }
                    .buttonStyle(.plain).focusable().focused($field, equals: .cancel)
                    .onKeyPress(.return) { model.escape(); return .handled }
                    .accessibilityIdentifier("create-back")
                Spacer()
                Button { model.create() } label: {
                    HStack(spacing: 8) {
                        Text(createActionLabel)
                        Text("⌘↵").font(.system(size: 11)).opacity(0.75)
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.regular)
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
            .padding(.top, 2)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .disabled(model.busy).frame(maxHeight: .infinity, alignment: .top)
    }

    private var destinationLabel: String {
        if let path = model.createdPath ?? model.destination { return displayPath(path) }
        return model.branch.isEmpty ? "Enter a branch name to preview its location." : "Checking destination…"
    }

    private var createActionLabel: String {
        if model.busy { return model.createdPath == nil ? "Creating…" : "Opening…" }
        if model.createdPath != nil { return model.error == nil ? "Open worktree" : "Retry opening" }
        return "Create"
    }

    private func presentBasePicker() {
        baseReturnFocus = .base
        field = .base
        model.basePickerPresented = true
    }

    private func advanceFormFocus(backward: Bool) {
        guard model.page == .create, !model.busy, !model.basePickerPresented else { return }
        var fields: [Field] = model.createdPath == nil ? [.branch, .base] : []
        if !model.targets.isEmpty { fields.append(.target) }
        fields.append(.cancel)
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
            Text(notice).foregroundStyle(.secondary).accessibilityIdentifier("picker-notice")
                .font(.system(size: 11)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 4)
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            if model.splitMode {
                Text("Split ⌃P   h←  j↓  k↑  l→").accessibilityIdentifier("keyboard-hint")
            } else if model.page == .repositories {
                Text("Choose repository").foregroundStyle(.secondary)
            } else if model.page == .create {
                Text("Tab fields · ⌃O target").accessibilityIdentifier("keyboard-hint")
            } else {
                openTargetControl
            }
            Spacer(minLength: 0)
            if !model.splitMode {
                if model.page == .directories || model.page == .worktrees {
                    Button("Split ⌃P") { model.toggleSplit() }
                        .disabled(!model.canOpen)
                        .help("Ctrl+P, then H/J/K/L or an arrow to split. Esc cancels.")
                        .accessibilityLabel("Split pane, Control P")
                        .accessibilityIdentifier("toggle-split")
                }
                if model.page == .directories {
                    Button("Worktrees ⌃T") { model.showWorktrees() }
                        .disabled(model.busy || model.loading).accessibilityIdentifier("show-worktrees")
                } else if model.page == .worktrees {
                    Button("New ⌘N") { model.beginCreate() }
                        .disabled(model.busy || model.loading).accessibilityIdentifier("new-worktree")
                    Button("Remove…") { model.askRemove() }
                        .disabled(model.busy || model.loading || model.selected?.isMain != false)
                        .accessibilityIdentifier("remove-worktree")
                }
                if model.page != .create {
                    Button("↵") { model.choose() }
                        .disabled(model.page == .repositories ? model.selected == nil || model.busy || model.loading : !model.canOpen)
                        .help("Open selected location").accessibilityLabel("Open selected location")
                        .accessibilityIdentifier("open-selected")
                }
            }
            Button("Esc") { model.escape() }
                .help(model.page == .directories ? "Close picker" : "Back")
                .disabled(model.busy).accessibilityIdentifier("close-picker")
        }
        .font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.65))
        .lineLimit(1)
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .frame(height: PickerStyle.footerHeight)
        .overlay(alignment: .top) { Divider().opacity(0.4) }
    }

    private var openTargetControl: some View {
        HStack(spacing: 6) {
            Text("Open in:").font(.system(size: 12)).foregroundStyle(Color.primary.opacity(0.65))
            Menu {
                ForEach(model.targets, id: \.self) { value in
                    Button(PickerModel.targetLabel(value)) { model.target = value }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(PickerModel.targetLabel(model.target))
                    if model.page != .create { Text("⌃O").font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.55)) }
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: model.page == .create ? 13 : 12, weight: .medium)).foregroundStyle(Color.primary)
                .padding(.horizontal, model.page == .create ? 0 : 7)
                .padding(.vertical, model.page == .create ? 0 : 4)
                .background(Color.primary.opacity(model.page == .create ? 0 : 0.08), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(model.page == .create ? 0 : 0.08)))
            }
            .menuIndicator(.hidden)
            .focusable().focused($field, equals: .target)
            .fixedSize().disabled(model.busy || model.targets.isEmpty)
            .help("Choose where to open. Press Ctrl+O or Ctrl+Shift+O to change.")
            .accessibilityLabel("Open in: \(PickerModel.targetLabel(model.target))")
            .accessibilityIdentifier("open-target")
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
        switch model.page {
        case .worktrees: return "No matching worktrees"
        case .repositories: return "No matching repositories"
        default: return "No matching directories"
        }
    }
}
