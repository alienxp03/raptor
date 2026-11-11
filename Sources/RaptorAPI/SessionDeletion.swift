import Foundation
import RaptorCatalog
import RaptorPaths
import RaptorRex
import RaptorWorktree

struct SessionDeletionTicket {
    var host: String
    var session: DeletionSessionState
    var plan: DeletionPlan
    var expires: Date
    var forceOffered = false
}

struct DeletionTombstone: Codable {
    var host: String
    var sessionID: String
    var path: String
}

extension Handler {
    func sessionDeletion(_ method: String, _ params: [UInt8]) -> (MethodResult?, Error?) {
        do {
            var parser = JSONParser(params)
            let obj = try parser.parseTop().value
            guard try Params.string(obj, "kind") == "session" else { throw MessageError("Delete requires kind=session") }
            let sid = try Params.string(obj, "session_id")
            let host = try Rex.deletionHost(Params.string(obj, "host"))
            let token = try Params.string(obj, "delete_token")
            let force = try Params.bool(obj, "force")
            let origin = ctxSnapshot().session
            if host.isEmpty {
                try Rex.validateDeletionOrigin(sid, origins: [origin, RaptorPaths.env("REX_SESSION") ?? ""])
            }
            if method == "sessions.delete.preview" {
                let (session, plan) = try inspectSessionDeletion(host, sid)
                let key = UUID().uuidString
                deleteTickets = deleteTickets.filter { $0.value.expires > Date() }
                // Bound retained previews without allowing an old confirmation to
                // acquire a new target after backend restart or token eviction.
                if deleteTickets.count >= 64 { deleteTickets.removeAll() }
                deleteTickets[key] = SessionDeletionTicket(host: host, session: session, plan: plan,
                                                          expires: Date().addingTimeInterval(300))
                return (.creation(fields: deletionFields(key, host, sid, plan)), nil)
            }
            guard var ticket = deleteTickets[token], ticket.host == host, ticket.session.sessionID == sid,
                  ticket.expires > Date() else { throw MessageError("Delete preview expired; preview again") }
            var fields = deletionFields(token, host, sid, ticket.plan)
            func result(_ error: String?, _ available: Bool = false,
                        _ worktree: Bool = false, _ branch: Bool = false, _ closed: Bool = false) -> (MethodResult?, Error?) {
                fields += [("force_available", .bool(available)), ("worktree_removed", .bool(worktree)),
                           ("branch_removed", .bool(branch)), ("session_closed", .bool(closed))]
                if let error { fields.append(("error", .string(error))) }
                return (.creation(fields: fields), nil)
            }
            let fresh: (DeletionSessionState, DeletionPlan)
            do { fresh = try inspectSessionDeletion(host, sid) }
            catch {
                deleteTickets.removeValue(forKey: token)
                return result("Delete revalidation failed: \(error)")
            }
            guard fresh.0 == ticket.session, fresh.1 == ticket.plan else {
                deleteTickets.removeValue(forKey: token)
                return result("Session, worktree, branch, or HEAD changed; preview again")
            }
            if force && !ticket.forceOffered { return result("Force requires a failed normal Delete and a separate confirmation") }
            if !force && ticket.plan.needsForce {
                ticket.forceOffered = true
                deleteTickets[token] = ticket
                return result("Worktree has dirty/ignored files or unmerged commits. Force discards them.", true)
            }
            deleteTickets.removeValue(forKey: token)
            let run = deletionRunner(host, sid, ticket.session.hostID)
            let guarded: DeletionCommand = { directory, name, arguments in
                if name == "wt", arguments.first == "remove" {
                    if host.isEmpty {
                        try Rex.validateDeletionOrigin(sid, origins: [self.ctxSnapshot().session, RaptorPaths.env("REX_SESSION") ?? ""])
                    }
                    let state = try self.loadDeletionSession?(host, sid) ?? Rex.deletionSessionState(host, sid)
                    guard state == ticket.session else { throw MessageError("session changed before removal; preview again") }
                }
                return try run(directory, name, arguments)
            }
            let outcome = WorktreeKit.executeDeletion(ticket.plan, force: force, run: guarded)
            if outcome.worktreeRemoved { recordDeletedResources(host, sid, ticket.plan.path, sessionClosed: false) }
            guard outcome.worktreeRemoved && outcome.branchRemoved else {
                return result(outcome.error ?? "Worktrunk retained resources; session kept open", false,
                              outcome.worktreeRemoved, outcome.branchRemoved)
            }
            do {
                if let closeDeletedSession { try closeDeletedSession(host, sid) }
                else {
                    guard try Rex.deletionHostID(host) == ticket.session.hostID else {
                        throw MessageError("Rex host identity changed before session close")
                    }
                    try Rex.closeSession(host, sid)
                }
            }
            catch { return result("Resources removed, but session close failed: \(error). \(outcome.error ?? "")", false, true, true) }
            recordDeletedResources(host, sid, ticket.plan.path, sessionClosed: true)
            return result(outcome.error, false, true, true, true)
        } catch { return (nil, error) }
    }

