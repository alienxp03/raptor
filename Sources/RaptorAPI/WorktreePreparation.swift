import Foundation
import RaptorRex
import RaptorWorktree

/// Only the selected registration is frozen here. Full plans also freeze the
/// complete registration list and content fingerprints before any mutation.
struct WorktreeReviewIdentity: Equatable {
    var path: String
    var repo: String
    var branch: String
    var head: String
    var registration: String

    init(path: String, repo: String, branch: String, head: String, registration: String) {
        self.path = path
        self.repo = repo
        self.branch = branch
        self.head = head
        self.registration = registration.components(separatedBy: "\0").filter { !$0.isEmpty }.joined(separator: "\0")
    }

    init(_ plan: DeletionPlan) {
        let record = plan.registration.components(separatedBy: "\0\0")
            .first { $0.components(separatedBy: "\0").first == "worktree " + plan.path } ?? ""
        self.init(path: plan.path, repo: plan.repo, branch: plan.branch, head: plan.head, registration: record)
    }
}

extension Handler {
    /// Git registration only: never invoke Worktrunk, status, diff, or hashes.
    func inspectReviewMetadata(_ path: String, run: DeletionCommand) -> WorktreeReviewRow {
        var row = WorktreeReviewRow(repo: "", path: path, branch: "", prepared: false)
        do {
            let listing = try run(path, "git", ["worktree", "list", "--porcelain", "-z"])
            guard listing.ok else {
                throw MessageError(listing.stderr.isEmpty ? "Cannot inspect worktree" : listing.stderr)
            }
            let records = listing.stdout.components(separatedBy: "\0\0").filter { !$0.isEmpty }
                .map { $0.components(separatedBy: "\0") }
            guard let primary = records.first?.first, primary.hasPrefix("worktree ") else {
                throw MessageError("Unknown primary worktree")
            }
            row.repo = String(primary.dropFirst(9))
            row.isPrimary = row.repo == path
            let matches = records.filter { $0.first == "worktree " + path }
            guard let record = matches.first else {
                throw MessageError("worktree is not uniquely registered or is locked/prunable")
            }
            let refs = record.filter { $0.hasPrefix("branch refs/heads/") }
            let heads = record.filter { $0.hasPrefix("HEAD ") }
            if let ref = refs.first { row.branch = String(ref.dropFirst("branch refs/heads/".count)) }
            // Keep identity even on protected/error rows. Delete must detect
            // structural and HEAD changes in unselected checkouts as well.
            row.metadata = WorktreeReviewIdentity(path: path, repo: row.repo, branch: row.branch,
                head: heads.first.map { String($0.dropFirst(5)) } ?? "",
                registration: matches.map { $0.joined(separator: "\0") }.joined(separator: "\0\0"))
            guard matches.count == 1 else {
                throw MessageError("worktree is not uniquely registered or is locked/prunable")
            }
            if row.isPrimary {
                throw MessageError(row.branch.isEmpty ? "Cannot delete this checkout." : "Cannot delete branch `\(row.branch)`.")
            }
            if let nested = records.compactMap({ $0.first }).first(where: { $0.hasPrefix("worktree " + path + "/") }) {
                throw MessageError("Cannot delete this worktree: it contains `\(nested.dropFirst(9))`.")
            }
            guard !record.contains(where: { $0 == "locked" || $0.hasPrefix("locked ") || $0.hasPrefix("prunable") }) else {
                throw MessageError("worktree is not uniquely registered or is locked/prunable")
            }
            guard refs.count == 1, !row.branch.isEmpty,
                  records.filter({ $0.contains(refs[0]) }).count == 1,
                  heads.count == 1, heads[0].count > 5 else {
                throw MessageError("worktree has no unique local Git branch or HEAD")
            }
        } catch { row.error = String(describing: error) }
        return row
    }

