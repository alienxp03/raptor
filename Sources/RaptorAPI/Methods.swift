import Foundation
import RaptorCatalog
import RaptorConfig
import RaptorDispatch
import RaptorPaths
import RaptorPullrequest
import RaptorRex
import RaptorTheme
import RaptorWorktree

/// The shared {kind, session_id, window_id?, host?} envelope of the tab/session
/// mutations. The empty host is the local server.
struct SessionActionParams {
    var kind: String
    var sessionID: String
    var windowID: String
    var label: String
    var host: String
}

extension Handler {
    func targets() -> [String] {
        let ctx = ctxSnapshot()
        return cfg.availableTargets(hasBlock: !ctx.block.isEmpty)
    }

    /// callContext: decode each method separately — unrelated parameters must not
    /// change type validation for the selected method.
    func call(_ cancel: CancelToken, _ method: String, _ params: [UInt8]) -> (MethodResult?, Error?) {
        let ctx = ctxSnapshot()
        switch method {
        case "theme":
            return (.theme(raw: RaptorTheme.themeJSONData()), nil)
        case "sessions.visit":
            do {
                return (try observeFocus(params), nil)
            } catch {
                return (nil, error)
            }
        case "context":
            // The resident backend is shared across opens; every open sends its
            // origin context here instead of spawning a new process.
            let obj: JSONValue
            do {
                var parser = JSONParser(params)
                obj = try parser.parseTop().value
            } catch {
                return (nil, error)
            }
            let session: String, block: String, client: String, title: String
            do {
                session = try Params.string(obj, "session")
                block = try Params.string(obj, "block")
                client = try Params.string(obj, "client")
                title = try Params.string(obj, "title")
            } catch {
                return (nil, error)
            }
            cacheMu.lock()
            self.ctx = Ctx(session: session, block: block, client: client, title: title)
            presentation += 1
            if revalidating {
                refreshPending = true
                generation += 1
            }
            cacheMu.unlock()
            captureRecency(true)
            return (.empty, nil)
        case "pins.toggle":
            let obj: JSONValue
            do {
                var parser = JSONParser(params)
                obj = try parser.parseTop().value
            } catch {
                return (nil, error)
            }
            let path: String
            do {
                path = try Params.string(obj, "path")
            } catch {
                return (nil, error)
            }
            if path.isEmpty {
                return (nil, MessageError("path is required"))
            }
            let pinned: Bool
            do {
                pinned = try RaptorConfig.togglePin(path)
            } catch {
                return (nil, error)
            }
            patchLauncherPin(path, pinned)
            return (.pins(pinned: pinned), nil)
        case "agents":
            let obj: JSONValue
            do {
                var parser = JSONParser(params)
                obj = try parser.parseTop().value
            } catch {
                return (nil, error)
            }
            let query: String
            do {
                query = try Params.string(obj, "query")
            } catch {
                return (nil, error)
            }
            let entries: [AgentEntry]
            do {
                entries = try activitySnapshotContext(cancel, true)
            } catch {
                return (nil, error)
            }
            var filtered = entries
            for i in filtered.indices {
                filtered[i].active = filtered[i].sessionID == ctx.session
                    && (ctx.block.isEmpty || filtered[i].blockID == ctx.block)
            }
            var items: [AgentEntry] = []
            for i in Catalog.filterAgents(filtered, query) {
                items.append(filtered[i])
            }
            return (.agents(items: items, target: cfg.enter), nil)
        case "agents.jump":
            let obj: JSONValue
            do {
                var parser = JSONParser(params)
                obj = try parser.parseTop().value
            } catch {
                return (nil, error)
            }
            let sessionID: String, windowID: String, blockID: String
            do {
                sessionID = try Params.string(obj, "session_id")
                windowID = try Params.string(obj, "window_id")
                blockID = try Params.string(obj, "block_id")
            } catch {
                return (nil, error)
            }
            do {
                try Rex.jumpAgent(AgentEntry(sessionID: sessionID, windowID: windowID, blockID: blockID), ctx.client)
                return (.empty, nil)
            } catch {
                return (nil, error)
            }
        case "sessions":
            let obj: JSONValue
            do {
                var parser = JSONParser(params)
                obj = try parser.parseTop().value
            } catch {
                return (nil, error)
            }
            let query: String
            do {
                query = try Params.string(obj, "query")
            } catch {
                return (nil, error)
            }
            cacheMu.lock()
            let wasLoaded = launcherLoaded
            cacheMu.unlock()
            let (firstRead, ok) = readLauncherCache()
            if !ok {
                if let error = refreshColdContext(cancel, true) {
                    return (nil, error)
                }
            } else if !wasLoaded {
                // Disk rows are immediately usable. Refresh once, not per query.
                revalidateLauncher()
            }
            var cached = firstRead
            if !ok {
                cached = readLauncherCache().0
            }
            var items = cached.items ?? []
            cacheMu.lock()
            let origin = self.ctx.session
            let ranks = self.ranks
            cacheMu.unlock()
            for i in items.indices {
                items[i].active = items[i].local && items[i].sessionID == origin
            }
            Catalog.orderLauncherSessionsByRecency(&items, ranks)
            // Full IDs were compared above. An empty origin prevents catalog's
            // reference resolver from making native calls for each candidate.
            items = Catalog.pinLauncherOrigin(items, "")
            items = Catalog.filterLauncherItems(items, query, "")
            return (
                .sessions(
                    selectedID: Catalog.preferredLauncherID(items, query), items: items,
                    hosts: cached.hosts, targets: targets(), target: "session"),
                nil
            )
        case "sessions.jump":
            return runSessionAction(params) { p, entry in
                let host = Rex.apiNormalizeHost(entry.host)
                try apiJumpOnHost(host, entry, ctx.client)
                return .empty
            }
        case "sessions.create":
            let obj: JSONValue
            do {
                var parser = JSONParser(params)
                obj = try parser.parseTop().value
            } catch {
                return (nil, error)
            }
            let hostParam: String, dir: String
            do {
                hostParam = try Params.string(obj, "host")
                dir = try Params.string(obj, "dir")
            } catch {
                return (nil, error)
            }
            if dir.isEmpty {
                return (nil, MessageError("dir is required"))
            }
            let host = Rex.apiNormalizeHost(hostParam)
            let sid: String, existing: Bool
            do {
                let created = try apiCreateSessionOn(host, dir)
                sid = created.id
                existing = created.existing
            } catch {
                return (nil, error)
            }
            var fields: [(String, JS)] = [
                ("existing", .bool(existing)),
                ("session_id", .string(sid)),
            ]
            do {
                try apiSelectOnHost(host, sid, ctx.client)
            } catch {
                fields.append((
                    "error",
                    .string("created \(sid) on \(Rex.localHostLabelOr(host)), but could not switch to it: \(error)")
                ))
            }
            addLauncherItems(to: &fields)
            return (.creation(fields: fields.sorted { $0.0 < $1.0 }), nil)
        case "sessions.close":
            return runSessionAction(params) { p, entry in
                if entry.kind == "session" && (entry.host.isEmpty || entry.host == Rex.localHostLabel)
                    && entry.sessionID == ctx.session {
                    throw MessageError("refusing to close the session this picker opened from")
                }
                let host = Rex.apiNormalizeHost(entry.host)
                if entry.kind == "session" {
                    try Rex.closeSession(host, entry.sessionID)
                } else {
                    try Rex.closeWindow(host, entry.sessionID, entry.id)
                }
                return .empty
            }
        case "sessions.rename":
            return runSessionAction(params) { p, entry in
                if p.label.isEmpty {
                    throw MessageError("label is required")
                }
                let host = Rex.apiNormalizeHost(entry.host)
                if entry.kind == "session" {
                    try Rex.setSessionLabel(host, entry.sessionID, p.label)
                } else {
                    try Rex.setWindowLabel(host, entry.sessionID, entry.id, p.label)
                }
                return .empty
            }
        case "directories":
            let obj: JSONValue
            do {
                var parser = JSONParser(params)
                obj = try parser.parseTop().value
            } catch {
                return (nil, error)
            }
            let query: String, reposOnly: Bool, host: String
            do {
                query = try Params.string(obj, "query")
                reposOnly = try Params.bool(obj, "repos_only")
                host = try Params.string(obj, "host")
            } catch {
                return (nil, error)
            }
            var items = Catalog.directoriesOn(host: host, reposOnly: reposOnly)
            if let agents = try? activitySnapshotContext(cancel, false) {
                Catalog.applyDirectoryActivity(&items, agents)
            }
            var resultItems: [Directory] = []
            for i in Catalog.filterDirectories(items, query) {
                resultItems.append(items[i])
            }
            Catalog.applyPins(&resultItems)
            return (.directories(items: resultItems, targets: targets(), target: cfg.enter), nil)
        case "pullrequests.resolve", "pullrequests.prepare", "pullrequests.open":
            return pullRequest(method, params)
        case "worktrees.list":
            let obj: JSONValue
            do {
                var parser = JSONParser(params)
                obj = try parser.parseTop().value
            } catch {
                return (nil, error)
            }
            let repoParam: String, query: String
            do {
                repoParam = try Params.string(obj, "repo")
                query = try Params.string(obj, "query")
            } catch {
                return (nil, error)
            }
            let ctxValue = Ctx(session: ctx.session, block: ctx.block, client: ctx.client, title: ctx.title)
            let repo: String
            do {
                repo = try Catalog.resolveRepo(ctxValue, repoParam)
            } catch {
                return (nil, error)
            }
            var items: [TreeItem] = []
            var branches: [String] = []
            var destinationRoot = ""
            var baseBranch = ""
            var suggestedBranch = ""
            if !repo.isEmpty {
                let info = Catalog.listWorktrees(repo, cfg)
                destinationRoot = info.root
                branches.append(contentsOf: info.branches)
                baseBranch = info.baseBranch
                suggestedBranch = info.suggestedBranch
                for i in Catalog.filterWorktrees(info.items, query) {
                    let w = info.items[i]
                    items.append(TreeItem(path: w.path, branch: w.branch, isMain: w.isMain))
                }
            }
            return (
                .tree(
                    destinationRoot: destinationRoot, repo: repo, needsRepo: repo.isEmpty,
                    items: items, branches: branches, baseBranch: baseBranch,
                    suggestedBranch: suggestedBranch, targets: targets(), target: cfg.enter),
                nil
            )
        case "worktrees.branches":
            let obj: JSONValue
            do {
                var parser = JSONParser(params)
                obj = try parser.parseTop().value
            } catch {
                return (nil, error)
            }
            let repoParam: String, query: String
            do {
                repoParam = try Params.string(obj, "repo")
                query = try Params.string(obj, "query")
            } catch {
                return (nil, error)
            }
            let ctxValue = Ctx(session: ctx.session, block: ctx.block, client: ctx.client, title: ctx.title)
            let repo: String
            do {
                repo = try Catalog.resolveRepo(ctxValue, repoParam)
            } catch {
                return (nil, error)
            }
            if repo.isEmpty {
                return (nil, MessageError("choose a repository"))
            }
            return (.branches(items: Catalog.filterBranches(WorktreeKit.localBranches(repo: repo), query)), nil)
        case "worktrees.preview", "worktrees.create", "worktrees.remove":
            let obj: JSONValue
            do {
                var parser = JSONParser(params)
                obj = try parser.parseTop().value
            } catch {
                return (nil, error)
            }
            let repoParam: String, branch: String, base: String, pathParam: String
            do {
                repoParam = try Params.string(obj, "repo")
                branch = try Params.string(obj, "branch")
                base = try Params.string(obj, "base")
                pathParam = try Params.string(obj, "path")
            } catch {
                return (nil, error)
            }
            let ctxValue = Ctx(session: ctx.session, block: ctx.block, client: ctx.client, title: ctx.title)
            let repo: String
            do {
                repo = try Catalog.resolveRepo(ctxValue, repoParam)
            } catch {
                return (nil, error)
            }
            if repo.isEmpty {
                return (nil, MessageError("choose a repository"))
            }
            if method == "worktrees.remove" {
                if !pathParam.isEmpty {
                    for tree in WorktreeKit.list(repo: repo) {
                        if apiCanonicalPath(tree.path) == apiCanonicalPath(pathParam) {
                            do {
                                try WorktreeKit.remove(repo: repo, tree: tree)
                                return (.empty, nil)
                            } catch {
                                return (nil, error)
                            }
                        }
                    }
                }
                return (nil, MessageError("unknown worktree: \(pathParam)"))
            }
            let path = WorktreeKit.path(repo: repo, branch: branch, cfg: cfg)
            if method == "worktrees.preview" {
                var validationError = ""
                do {
                    try WorktreeKit.validate(repo: repo, branch: branch, base: base, path: path)
                } catch {
                    validationError = String(describing: error)
                }
                return (.preview(path: path, validationError: validationError), nil)
            }
            let setup: LocalCreation
            do {
                setup = try Pullrequest.preflightLocal(source: repo)
            } catch {
                return (nil, error)
            }
            var before = Set<String>()
            for tree in WorktreeKit.list(repo: repo) {
                before.insert(apiCanonicalPath(tree.path))
            }
            var createError: Error?
            do {
                try WorktreeKit.createLocal(repo: repo, branch: branch, base: base, path: path)
            } catch {
                createError = error
            }
            // Use the registered resource, including a switch which failed after
            // creation. Never attach creation setup to a pre-existing worktree.
            var resolvedPath = path
            for tree in WorktreeKit.list(repo: repo) {
                if tree.branch == branch && !before.contains(apiCanonicalPath(tree.path)) {
                    if apiCanonicalPath(resolvedPath) != apiCanonicalPath(tree.path) {
                        resolvedPath = tree.path
                    }
                    do {
                        try setup.register(path: tree.path, branch: tree.branch, base: base)
                    } catch {
                        return (
                            .path(resolvedPath),
                            MessageError(
                                "worktree preserved at \(resolvedPath); creation error: \(describe(createError)); "
                                    + "could not register setup: \(error)")
                        )
                    }
                    if let createError {
                        return (
                            .path(resolvedPath),
                            MessageError("worktree preserved at \(resolvedPath): \(describe(createError))")
                        )
                    }
                    return (.path(resolvedPath), nil)
                }
            }
            if let createError {
                return (nil, createError)
            }
            return (nil, MessageError("creation returned without a new registered worktree; inspect \(path)"))
        case "dispatch":
            let obj: JSONValue
            do {
                var parser = JSONParser(params)
                obj = try parser.parseTop().value
            } catch {
                return (nil, error)
            }
            let target: String, path: String
            do {
                target = try Params.string(obj, "target")
                path = try Params.string(obj, "path")
            } catch {
                return (nil, error)
            }
            if path.isEmpty {
                return (nil, MessageError("path is required"))
            }
            let ctxValue = Ctx(session: ctx.session, block: ctx.block, client: ctx.client, title: ctx.title)
            let result: OpenResult
            let dispatchError: Error?
            do {
                result = try RaptorDispatch.dispatchResult(target: target, dir: path, ctx: ctxValue, cfg: cfg)
                dispatchError = nil
            } catch let error as DispatchError {
                result = error.result
                dispatchError = error
            } catch {
                result = OpenResult(path: path)
                dispatchError = error
            }
            if let dispatchError, (result.sessionID ?? "").isEmpty {
                return (nil, dispatchError)
            }
            return (openLauncherResult(result, dispatchError), nil)
        default:
            return (nil, MessageError("unknown method \"" + method + "\""))
        }
    }

