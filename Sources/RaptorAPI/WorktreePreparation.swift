import Foundation
import RaptorRex
import RaptorWorktree

/// Only the selected registration is frozen here. Full plans also freeze the
/// complete registration list, status and branch heads before any mutation.
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

/// Workers publish rows here, never through a Handler or ticket reference.
private final class PreparedWorktreeRows: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: WorktreeReviewRow] = [:]

    func store(_ row: WorktreeReviewRow) {
        lock.lock()
        defer { lock.unlock() }
        rows[row.path] = row
    }

    func snapshot() -> [String: WorktreeReviewRow] {
        lock.lock()
        defer { lock.unlock() }
        return rows
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
        let batch: [String]
        if let node = obj.field("paths") {
            guard case .array(let values) = node.value, (1...2).contains(values.count) else {
                throw MessageError("paths must contain one or two unique strings")
            }
            batch = try values.map { node in
                guard case .string(let path) = node.value else { throw MessageError("paths must contain strings") }
                return path
            }
            guard Set(batch).count == batch.count else {
                throw MessageError("paths must contain one or two unique strings")
            }
            if obj.field("path") != nil {
                guard try Params.string(obj, "path") == batch.first else {
                    throw MessageError("path must match the first paths entry")
                }
            }
        } else {
            batch = [try Params.string(obj, "path")]
        }
        guard batch.allSatisfy({ path in selection.contains(path) && ticket.rows.contains { $0.path == path } }) else {
            throw MessageError("Prepare path must be in the selected worktrees")
        }
        let state = try loadDeletionSession?(ticket.host, ticket.session.sessionID)
            ?? Rex.deletionSessionState(ticket.host, ticket.session.sessionID)
        guard state == ticket.session else { throw MessageError("Session changed; preview again") }
        ticket.frozenSelection = selection
        ticket.metadataRows = baseline
        // Copy all inputs and create independent runners on the request thread.
        // Successful plans are immutable, including when a sibling needs Retry.
        let jobs = batch.compactMap { path -> (WorktreeReviewRow, WorktreeReviewIdentity?, DeletionCommand)? in
            guard let row = ticket.rows.first(where: { $0.path == path }),
                  !(row.prepared && row.plan != nil) else { return nil }
            return (row, baseline.first { $0.path == path }?.metadata,
                    deletionRunner(ticket.host, ticket.session.sessionID, ticket.session.hostID))
        }
        guard !jobs.isEmpty else { return }
        let results = PreparedWorktreeRows()
        let group = DispatchGroup()
        // Validated batch size bounds concurrency to two, inside this serial request.
        for (original, identity, run) in jobs {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                var row = original
                row.error = nil
                do {
                    let plan = try WorktreeKit.inspectDeletion(cwd: row.path, run: run)
                    guard WorktreeReviewIdentity(plan) == identity else {
                        throw MessageError("Worktree identity changed; preview again")
                    }
                    row.plan = plan
                    row.prepared = true
                } catch {
                    row.error = String(describing: error)
                    row.prepared = false
                }
                results.store(row)
            }
        }
        group.wait()
        // Helpers have closed now. Do not snapshot their temporary Rex blocks.
        let after = try loadDeletionSession?(ticket.host, ticket.session.sessionID)
            ?? Rex.deletionSessionState(ticket.host, ticket.session.sessionID)
        guard after == ticket.session else { throw MessageError("Session changed; preview again") }
        let prepared = results.snapshot()
        // Merge by exact path, not completion order; keep row and source order.
        for index in ticket.rows.indices {
            if let row = prepared[ticket.rows[index].path] { ticket.rows[index] = row }
        }
        for source in ticket.sourceRows.keys {
            if let path = ticket.sourceRows[source]?.path, let row = prepared[path] {
                ticket.sourceRows[source] = row
            }
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
