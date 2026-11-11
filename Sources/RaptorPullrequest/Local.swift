import Foundation
import RaptorRex
import RaptorWorktree

/// LocalCreation captures hook context before a caller creates a worktree with
/// --no-hooks. Register must be called only for an actually new worktree.
public struct LocalCreation {
    var source: String
    var config: String
    var hooks: Bool
}

extension Pullrequest {
    /// PreflightLocal refuses true pre-switch hooks before mutation: there is no
    /// safe interactive terminal yet. Deferred creation hooks must not bypass
    /// approval.
    public static func preflightLocal(source: String) throws -> LocalCreation {
        let src = try canonical(source)
        try checkPreSwitch(src)
        var p = LocalCreation(source: src, config: "", hooks: false)
        for phase in ["pre-start", "post-start", "post-switch"] {
            let out: String
            do {
                out = try command(src, "wt", ["hook", "show", phase, "--format=json"])
            } catch {
                throw MessageError("inspect \(phase) hooks: \(error)")
            }
            guard let hookList = jsonArray(out) else {
                throw MessageError("inspect \(phase) hooks: expected a JSON array")
            }
            p.hooks = p.hooks || !hookList.isEmpty
        }
        if p.hooks {
            p.config = try configStamp(src)
        }
        return p
    }
}

extension LocalCreation {
    /// Register records only configured creation setup, never an existing
    /// worktree. base is the explicit creation base; empty uses the created
    /// worktree's commit, matching instant-task creation's --base commit
    /// argument without a HEAD race.
    public func register(path: String, branch: String, base: String) throws {
        if !hooks {
            return
        }
        let p = try canonical(path)
        let unlock = try lock(p, false)
        defer { unlock() }
        let old = try load(p)
        if validState(p, old) {
            return
        }
        let id = try instance(p)
        var resolvedBase = base
        if resolvedBase.isEmpty {
            resolvedBase = try command(p, "git", ["rev-parse", "--verify", "HEAD^{commit}"])
        }
        var basePath = ""
        for tree in WorktreeKit.list(repo: source) where tree.branch == resolvedBase {
            basePath = tree.path
            break
        }
        try save(p, SetupState(instance: id, config: config, path: p, source: source,
                               branch: branch, base: resolvedBase, basePath: basePath, new: true))
    }
}

extension Pullrequest {
    /// LocalPending reports durable setup, including failed or unreleased setup.
    /// A stale journal is an error, not permission to skip setup silently.
    public static func localPending(_ path: String) throws -> Bool {
        // Ordinary dispatch also accepts paths which Rex will resolve/create. Do
        // not change that contract when no setup journal exists.
        let p = prospectivePath(path)
        let unlock = try lock(p, false)
        defer { unlock() }
        let s = try load(p)
        if s.path.isEmpty || s.complete {
            // Finished setup must not block ordinary navigation after a manual
            // branch change or replacement. Prepare/Register validate new instances.
            return false
        }
        if !validState(p, s) {
            throw MessageError("setup journal does not match this worktree instance: \(p); inspect preserved worktree")
        }
        return !s.complete
    }

    /// LocalStartup claims one NEW terminal runner. after runs only after
    /// successful Setup (for example Pi); any failure leaves a usable login
    /// shell. Never send this command to an existing terminal. Open owns
    /// session/tab recovery instead.
    public static func localStartup(path: String, target: String, after: String...) throws -> [String] {
        let p = try canonical(path)
        let exe = executablePath()
        let unlock = try lock(p, false)
        defer { unlock() }
        var s = try load(p)
        if !validState(p, s) {
            throw MessageError("no valid local setup journal: \(p)")
        }
        if s.opening || !(s.result.sessionID ?? "").isEmpty {
            throw MessageError("worktree preserved at \(p); setup destination already requested (\(s.target ?? ""), session \(s.result.sessionID ?? ""), tab \(s.result.windowID ?? ""), pane \(s.result.blockID ?? "")); inspect/select that destination, then run raptor setup --path \(quote(p)) --retry")
        }
        var wrapper = "trap ':' INT; " + quote(exe) + " setup --path " + quote(p)
        if !after.isEmpty {
            let parts = after.map { quote($0) }
            wrapper += " && { " + parts.joined(separator: " ") + "; exit $?; }"
        }
        wrapper += "; exec \"${SHELL:-/bin/sh}\" -l"
        s.opening = true
        s.target = target
        try save(p, s)
        return ["/bin/sh", "-c", wrapper]
    }

    /// ResumeLocal selects a previously requested generic destination without
    /// starting another runner. Unknown create results require manual inspection.
    /// Go returned (result, handled, error); failures throw ResumeError carrying
    /// both values.
    public static func resumeLocal(path: String, target: String, ctx: Ctx) throws -> (result: OpenResult, handled: Bool) {
        func handledFailure(_ result: OpenResult, _ error: any Error) -> ResumeError {
            ResumeError(result: result, handled: true, cause: error)
        }
        do {
            let p = try canonical(path)
            let unlock = try lock(p, false)
            defer { unlock() }
            var s = try load(p)
            if !validState(p, s) {
                throw MessageError("invalid setup journal: \(p)")
            }
            if !s.opening {
                return (OpenResult(), false)
            }
            let result = s.result
            if s.target ?? "" != target {
                throw handledFailure(result, MessageError("worktree preserved at \(p); retry original \(s.target ?? "") destination"))
            }
            do {
                try verifyDestination(result)
            } catch {
                throw handledFailure(result, MessageError("worktree preserved at \(p); inspect existing setup destination: \(error)"))
            }
            if !ctx.client.isEmpty {
                try Rex.doAction(client: ctx.client, action: "session.select",
                                 kv: ["session_id=" + (result.sessionID ?? ""), "window_id=" + (result.windowID ?? "")])
            } else {
                _ = try Rex.run("focus", "-s", result.sessionID ?? "", result.blockID ?? "")
            }
            s.released = true
            try save(p, s)
            return (result, true)
        } catch let e as ResumeError {
            throw e
        } catch {
            throw ResumeError(result: OpenResult(), handled: false, cause: error)
        }
    }

    /// LocalDestination saves IDs even on selection failure. released must be
    /// true only after the Rex selection request succeeds (not proof of visual
    /// focus).
    public static func localDestination(path: String, result: OpenResult, released: Bool) throws {
        let p = try canonical(path)
        let unlock = try lock(p, false)
        defer { unlock() }
        var s = try load(p)
        if !validState(p, s) {
            throw MessageError("worktree instance changed: \(p)")
        }
        var stored = result
        stored.path = p
        s.result = stored
        s.released = released
        try save(p, s)
    }
}
