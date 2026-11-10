import Foundation
import RaptorConfig
import RaptorPaths
import RaptorPullrequest
import RaptorRex

/// Namespace for the ported internal/dispatch package: open-target dispatch
/// (session/tab/here/pane) plus previous-location recording.
public enum RaptorDispatch {}

/// Thrown where Go returned (result, error) from DispatchResult so recovery
/// keeps every resource identity even if selection fails.
public struct DispatchError: Error, CustomStringConvertible {
    public let result: OpenResult
    public let cause: any Error
    public var description: String { String(describing: cause) }
}

/// Lenient rex JSON responses: missing keys decode as Go zero values.
struct NewSessionResponse: Decodable {
    var sessionID: String?
    enum CodingKeys: String, CodingKey { case sessionID = "session_id" }
    init(from decoder: Decoder) throws {
        sessionID = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .sessionID)
    }
}

struct NewWindowResponse: Decodable {
    var windowID: String?
    enum CodingKeys: String, CodingKey { case windowID = "window_id" }
    init(from decoder: Decoder) throws {
        windowID = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .windowID)
    }
}

struct SplitResponse: Decodable {
    var blockIDs: [String]?
    enum CodingKeys: String, CodingKey { case blockIDs = "block_ids" }
    init(from decoder: Decoder) throws {
        blockIDs = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([String].self, forKey: .blockIDs)
    }
}

struct BlockPlacementResponse: Decodable {
    struct Block: Decodable {
        var windowID: String?
        enum CodingKeys: String, CodingKey { case windowID = "window_id" }
        init(from decoder: Decoder) throws {
            windowID = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .windowID)
        }
    }
    var block: Block?
    enum CodingKeys: String, CodingKey { case block }
    init(from decoder: Decoder) throws {
        block = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Block.self, forKey: .block)
    }
}