    func describe(_ error: Error?) -> String {
        guard let error else { return "<nil>" }
        return String(describing: error)
    }

    /// decodeSessionAction + run, mirroring the Go validation order.
    func runSessionAction(_ params: [UInt8], _ body: (SessionActionParams, SessionEntry) throws -> MethodResult)
        -> (MethodResult?, Error?) {
        let obj: JSONValue
        do {
            var parser = JSONParser(params)
            obj = try parser.parseTop().value
        } catch {
            return (nil, error)
        }
        var p = SessionActionParams(kind: "", sessionID: "", windowID: "", label: "", host: "")
        do {
            p.kind = try Params.string(obj, "kind")
            p.sessionID = try Params.string(obj, "session_id")
            p.windowID = try Params.string(obj, "window_id")
            p.label = try Params.string(obj, "label")
            p.host = try Params.string(obj, "host")
        } catch {
            return (nil, error)
        }
        if p.kind != "session" && p.kind != "window" {
            return (nil, MessageError("kind must be session or window"))
        }
        if p.sessionID.isEmpty {
            return (nil, MessageError("session_id is required"))
        }
        if p.kind == "window" && p.windowID.isEmpty {
            return (nil, MessageError("window_id is required for a window"))
        }
        var entry = SessionEntry(kind: p.kind, id: p.windowID, sessionID: p.sessionID, host: p.host)
        if p.kind == "session" {
            entry.id = p.sessionID
        }
        do {
            return (try body(p, entry), nil)
        } catch {
            return (nil, error)
        }
    }
}