    func prepareWorktreeReview(_ ticket: inout WorktreeReviewTicket, obj: JSONValue) throws {
        guard ticket.metadataOnly, ticket.pending.isEmpty, ticket.rows.allSatisfy({ $0.checked }) else {
            throw MessageError("Complete all metadata checks before Prepare")
        }
        guard let node = obj.field("selected_paths"), case .array(let values) = node.value else {
            throw MessageError("selected_paths must be a nonempty string array")
        }
        let paths = try values.map { node -> String in
            guard case .string(let path) = node.value else { throw MessageError("selected_paths must contain strings") }
            return path
        }
        let selection = Set(paths)
        let baseline = ticket.metadataRows ?? ticket.rows
        guard !paths.isEmpty, paths.count == selection.count,
              selection.allSatisfy({ path in baseline.contains { $0.path == path && $0.eligible && $0.metadata != nil } }) else {
            throw MessageError("Select unique deletable worktree paths from this preview")
        }
        if let frozen = ticket.frozenSelection, frozen != selection {
            throw MessageError("Preparation selection changed; preview again")
        }
        let path = try Params.string(obj, "path")
        guard selection.contains(path), let index = ticket.rows.firstIndex(where: { $0.path == path }) else {
            throw MessageError("Prepare path must be in the selected worktrees")
        }
        let state = try loadDeletionSession?(ticket.host, ticket.session.sessionID)
            ?? Rex.deletionSessionState(ticket.host, ticket.session.sessionID)
        guard state == ticket.session else { throw MessageError("Session changed; preview again") }
        ticket.frozenSelection = selection
        ticket.metadataRows = baseline
        // A successful plan is immutable. Failed scans retain the baseline and
        // token so Retry uses the same identity and exact frozen selection.
        if ticket.rows[index].prepared && ticket.rows[index].plan != nil { return }
        var row = ticket.rows[index]
        row.error = nil
        do {
            let run = deletionRunner(ticket.host, ticket.session.sessionID, ticket.session.hostID)
            // Reject identity changes before spending time on content hashes.
            let root = try run(path, "git", ["rev-parse", "--show-toplevel"])
            guard root.ok, root.stdout.trimmingCharacters(in: .newlines) == path else {
                throw MessageError("Worktree changed; preview again")
            }
            let fresh = inspectReviewMetadata(path, run: run)
            if let error = fresh.error { throw MessageError(error) }
            let identity = baseline.first { $0.path == path }?.metadata
            guard fresh.metadata == identity else { throw MessageError("Worktree identity changed; preview again") }
            let plan = try WorktreeKit.inspectDeletion(cwd: path, run: run)
            guard WorktreeReviewIdentity(plan) == identity else {
                throw MessageError("Worktree identity changed; preview again")
            }
            row.plan = plan
            row.prepared = true
        } catch {
            row.error = String(describing: error)
            row.prepared = false
        }
        ticket.rows[index] = row
        for source in ticket.sourceRows.keys where ticket.sourceRows[source]?.path == path {
            ticket.sourceRows[source] = row
        }
    }

    func revalidateReviewMetadata(_ ticket: WorktreeReviewTicket) throws {
        guard let baseline = ticket.metadataRows else { throw MessageError("Prepare before Delete") }
        var fresh = WorktreeReviewTicket(host: ticket.host, session: ticket.session, rows: [], expires: ticket.expires,
            discoveryPaths: ticket.discoveryPaths, pending: ticket.discoveryPaths, metadataOnly: true)
        for source in ticket.discoveryPaths.sorted() {
            try checkWorktreeReview(&fresh, path: source, metadataOnly: true)
        }
        // Ignore preparation state and plans; compare every source's resolved
        // root, errors, protection and registration identity. No content scans.
        func metadataRows(_ rows: [WorktreeReviewRow]) -> [WorktreeReviewRow] {
            rows.map { original in
                var row = original
                row.plan = nil
                row.prepared = false
                return row
            }
        }
        guard metadataRows(fresh.rows) == metadataRows(baseline) else {
            throw MessageError("Session or worktrees changed; preview again")
        }
    }
}
