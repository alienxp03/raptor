import Foundation
import RaptorPaths
import RaptorRex
import RaptorWorktree

struct WorktreeReviewRow: Equatable {
    var repo: String
    var path: String
    var branch: String
    var error: String?
    var isPrimary = false
    var checked = true
    var prepared = true
    var metadata: WorktreeReviewIdentity?
    var plan: DeletionPlan?

    var eligible: Bool {
        checked && error == nil && !repo.isEmpty && !path.isEmpty && !branch.isEmpty && !isPrimary
    }

    var json: JS {
        var fields: [(String, JS)] = [("repo", .string(repo)), ("path", .string(path)),
                                    ("branch", .string(branch)), ("is_primary", .bool(isPrimary)),
                                    ("needs_force", .bool(plan?.needsForce ?? false)), ("checked", .bool(checked)),
                                    ("prepared", .bool(prepared))]
        if let plan {
            fields += [("has_changes", .bool(plan.hasChanges)),
                       ("has_ignored_files", .bool(plan.hasIgnoredFiles)),
                       ("has_unmerged_commits", .bool(plan.unmerged))]
        }
        if let error { fields.append(("error", .string(error))) }
        return .object(fields)
    }
}

struct WorktreeReviewTicket {
    var host: String
    var session: DeletionSessionState
    var rows: [WorktreeReviewRow]
    var expires: Date
    var forceSelection: Set<String>?
    // Immutable source membership; never infer Git identity from path prefixes.
    var discoveryPaths: Set<String> = []
    var sourceRows: [String: WorktreeReviewRow] = [:]
    var pending: Set<String> = []
    var metadataOnly = false
    var frozenSelection: Set<String>?
    var metadataRows: [WorktreeReviewRow]?
}

extension Handler {
    func protectNestedCheckouts(_ rows: [WorktreeReviewRow]) -> [WorktreeReviewRow] {
        rows.map { original in
            var row = original
            if row.error == nil, !row.path.isEmpty,
               let nested = rows.first(where: { $0.path.hasPrefix(row.path + "/") }) {
                row.error = "Cannot delete this worktree: it contains `\(nested.path)`."
                row.plan = nil
            }
            return row
        }
    }

    func accumulatedReviewRows(_ ticket: WorktreeReviewTicket) -> [WorktreeReviewRow] {
        var rows: [String: WorktreeReviewRow] = [:]
        for source in ticket.discoveryPaths.sorted() {
            let row = ticket.sourceRows[source] ?? WorktreeReviewRow(repo: "", path: source, branch: "", checked: false, prepared: false)
            // An unresolved source with the exact same path still needs its check.
            if rows[row.path] == nil || !row.checked ||
                (rows[row.path]?.checked == true && (row.plan != nil ||
                    (row.eligible && rows[row.path]?.eligible != true) ||
                    (row.metadata != nil && rows[row.path]?.metadata == nil))) {
                rows[row.path] = row
            }
        }
        let sorted = rows.values.sorted { $0.path < $1.path }
        return ticket.pending.isEmpty ? protectNestedCheckouts(sorted) : sorted
    }

    func checkWorktreeReview(_ ticket: inout WorktreeReviewTicket, path: String, metadataOnly: Bool = false) throws {
        guard ticket.frozenSelection == nil else { throw MessageError("Preparation started; selection and metadata are frozen") }
        guard !ticket.metadataOnly || metadataOnly else { throw MessageError("Use metadata_only for this preview") }
        if metadataOnly {
            guard !ticket.sourceRows.values.contains(where: { $0.plan != nil }) else {
                throw MessageError("Check mode changed; preview again")
            }
            ticket.metadataOnly = true
        }
        let source: String
        if ticket.discoveryPaths.contains(path) { source = path }
        else if let original = ticket.discoveryPaths.sorted().first(where: { ticket.sourceRows[$0]?.path == path }) {
            source = original
        } else { throw MessageError("Path is not in this preview") }
        // Completed plans are immutable, including after a Force offer.
        if let row = ticket.sourceRows[source], row.plan != nil || row.isPrimary ||
            (metadataOnly && row.metadata != nil && row.error == nil) { return }
        let run = deletionRunner(ticket.host, ticket.session.sessionID, ticket.session.hostID)
        var row = WorktreeReviewRow(repo: "", path: source, branch: "", prepared: !metadataOnly)
        do {
            guard source.hasPrefix("/"), !source.contains("\0") else { throw MessageError("Unknown directory") }
            let root = try run(source, "git", ["rev-parse", "--show-toplevel"])
            let resolved = root.stdout.trimmingCharacters(in: .newlines)
            guard root.ok, resolved.hasPrefix("/"), !resolved.contains("\0") else {
                throw MessageError(root.stderr.isEmpty ? "Not a known Git worktree" : root.stderr)
            }
            row.path = resolved
            if let cached = ticket.sourceRows.values.first(where: {
                $0.path == resolved && ($0.plan != nil || $0.isPrimary || (metadataOnly && $0.metadata != nil && $0.error == nil))
            }) {
                row = cached
            } else {
                row = metadataOnly ? inspectReviewMetadata(resolved, run: run) : try inspectReviewRoot(resolved, run: run)
            }
        } catch { row.error = String(describing: error) }
        ticket.sourceRows[source] = row
        ticket.pending.remove(source)
        ticket.rows = accumulatedReviewRows(ticket)
    }