/// rex.Run's two-value shape: stdout survives nonzero exits for parsing.
func rexRun(_ args: [String]) throws -> String {
    let r = try Rex.runCmd(dir: "", timeout: 15, name: "rex", args: args)
    if r.code != 0 {
        throw RexError("rex \(args.joined(separator: " ")): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    return r.stdout
}

public extension RaptorDispatch {
    /// Dispatch opens dir with the given target, mirroring the old shell script.
    static func dispatch(target: String, dir: String, ctx: Ctx, cfg: RaptorConfig) throws {
        _ = try dispatchResult(target: target, dir: dir, ctx: ctx, cfg: cfg)
    }

    /// DispatchResult retains exact resource identities even if selection fails.
    static func dispatchResult(target: String, dir: String, ctx: Ctx, cfg: RaptorConfig) throws -> OpenResult {
        var result = OpenResult(path: dir)
        do {
            try dispatchInto(target: target, dir: dir, ctx: ctx, cfg: cfg, result: &result)
            return result
        } catch {
            throw DispatchError(result: result, cause: error)
        }
    }
}

extension RaptorDispatch {
    static func dispatchInto(target: String, dir: String, ctx: Ctx, cfg: RaptorConfig, result: inout OpenResult) throws {
        let pending = try Pullrequest.localPending(dir)
        if pending && (target == "session" || target == "tab") {
            do {
                result = try Pullrequest.open(path: dir, target: target, ctx: ctx)
            } catch let error as OpenError {
                result = error.result
                throw RexError("worktree preserved at \(dir); setup destination: \(error)")
            } catch {
                result = OpenResult()
                throw RexError("worktree preserved at \(dir); setup destination: \(error)")
            }
            return
        }
        if pending && target == "here" {
            throw RexError("worktree preserved at \(dir); setup pending: choose Session or Tab; setup cannot be injected Here")
        }
        switch target {
        case "session":
            if ctx.client.isEmpty {
                throw RexError("no client context")
            }
            let name = RaptorPaths.basename(dir)
            var sid = Rex.sessionByLabel(name) ?? ""
            if sid.isEmpty {
                let out = try rexRun(["new", "--json", "-c", dir, name])
                let res = Rex.decodeJSON(NewSessionResponse.self, from: Data(out.utf8))
                guard let created = res?.sessionID, !created.isEmpty else {
                    throw RexError("could not create session for \(dir)")
                }
                sid = created
                Rex.recordLauncherCreation("", sid, name, dir)
            }
            result.sessionID = sid
            try Rex.selectSession(ctx, sid)
            return

        case "tab":
            if ctx.session.isEmpty {
                throw RexError("no session context")
            }
            let out = try rexRun(["window", "new", "-s", ctx.session, RaptorPaths.basename(dir), "-c", dir, "--json"])
            let res = Rex.decodeJSON(NewWindowResponse.self, from: Data(out.utf8))
            guard let windowID = res?.windowID, !windowID.isEmpty else {
                throw RexError("could not identify the new tab")
            }
            result.sessionID = ctx.session
            result.windowID = windowID
            if !ctx.client.isEmpty {
                try Rex.doAction(client: ctx.client, action: "session.select",
                                 kv: ["session_id=" + ctx.session, "window_id=" + windowID])
            } else {
                _ = try Rex.run("focus", "-s", ctx.session, windowID)
            }
            return

        case "pane_right", "pane_below":
            if ctx.block.isEmpty {
                throw RexError("no block context")
            }
            if pending {
                do {
                    let (_, handled) = try Pullrequest.resumeLocal(path: dir, target: target, ctx: ctx)
                    if handled { return }
                } catch let error as ResumeError {
                    throw error
                }
            }
            let dirFlag = "--split=" + splitDirection(target)
            var args = ["split", "-s", ctx.session, "-b", ctx.block, dirFlag, "-c", dir, "--json"]
            if pending {
                let startup = try Pullrequest.localStartup(path: dir, target: target)
                args.append("--")
                args.append(contentsOf: startup)
            }
            var out = ""
            var createErr: (any Error)?
            do {
                out = try rexRun(args)
            } catch {
                createErr = error
            }
            let res = Rex.decodeJSON(SplitResponse.self, from: Data(out.utf8))
            var destination = OpenResult(path: dir, sessionID: ctx.session)
            if let first = res?.blockIDs?.first {
                destination.blockID = first
            }
            if pending {
                try Pullrequest.localDestination(path: dir, result: destination, released: false)
            }
            if let err = createErr {
                if pending {
                    throw RexError("worktree preserved at \(dir); pane creation uncertain; inspect Rex before retrying: \(err)")
                }
                throw err
            }
            guard let blockIDs = res?.blockIDs, !blockIDs.isEmpty else {
                throw RexError("could not identify the new pane; inspect Rex before retrying")
            }
            _ = try Rex.run("focus", "-s", ctx.session, blockIDs[0])
            if !ctx.client.isEmpty || pending {
                // Server focus alone does not select the pane's window on the
                // requesting app, particularly while the native picker has focus.
                let payload = Rex.marshalSorted(["block_id": blockIDs[0]])
                let describeOut = try rexRun(["api", "call", "-s", ctx.session, "session.describe_block", payload])
                let placement = Rex.decodeJSON(BlockPlacementResponse.self, from: Data(describeOut.utf8))
                guard let windowID = placement?.block?.windowID, !windowID.isEmpty else {
                    throw RexError("could not identify the new pane's window")
                }
                destination.windowID = windowID
                if pending {
                    try Pullrequest.localDestination(path: dir, result: destination, released: false)
                }
                if !ctx.client.isEmpty {
                    try Rex.doAction(client: ctx.client, action: "session.select",
                                     kv: ["session_id=" + ctx.session, "window_id=" + windowID])
                }
            }
            if pending {
                try Pullrequest.localDestination(path: dir, result: destination, released: true)
            }
            return

        case "here":
            if ctx.block.isEmpty {
                throw RexError("no block context")
            }
            let shell = Rex.blockForeground(ctx.block)
            switch shell {
            case "zsh", "bash", "sh", "dash", "ksh", "fish", "nu", "elvish":
                let command = try shellCD(shell, dir)
                _ = try Rex.run("send", "-b", ctx.block, command)
                return
            default:
                throw RexError("pane is not at a shell prompt")
            }

        default:
            throw RexError("unknown target \(Rex.jsonQuote(target))")
        }
    }

    /// shellCD quotes paths as data, never as executable shell input.
    static func shellCD(_ shell: String, _ dir: String) throws -> String {
        if containsControlCharacter(dir) {
            throw RexError("directory contains terminal control characters")
        }
        if shell == "nu" || shell == "elvish" {
            // These shells do not use POSIX quote concatenation. Keep their existing
            // simple-path support, but do not guess an escaping syntax.
            if dir.contains("'") {
                throw RexError("directory contains quotes unsupported by cd here in \(shell); use a new tab")
            }
            var d = dir
            if d.hasPrefix("-") {
                d = "./" + d
            }
            return "cd '" + d + "'\n"
        }
        return "cd -- '" + dir.replacingOccurrences(of: "'", with: "'\\''") + "'\n"
    }

    /// Go's unicode.IsControl (the Cc category).
    static func containsControlCharacter(_ s: String) -> Bool {
        for c in s.unicodeScalars where c.value < 0x20 || (0x7f...0x9f).contains(c.value) {
            return true
        }
        return false
    }
}