    func deletionRunner(_ host: String, _ sid: String, _ hostID: String) -> DeletionCommand {
        if let runDeletionCommand { return runDeletionCommand(host, sid, hostID) }
        return { try Rex.deletionCommand(host, sid, hostID, directory: $0, name: $1, arguments: $2) }
    }

    func inspectSessionDeletion(_ host: String, _ sid: String) throws -> (DeletionSessionState, DeletionPlan) {
        let state = try loadDeletionSession?(host, sid) ?? Rex.deletionSessionState(host, sid)
        let run = deletionRunner(host, sid, state.hostID)
        var plans: [DeletionPlan] = []
        for cwd in Set(state.directories) { plans.append(try WorktreeKit.inspectDeletion(cwd: cwd, run: run)) }
        guard let plan = plans.first, plans.allSatisfy({ $0 == plan }) else {
            throw MessageError("session spans multiple different worktrees or has no known directory")
        }
        return (state, plan)
    }

    func deletionFields(_ token: String, _ host: String, _ sid: String, _ plan: DeletionPlan) -> [(String, JS)] {
        [("repo", .string(plan.repo)), ("path", .string(plan.path)), ("branch", .string(plan.branch)),
         ("delete_token", .string(token)), ("host", .string(host)), ("session_id", .string(sid))]
    }

    func deletionTombstonesPath() -> String { RaptorPaths.cacheDir() + "/session-deletions.json" }

    /// cacheMu must be held. Filter after creation overlays and failed-host row
    /// retention. Persistent tombstones also block old disk caches after restart.
    func filterDeleted(_ entry: LauncherCacheEntry) -> LauncherCacheEntry {
        var entry = entry
        let tombstones = (try? Data(contentsOf: URL(fileURLWithPath: deletionTombstonesPath())))
            .flatMap { try? JSONDecoder().decode([DeletionTombstone].self, from: $0) } ?? []
        entry.items = entry.items?.filter { item in
            !(tombstones + deletionTombstones).contains { tombstone in
                let sameHost = tombstone.host.isEmpty ? item.local : item.host == tombstone.host
                guard sameHost else { return false }
                if item.kind == "session" { return !tombstone.sessionID.isEmpty && item.sessionID == tombstone.sessionID }
                return !tombstone.path.isEmpty && (item.path == tombstone.path || item.path.hasPrefix(tombstone.path + "/"))
            }
        }
        return entry
    }

    /// An explicit successful creation can reuse a deleted path. Keep old
    /// session IDs blocked, but make that directory selectable again.
    func reviveDeletedPath(_ host: String, _ path: String) {
        cacheMu.lock()
        defer { cacheMu.unlock() }
        let file = URL(fileURLWithPath: deletionTombstonesPath())
        var records = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([DeletionTombstone].self, from: $0) } ?? []
        for i in records.indices where records[i].host == host && records[i].path == path { records[i].path = "" }
        for i in deletionTombstones.indices where deletionTombstones[i].host == host && deletionTombstones[i].path == path {
            deletionTombstones[i].path = ""
        }
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: file, options: .atomic) }
    }

    func recordDeletedResources(_ host: String, _ sid: String, _ path: String, sessionClosed: Bool) {
        cacheMu.lock()
        defer { cacheMu.unlock() }
        let file = URL(fileURLWithPath: deletionTombstonesPath())
        var records = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([DeletionTombstone].self, from: $0) } ?? []
        let record = DeletionTombstone(host: host, sessionID: sessionClosed ? sid : "", path: path)
        records.append(record)
        deletionTombstones.append(record)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: file, options: .atomic) }
        generation += 1
        launcher = filterDeleted(overlayLauncher(launcher))
        writeLauncherCache(launcher.items ?? [], launcher.hosts)
        if sessionClosed { activityAgents.removeAll { $0.sessionID == sid } }
    }
}