    func inspectReviewRoot(_ path: String, run: DeletionCommand) throws -> WorktreeReviewRow {
        var row = WorktreeReviewRow(repo: "", path: path, branch: "")
        do {
            let listing = try run(path, "git", ["worktree", "list", "--porcelain", "-z"])
            guard listing.ok else { throw MessageError(listing.stderr.isEmpty ? "Cannot inspect worktree" : listing.stderr) }
            let records = listing.stdout.components(separatedBy: "\0\0").map { $0.components(separatedBy: "\0") }
            if let primary = records.first?.first, primary.hasPrefix("worktree ") {
                row.repo = String(primary.dropFirst(9))
                row.isPrimary = row.repo == path
            }
            if let record = records.first(where: { $0.first == "worktree " + path }),
               let ref = record.first(where: { $0.hasPrefix("branch refs/heads/") }) {
                row.branch = String(ref.dropFirst("branch refs/heads/".count))
            }
            if row.isPrimary {
                row.error = row.branch.isEmpty ? "Cannot delete this checkout." : "Cannot delete branch `\(row.branch)`."
            } else {
                let plan = try WorktreeKit.inspectDeletion(cwd: path, run: run)
                row.repo = plan.repo
                row.branch = plan.branch
                row.plan = plan
            }
        } catch { row.error = String(describing: error) }
        return row
    }

    func inspectWorktreeReview(_ host: String, _ sid: String) throws -> (DeletionSessionState, [WorktreeReviewRow]) {
        let state = try loadDeletionSession?(host, sid) ?? Rex.deletionSessionState(host, sid)
        let run = deletionRunner(host, sid, state.hostID)
        var rows: [String: WorktreeReviewRow] = [:]
        for cwd in Set(state.directories).sorted() {
            var row = WorktreeReviewRow(repo: "", path: cwd, branch: "")
            do {
                guard cwd.hasPrefix("/"), !cwd.contains("\0") else { throw MessageError("Unknown directory") }
                let root = try run(cwd, "git", ["rev-parse", "--show-toplevel"])
                let path = root.stdout.trimmingCharacters(in: .newlines)
                guard root.ok, path.hasPrefix("/"), !path.contains("\0") else {
                    throw MessageError(root.stderr.isEmpty ? "Not a known Git worktree" : root.stderr)
                }
                row.path = path
                if rows[path] != nil { continue }
                row = try inspectReviewRoot(path, run: run)
            } catch {
                row.error = String(describing: error)
            }
            rows[row.path] = row
        }
        if rows.isEmpty {
            rows[""] = WorktreeReviewRow(repo: "", path: "", branch: "", error: "Unknown session directory")
        }
        // Removing a parent directory would also remove a nested checkout,
        // even when that nested row is protected or left unselected.
        return (state, protectNestedCheckouts(rows.values.sorted { $0.path < $1.path }))
    }

