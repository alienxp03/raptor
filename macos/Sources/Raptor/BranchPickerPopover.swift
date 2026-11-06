import SwiftUI

@MainActor
struct BranchPickerPopover: View {
    let current: String
    let initialBranches: [String]
    let search: @MainActor (String) async throws -> [String]
    let choose: @MainActor (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var branches: [String]
    @State private var selected: String?
    @State private var resultsQuery = ""
    @State private var loading = true
    @State private var hasSearched = false
    @State private var error: String?

    init(current: String, initialBranches: [String],
         search: @escaping @MainActor (String) async throws -> [String],
         choose: @escaping @MainActor (String) -> Void) {
        self.current = current
        self.initialBranches = initialBranches
        self.search = search
        self.choose = choose
        _branches = State(initialValue: initialBranches)
        _selected = State(initialValue: initialBranches.contains(current) ? current : initialBranches.first)
    }

    // Keep cached choices usable during the opening refresh, but never show
    // choices from a different query while a new search is pending.
    private var visibleBranches: [String] { resultsQuery == query ? branches : [] }
    private var isLoading: Bool { loading || resultsQuery != query }
    private var visibleError: String? { resultsQuery == query ? error : nil }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search local branches…", text: $query)
                .disableAutocorrection(true)
                .textFieldStyle(.plain)
                .font(.system(size: PickerStyle.rowFontSize))
                .focused($searchFocused)
                .accessibilityLabel("Search local base branches")
                .accessibilityIdentifier("base-search")
                .onSubmit {} // Never submit the worktree form beneath this popover.
                .onKeyPress(keys: [.upArrow, .downArrow, .return, .escape],
                            phases: [.down, .repeat], action: handleKey)
                .padding(.horizontal, 9)
                .frame(height: PickerStyle.searchFieldHeight)
                .background(PickerStyle.fieldBackground, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, PickerStyle.listInset)
                .padding(.vertical, 8)
            Divider().opacity(0.4)
            results
            if let visibleError {
                Text("Could not load branches: \(visibleError)")
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: 44)
                    .help(visibleError)
                    .accessibilityIdentifier("base-error")
            }
        }
        .font(.system(size: PickerStyle.bodyFontSize))
        .foregroundStyle(PickerStyle.foreground)
        .frame(width: 360, height: popoverHeight)
        .pickerGlass()
        .tint(PickerStyle.selection)
        .submitScope()
        .onKeyPress(keys: [.upArrow, .downArrow, .return, .escape],
                    phases: [.down, .repeat], action: handleKey)
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            searchFocused = true
        }
        .task(id: query) { await refresh(query) }
    }

    private var popoverHeight: CGFloat {
        let rows = visibleBranches.isEmpty ? 2 : visibleBranches.count
        return min(280, PickerStyle.searchFieldHeight + 12 + 8 + CGFloat(rows) * PickerStyle.rowHeight + (visibleError == nil ? 0 : 36))
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleBranches, id: \.self) { branch in
                        branchRow(branch).id(branch)
                    }
                }
                .padding(.horizontal, PickerStyle.listInset)
                .padding(.vertical, 4)
            }
            .overlay {
                if visibleBranches.isEmpty {
                    if isLoading {
                        VStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading local branches…")
                        }
                        .foregroundStyle(PickerStyle.secondaryText)
                    } else if visibleError == nil {
                        Text(query.isEmpty ? "No local branches" : "No matching local branches")
                            .foregroundStyle(PickerStyle.secondaryText)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if isLoading && !visibleBranches.isEmpty {
                    ProgressView().controlSize(.mini)
                        .padding(8)
                        .accessibilityLabel("Refreshing local branches")
                        .allowsHitTesting(false)
                }
            }
            .onAppear { if let selected { proxy.scrollTo(selected) } }
            .onChange(of: selected) { _, branch in
                if let branch { proxy.scrollTo(branch) }
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityIdentifier("base-results")
    }

    private func branchRow(_ branch: String) -> some View {
        let isSelected = selected == branch
        return Button { accept(branch) } label: {
            Text(branch)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.system(size: PickerStyle.rowFontSize, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? PickerStyle.selectionText : PickerStyle.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PickerStyle.rowInset)
                .frame(height: PickerStyle.rowHeight)
                .background {
                    if isSelected { RoundedRectangle(cornerRadius: 6).fill(PickerStyle.selection) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(branch)
        .accessibilityLabel(branch)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityIdentifier("base-option:\(branch)")
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .upArrow: move(-1)
        case .downArrow: move(1)
        case .return:
            if press.phase == .down, let selected, visibleBranches.contains(selected) { accept(selected) }
        case .escape:
            if press.phase == .down { dismiss() }
        default: return .ignored
        }
        // Consume Return even without a result. It must not reach the parent.
        return .handled
    }

    private func move(_ delta: Int) {
        let choices = visibleBranches
        guard !choices.isEmpty else { return }
        guard let selected, let index = choices.firstIndex(of: selected) else {
            self.selected = delta < 0 ? choices.last : choices.first
            return
        }
        self.selected = choices[min(max(index + delta, 0), choices.count - 1)]
    }

    private func accept(_ branch: String) {
        guard visibleBranches.contains(branch) else { return }
        selected = branch
        choose(branch) // The parent owns selection and dismissal.
    }

    private func refresh(_ requestedQuery: String) async {
        let debounce = hasSearched
        hasSearched = true
        loading = true
        error = nil
        do {
            if debounce { try await Task.sleep(for: .milliseconds(100)) }
            try Task.checkCancellation()
            let choices = try await search(requestedQuery)
            // Some backends do not stop work on cancellation.
            guard !Task.isCancelled, query == requestedQuery else { return }
            branches = choices
            resultsQuery = requestedQuery
            if let selected, choices.contains(selected) {
                self.selected = selected
            } else {
                selected = choices.contains(current) ? current : choices.first
            }
            loading = false
        } catch {
            guard !Task.isCancelled, query == requestedQuery else { return }
            if resultsQuery != requestedQuery {
                branches = []
                selected = nil
            }
            resultsQuery = requestedQuery
            self.error = error.localizedDescription
            loading = false
        }
    }
}
