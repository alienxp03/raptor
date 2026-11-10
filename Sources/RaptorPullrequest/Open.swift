import Foundation
import RaptorRex
import RaptorWorktree

/// Thrown where Go returned (result, error) so recovery keeps every ID.
public struct OpenError: Error, CustomStringConvertible {
    public let result: OpenResult
    public let cause: any Error
    public var description: String { String(describing: cause) }
}

/// Thrown where Go returned (result, handled, error) from ResumeLocal.
public struct ResumeError: Error, CustomStringConvertible {
    public let result: OpenResult
    public let handled: Bool
    public let cause: any Error
    public var description: String { String(describing: cause) }
}

struct NoDestinationsError: Error, CustomStringConvertible {
    var description: String { "authoritative reconciliation found zero destinations" }
}

func quote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

func setupWrapper(_ executable: String, _ path: String) -> String {
    "trap ':' INT; " + quote(executable) + " setup --path " + quote(path) + "; exec \"${SHELL:-/bin/sh}\" -l"
}

/// Go's os.Executable: argv0, made absolute when it carries directory parts.
func executablePath() -> String {
    let argv0 = CommandLine.arguments.first ?? ""
    if argv0.hasPrefix("/") { return argv0 }
    if argv0.contains("/") {
        return pathClean(FileManager.default.currentDirectoryPath + "/" + argv0)
    }
    return argv0
}

/// destinationLabel is presentation only: Worktrunk still owns branch names and
/// worktree paths. Durable Rex IDs, not this label, identify an existing open.
func destinationLabel(_ s: SetupState) -> String {
    if let (id, number) = try? parse(s.url, "") {
        let repo = id.contains("/") ? String(id.split(separator: "/", maxSplits: 1)[1]) : id
        return repo + "-pr-" + number + "-" + s.branch.replacingOccurrences(of: "/", with: "-")
    }
    return baseOf(s.path)
}

func uncertainTransport(_ error: (any Error)?) -> Bool {
    guard let error else { return false }
    let message = String(describing: error).lowercased()
    for marker in ["timeout", "timed out", "deadline", "eof", "connection", "socket", "transport",
                   "broken pipe", "response", "respond", "network", "cancel", "interrupt"] {
        if message.contains(marker) { return true }
    }
    return false
}

func verifyDestination(_ result: OpenResult) throws {
    if (result.sessionID ?? "").isEmpty || (result.blockID ?? "").isEmpty || (result.windowID ?? "").isEmpty {
        throw MessageError("incomplete destination IDs; inspect preserved Rex resources")
    }
    let out: String
    do {
        out = try Rex.run("session", "inspect", result.sessionID ?? "", "--json")
    } catch {
        throw MessageError("preserved destination unavailable: \(error)")
    }
    guard let view = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any],
          let windows = view["windows"] as? [[String: Any]] else {
        throw MessageError("invalid Rex session JSON")
    }
    var found = false
    for window in windows where (window["window_id"] as? String ?? "") == (result.windowID ?? "") {
        found = true
    }
    var cwd = ""
    var cwdErr: (any Error)?
    do {
        cwd = try canonical(Rex.blockCwdInSession(result.sessionID ?? "", result.blockID ?? ""))
    } catch {
        cwdErr = error
    }
    if !found || cwdErr != nil || cwd != result.path {
        throw MessageError("destination IDs no longer match \(result.path); resources preserved")
    }
}