    func reviewSessionDeletion(_ method: String, _ obj: JSONValue) -> (MethodResult?, Error?) {
        var token = "", host = "", sid = ""
        var rows: [WorktreeReviewRow] = []
        var deleted: [String] = []
        var branchesRemoved = true
        func result(_ error: String? = nil, available: Bool = false, closed: Bool = false) -> (MethodResult?, Error?) {
            var fields: [(String, JS)] = [("delete_token", .string(token)), ("host", .string(host)),
                ("session_id", .string(sid)), ("worktrees", .array(rows.map { $0.json })),
                ("deleted_paths", .array(deleted.map { .string($0) })),
                ("worktree_removed", .bool(!deleted.isEmpty)),
                ("branch_removed", .bool(!deleted.isEmpty && branchesRemoved)),
                ("session_closed", .bool(closed)), ("force_available", .bool(available))]
            if let error { fields.append(("error", .string(error))) }
            return (.creation(fields: fields), nil)
        }
        do {
            token = try Params.string(obj, "delete_token")
            if method != "sessions.delete.preview", let ticket = worktreeReviewTickets[token] {
                rows = ticket.rows
            }
            sid = try Params.string(obj, "session_id")
            host = try Rex.deletionHost(Params.string(obj, "host"))
            guard try Params.string(obj, "kind") == "session" else { throw MessageError("Delete requires kind=session") }
            func validateOrigin() throws {
                if host.isEmpty {
                    try Rex.validateDeletionOrigin(sid, origins: [ctxSnapshot().session, RaptorPaths.env("REX_SESSION") ?? ""])
                }
            }
            try validateOrigin()
            if method == "sessions.delete.preview" {
                let discoverOnly = try Params.bool(obj, "discover_only")
                let metadataOnly = try Params.bool(obj, "metadata_only")
                let session: DeletionSessionState
                if discoverOnly || metadataOnly {
                    session = try loadDeletionSession?(host, sid) ?? Rex.deletionSessionState(host, sid)
                    rows = Set(session.directories).sorted().map {
                        WorktreeReviewRow(repo: "", path: $0, branch: "", checked: false, prepared: false)
                    }
                    if rows.isEmpty {
                        rows = [WorktreeReviewRow(repo: "", path: "", branch: "", error: "Unknown session directory", prepared: false)]
                    }
                } else {
                    let preview = try inspectWorktreeReview(host, sid)
                    session = preview.0
                    rows = preview.1
                }
                token = UUID().uuidString
                worktreeReviewTickets = worktreeReviewTickets.filter { $0.value.expires > Date() }
                if worktreeReviewTickets.count >= 64 { worktreeReviewTickets.removeAll() }
                var ticket = WorktreeReviewTicket(host: host, session: session, rows: rows,
                    expires: Date().addingTimeInterval(300),
                    discoveryPaths: discoverOnly || metadataOnly ? Set(session.directories) : [],
                    pending: discoverOnly || metadataOnly ? Set(session.directories) : [], metadataOnly: metadataOnly)
                if metadataOnly && !discoverOnly {
                    for source in ticket.discoveryPaths.sorted() {
                        try checkWorktreeReview(&ticket, path: source, metadataOnly: true)
                    }
                    rows = ticket.rows
                }
                worktreeReviewTickets[token] = ticket
                return result()
            }
            guard var ticket = worktreeReviewTickets[token], ticket.host == host,
                  ticket.session.sessionID == sid, ticket.expires > Date() else {
                throw MessageError("Delete preview expired; preview again")
            }
            rows = ticket.rows
            if method == "sessions.delete.check" {
                let path = try Params.string(obj, "path")
                // Validate the immutable Rex snapshot before issuing any Git commands.
                let state = try loadDeletionSession?(host, sid) ?? Rex.deletionSessionState(host, sid)
                guard state == ticket.session else {
                    worktreeReviewTickets.removeValue(forKey: token)
                    throw MessageError("Session changed; preview again")
                }
                try checkWorktreeReview(&ticket, path: path, metadataOnly: Params.bool(obj, "metadata_only"))
                ticket.expires = Date().addingTimeInterval(300)
                worktreeReviewTickets[token] = ticket
                rows = ticket.rows
                return result()
            }
            if method == "sessions.delete.prepare" {
                try prepareWorktreeReview(&ticket, obj: obj)
                ticket.expires = Date().addingTimeInterval(300)
                worktreeReviewTickets[token] = ticket
                rows = ticket.rows
                return result()
            }
            guard ticket.pending.isEmpty, rows.allSatisfy({ $0.checked }) else {
                throw MessageError("Check all worktrees before Delete")
            }
            guard try Params.bool(obj, "close_session") else { throw MessageError("Confirm closing the whole session") }
            guard let node = obj.field("selected_paths"), case .array(let values) = node.value else {
                throw MessageError("selected_paths must be a nonempty string array")
            }
            let paths = try values.map { node -> String in
                guard case .string(let path) = node.value else { throw MessageError("selected_paths must contain strings") }
                return path
            }
            let selection = Set(paths)
            let plans = rows.compactMap { $0.plan }.filter { selection.contains($0.path) }
            guard !paths.isEmpty, selection.count == paths.count, plans.count == selection.count else {
                throw MessageError("Select unique deletable worktree paths from this preview")
            }
            if ticket.metadataOnly {
                // Verification freezes the available plans, not the user's
                // final checkbox subset. Force remains bound to its exact offer.
                guard let verified = ticket.frozenSelection, selection.isSubset(of: verified),
                      plans.allSatisfy({ plan in rows.contains { $0.path == plan.path && $0.prepared && $0.eligible } }) else {
                    throw MessageError("Verify every selected worktree before Delete")
                }
            }
            let force = try Params.bool(obj, "force")
            if let offered = ticket.forceSelection, offered != selection {
                throw MessageError("Force selection changed; preview again")
            }
            if force && ticket.forceSelection == nil {
                throw MessageError("Force requires a normal Delete and separate confirmation")
            }
            do {
                let state = try loadDeletionSession?(host, sid) ?? Rex.deletionSessionState(host, sid)
                guard state == ticket.session else { throw MessageError("Session changed; preview again") }
                if ticket.metadataOnly {
                    try revalidateReviewMetadata(ticket)
                    let run = deletionRunner(host, sid, ticket.session.hostID)
                    for plan in plans {
                        guard try WorktreeKit.inspectDeletion(cwd: plan.path, run: run) == plan else {
                            throw MessageError("Worktree changed; preview again")
                        }
                    }
                } else {
                    let fresh = try inspectWorktreeReview(host, sid)
                    guard fresh.0 == ticket.session, fresh.1 == ticket.rows else {
                        throw MessageError("Session or worktrees changed; preview again")
                    }
                }
            } catch {
                worktreeReviewTickets.removeValue(forKey: token)
                throw error
            }
            if !force && plans.contains(where: { $0.needsForce }) {
                ticket.forceSelection = selection
                worktreeReviewTickets[token] = ticket
                return result("Uncommitted changes or unmerged commits. Force discards them.", available: true)
            }
            // A mutation attempt is never replayable, including partial failure.
            worktreeReviewTickets.removeValue(forKey: token)
            let run = deletionRunner(host, sid, ticket.session.hostID)
            func validateSession() throws {
                try validateOrigin()
                let removed = Set(deleted)
                let state = try loadDeletionSession?(host, sid) ?? Rex.deletionSessionState(host, sid,
                    allowingMissingDirectoriesForBlocks: ticket.session.blocksInWorktrees(removed))
                guard ticket.session.matchesDeletionProgress(state, removed: removed) else {
                    throw MessageError("Session changed; preview again")
                }
            }
            // All selected plans were compared above before any mutation.
            // executeDeletion also checks each immutable plan immediately before removal.
            try validateSession()
            for plan in plans {
                try validateSession()
                let adjusted = plan.accountingForDeletedWorktrees(Set(deleted))
                let guarded: DeletionCommand = { directory, name, args in
                    if name == "wt", args.first == "remove" { try validateSession() }
                    return try run(directory, name, args)
                }
                let outcome = WorktreeKit.executeDeletion(adjusted, force: force, run: guarded)
                if outcome.worktreeRemoved {
                    deleted.append(plan.path)
                    recordDeletedResources(host, sid, plan.path, sessionClosed: false)
                }
                branchesRemoved = branchesRemoved && outcome.branchRemoved
                guard outcome.worktreeRemoved && outcome.branchRemoved && outcome.error == nil else {
                    return result(outcome.error ?? "Removal incomplete; session kept open")
                }
            }
            try validateSession()
            if let closeDeletedSession { try closeDeletedSession(host, sid) }
            else {
                guard try Rex.deletionHostID(host) == ticket.session.hostID else { throw MessageError("Rex host identity changed") }
                try Rex.closeSession(host, sid)
            }
            recordDeletedResources(host, sid, "", sessionClosed: true)
            return result(closed: true)
        } catch {
            return result(String(describing: error))
        }
    }
}
