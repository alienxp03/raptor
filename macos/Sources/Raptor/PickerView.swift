import SwiftUI

struct PickerView: View {
    @ObservedObject var model: PickerModel
    @FocusState private var field: Field?
    @State private var baseReturnFocus: Field = .base
    private enum Field { case search, branch, base, target, submit }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.page == .create { createForm } else { results }
            status
            footer
        }
        .font(.system(size: PickerStyle.bodyFontSize))
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
                        Text("New worktree").font(.system(size: PickerStyle.titleFontSize, weight: .semibold))
                        if model.options.demo { demoBadge }
                        Spacer()
                    }
                }
                .padding(.horizontal, PickerStyle.horizontalInset)
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
                .frame(height: PickerStyle.controlHeight)
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
        return HStack(spacing: 14) {
            if let branch = item.branch {
                Text(branch + (item.isMain == true ? " · primary" : ""))
                    .fontWeight(selected ? .medium : .regular)
                    .frame(width: PickerStyle.width * 0.36, alignment: .leading)
                Text(displayPath(item.path)).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else if item.current == true {
                Text(item.label ?? "Current repo").fontWeight(.medium)
                Text(displayPath(item.path)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Text(displayPath(item.path))
            }
        }
        .font(.system(size: PickerStyle.bodyFontSize))
        .foregroundStyle(.primary)
        .lineLimit(1).truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 5)
        .frame(height: model.page == .worktrees ? PickerStyle.worktreeRowHeight : PickerStyle.rowHeight)
        .background {
            if selected { RoundedRectangle(cornerRadius: 6).fill(PickerStyle.selection.opacity(0.13)) }
        }
        .overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: 1).fill(PickerStyle.selection)
                    .frame(width: 2, height: 16).padding(.leading, 3)
            }
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
        .accessibilityLabel((item.current == true ? (item.label ?? "Current repo") + ", " : "") + displayPath(item.path) + (item.branch.map { ", branch \($0)" } ?? ""))
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("path-row:\(item.path)")
        .accessibilityAction { model.selectedID = item.id; model.choose() }
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            pathRow("Repo", value: model.repo.map(displayPath) ?? "Loading…", path: model.repo)
            HStack(spacing: 10) {
                formLabel("Branch")
                TextField("feat/my-change", text: $model.branch)
                    .disableAutocorrection(true)
                    .textFieldStyle(.plain).padding(.horizontal, 9)
                    .frame(height: PickerStyle.controlHeight)
                    .background(field == .branch ? PickerStyle.selection.opacity(0.18) : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(field == .branch ? PickerStyle.selection : Color.primary.opacity(0.12)))
                    .focused($field, equals: .branch)
                    .task { await Task.yield(); field = .branch }
                    .onSubmit { presentBasePicker() }
                    .disabled(model.createdPath != nil)
                    .accessibilityLabel("New branch name").accessibilityIdentifier("create-branch")
            }
            HStack(spacing: 10) {
                formLabel("Base")
                Button { presentBasePicker() } label: {
                    HStack {
                        Text(model.base.isEmpty ? "Choose a local branch…" : model.base)
                            .foregroundStyle(model.base.isEmpty ? Color.secondary : Color.primary)
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: PickerStyle.controlHeight)
                    .background(field == .base ? PickerStyle.selection.opacity(0.18) : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(field == .base ? PickerStyle.selection : Color.primary.opacity(0.12)))
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
        Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            .frame(width: 90, alignment: .leading)
    }

    private func pathRow(_ title: String, value: String, path: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            formLabel(title)
            Text(value).font(.system(size: 12)).foregroundStyle(.secondary)
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
                Text("⌘↵").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: PickerStyle.controlHeight)
            .background(PickerStyle.selection.opacity(0.22), in: Capsule())
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
            if model.page == .create { createSubmitButton }
            if !model.splitMode && model.page != .create {
                if model.page == .directories || model.page == .worktrees {
                    listActions
                    Button { model.beginCreate() } label: {
                        HStack(spacing: 8) {
                            Text("New").fontWeight(.medium)
                            Text("⌃N").foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: PickerStyle.controlHeight)
                        .background(PickerStyle.selection.opacity(0.13), in: Capsule())
                        .overlay(Capsule().strokeBorder(PickerStyle.selection.opacity(0.3)))
                    }
                    .disabled(model.busy || model.loading || model.selected == nil)
                    .help("Create a worktree for the selected repository. Ctrl+N or Cmd+N.")
                    .accessibilityIdentifier("new-worktree")
                } else if model.page == .repositories {
                    Button("Choose ↵") { model.choose() }
                        .disabled(model.selected == nil || model.busy || model.loading)
                        .accessibilityIdentifier("open-selected")
                }
            }
        }
        .font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.65))
        .lineLimit(1)
        .buttonStyle(.plain)
        .padding(.horizontal, PickerStyle.horizontalInset)
        .frame(height: PickerStyle.footerHeight)
        .overlay(alignment: .top) {
            if model.page != .create { Divider().opacity(0.4) }
        }
    }

    private var listActions: some View {
        Menu {
            Button("Open ↵") { model.choose() }.disabled(!model.canOpen)
            Button("Split pane ⌃P") { model.toggleSplit() }.disabled(!model.canOpen)
            if model.page == .directories {
                Button("Worktrees ⌃T") { model.showWorktrees() }
                    .disabled(model.busy || model.loading || model.selected == nil)
            } else {
                Button("Remove worktree… ⌃X") { model.askRemove() }
                    .disabled(model.busy || model.loading || model.selected?.isMain != false)
            }
            Divider()
            Button(model.page == .directories ? "Close Esc" : "Back Esc") { model.escape() }
                .disabled(model.busy)
        } label: {
            Image(systemName: "ellipsis").frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .fixedSize().help("More actions")
        .accessibilityLabel("More actions")
        .accessibilityIdentifier("list-actions")
    }

    private var openTargetControl: some View {
        HStack(spacing: model.page == .create ? 10 : 6) {
            if model.page == .create { formLabel("Open in") }
            else { Text("Open in:").font(.system(size: 12)).foregroundStyle(Color.primary.opacity(0.65)) }
            Menu {
                ForEach(model.targets, id: \.self) { value in
                    Button(PickerModel.targetLabel(value)) { model.target = value }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(PickerModel.targetLabel(model.target))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: PickerStyle.bodyFontSize, weight: .medium)).foregroundStyle(Color.primary)
                .padding(.horizontal, model.page == .create ? 0 : 7)
                .frame(height: PickerStyle.controlHeight)
                .background(model.page == .create && field == .target ? PickerStyle.selection.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(field == .target ? PickerStyle.selection.opacity(0.6) : Color.clear))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .focusable().focused($field, equals: .target)
            .focusEffectDisabled()
            .fixedSize().disabled(model.busy || model.targets.isEmpty)
            .help("Choose where to open. Press Ctrl+O or Ctrl+Shift+O to change.")
            .accessibilityLabel("Open in: \(PickerModel.targetLabel(model.target))")
            .accessibilityIdentifier("open-target")
            if model.page != .create {
                Text("⌃O").font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.55))
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
        switch model.page {
        case .worktrees: return "No matching worktrees"
        case .repositories: return "No matching repositories"
        default: return "No matching directories"
        }
    }
}