func reconcile(_ path: String) throws -> OpenResult {
    var result = OpenResult(path: path)
    let out = try Rex.run("ls", "--json")
    guard let listObj = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] else {
        throw MessageError("invalid Rex listing JSON")
    }
    guard let sessions = listObj["sessions"] as? [[String: Any]] else {
        throw MessageError("incomplete Rex session listing")
    }
    var matches = 0
    for session in sessions {
        let sid = session["session_id"] as? String ?? ""
        let iout: String
        do {
            iout = try Rex.run("session", "inspect", sid, "--json")
        } catch {
            throw MessageError("cannot reconcile session \(sid): \(error)")
        }
        guard let view = (try? JSONSerialization.jsonObject(with: Data(iout.utf8))) as? [String: Any] else {
            throw MessageError("invalid Rex window JSON")
        }
        guard let windows = view["windows"] as? [[String: Any]] else {
            throw MessageError("incomplete Rex window listing")
        }
        for window in windows {
            guard let blocks = window["blocks"] as? [[String: Any]], !blocks.isEmpty else {
                throw MessageError("incomplete Rex block listing")
            }
            let windowID = window["window_id"] as? String ?? ""
            for block in blocks {
                let bid = block["block_id"] as? String ?? ""
                let cwd = Rex.blockCwdInSession(sid, bid)
                guard let p = try? canonical(cwd) else {
                    throw MessageError("cannot reconcile block \(bid) cwd")
                }
                if p == path {
                    matches += 1
                    result = OpenResult(path: path, sessionID: sid, windowID: windowID, blockID: bid)
                }
            }
        }
    }
    if matches == 0 {
        throw NoDestinationsError()
    }
    if matches != 1 {
        throw MessageError("uncertain Rex creation: found \(matches) destinations at \(path); inspect preserved resources before retry")
    }
    return result
}

extension Pullrequest {
    /// Open accepts only session or tab. Selection is queued, not visual
    /// confirmation. A failed create is reconciled by canonical cwd; labels are
    /// never identities. On failure OpenError carries the full result, like Go's
    /// deferred `result.Error = err.Error()`.
    public static func open(path: String, target: String, ctx: Ctx) throws -> OpenResult {
        var result = OpenResult(path: path)
        func bail(_ error: any Error) -> OpenError {
            result.error = String(describing: error)
            return OpenError(result: result, cause: error)
        }
        let p: String
        do {
            p = try canonical(path)
        } catch {
            throw bail(error)
        }
        result.path = p
        if let prior = try? load(p), validState(p, prior), !(prior.result.sessionID ?? "").isEmpty {
            result = prior.result
            result.path = p
            result.error = nil
        }
        if target != "session" && target != "tab" {
            throw bail(MessageError("PR setup requires session or tab"))
        }
        if target == "tab" && ctx.session.isEmpty {
            throw bail(MessageError("tab requires a session ID"))
        }
        if ctx.client.isEmpty {
            throw bail(MessageError("a Rex client ID is required for selection"))
        }
        let unlock: () -> Void
        do {
            unlock = try lock(p, false)
        } catch {
            throw bail(error)
        }
        defer { unlock() }
        var s: SetupState
        do {
            s = try load(p)
        } catch {
            throw bail(error)
        }
        if !validState(p, s) {
            throw bail(MessageError("no PR setup state for \(p); call Prepare first"))
        }
        result = s.result
        result.path = p
        result.error = nil
        if !(s.target ?? "").isEmpty && s.target != target {
            throw bail(MessageError("destination already prepared as \(s.target ?? ""); retry that target"))
        }
        if s.opening && ((result.sessionID ?? "").isEmpty || (result.windowID ?? "").isEmpty || (result.blockID ?? "").isEmpty) {
            var reconciled: OpenResult
            do {
                reconciled = try reconcile(p)
            } catch {
                if !(s.retryCreate ?? false) || !(error is NoDestinationsError) {
                    throw bail(error)
                }
                // Only a completed, explicit failure plus a full zero-match scan
                // permits another create. Timeouts/lost responses remain blocked.
                s.opening = false
                s.retryCreate = false
                reconciled = OpenResult(path: p)
            }
            result = reconciled
            s.result = result
            do {
                try save(p, s)
            } catch {
                throw bail(error)
            }
        }
        if (result.sessionID ?? "").isEmpty {
            let executable = executablePath()
            // Setup is a child command. Even a failure returns to a fresh usable login shell.
            let wrapper = setupWrapper(executable, p)
            let label = destinationLabel(s)
            var args = ["new", label, "-c", p, "--json"]
            if target == "tab" {
                args = ["window", "new", "-s", ctx.session, label, "-c", p, "--json"]
            }
            args.append(contentsOf: ["--", "/bin/sh", "-c", wrapper])
            s.opening = true
            s.target = target
            s.retryCreate = false
            do {
                try save(p, s)
            } catch {
                throw bail(error)
            }
            var out = ""
            var cmdErr: CmdError?
            var createErr: (any Error)?
            do {
                out = try commandContext(timeout: 15, dir: "", name: "rex", args: args)
            } catch let e as CmdError {
                cmdErr = e
                createErr = e
                out = e.stdout
            } catch {
                createErr = error
            }
            var parseOK = false
            var explicitJSONError = false
            var createdSessionID = ""
            if let obj = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] {
                parseOK = true
                if let e = obj["error"], !(e is NSNull) {
                    explicitJSONError = true
                }
                createdSessionID = obj["session_id"] as? String ?? ""
                result.sessionID = createdSessionID.isEmpty ? nil : createdSessionID
                result.windowID = ((obj["window_id"] as? String ?? "")).isEmpty ? nil : obj["window_id"] as? String
                if target == "tab" {
                    result.sessionID = ctx.session
                }
                if let initial = obj["initial_windows"] as? [[String: Any]], let first = initial.first {
                    result.windowID = (first["window_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    if let ids = first["block_ids"] as? [String], let firstBlock = ids.first {
                        result.blockID = firstBlock
                    }
                }
                if let ids = obj["block_ids"] as? [String], let first = ids.first {
                    result.blockID = first
                }
            }
            // Publish a successful new session before journal/selection failures can
            // hide it. Never infer a session from a label or a failed create.
            if target == "session", createErr == nil, parseOK, !explicitJSONError, !(result.sessionID ?? "").isEmpty {
                Rex.recordLauncherCreation("", result.sessionID ?? "", label, p)
            }
            // Keep every returned ID, even when Rex reports an error.
            s.result = result
            // Truncated/unrecognized responses are not explicit failures, even if
            // the CLI exits nonzero. A transport error can also exit normally.
            let explicitFailure = out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (parseOK && explicitJSONError)
            let definite = cmdErr != nil
                && (((cmdErr!.isExitError && cmdErr!.exitedNormally && !uncertainTransport(cmdErr!)) || cmdErr!.isLaunchError))
            s.retryCreate = definite && explicitFailure
                && createdSessionID.isEmpty
                && (result.windowID ?? "").isEmpty
                && (result.blockID ?? "").isEmpty
            do {
                try save(p, s)
            } catch {
                throw bail(error)
            }
            if let e = createErr {
                if s.retryCreate ?? false {
                    throw bail(MessageError("Rex create failed; retry Open for authoritative reconciliation before another create: \(e)"))
                }
                throw bail(MessageError("Rex create uncertain; retry Open to reconcile: \(e)"))
            }
            if !parseOK || (result.sessionID ?? "").isEmpty || (result.windowID ?? "").isEmpty || (result.blockID ?? "").isEmpty {
                throw bail(MessageError("Rex returned incomplete IDs; retry Open to reconcile"))
            }
        }
        // Verify IDs and cwd before selecting. Never replace a missing destination silently.
        do {
            try verifyDestination(result)
        } catch {
            throw bail(error)
        }
        do {
            try Rex.doAction(client: ctx.client, action: "session.select",
                             kv: ["session_id=" + (result.sessionID ?? ""), "window_id=" + (result.windowID ?? "")])
        } catch {
            throw bail(error)
        }
        if (result.sessionID ?? "") != ctx.session {
            try? Rex.recordSessionUse("", ctx.session)
        }
        try? Rex.recordSessionUse("", result.sessionID ?? "")
        s.result = result
        s.released = true
        do {
            try save(p, s)
        } catch {
            throw bail(error)
        }
        return result
    }
}
