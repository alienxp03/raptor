import Foundation
import RaptorCatalog
import RaptorConfig
import RaptorPullrequest
import RaptorRex
import RaptorWorktree

/// Namespace for the ported internal/task package: the noninteractive
/// new-worktree → session → fresh Pi flow shared by the CLI and Rex action.
public enum RaptorTask {}

/// Start outcome. Session, window, and block IDs are
/// omitempty, so absent IDs stay nil.
public struct TaskResult: Codable, Equatable {
    public var path: String
    public var branch: String
    public var sessionID: String?
    public var windowID: String?
    public var blockID: String?

    public init(path: String = "", branch: String = "", sessionID: String? = nil, windowID: String? = nil, blockID: String? = nil) {
        self.path = path
        self.branch = branch
        self.sessionID = sessionID
        self.windowID = windowID
        self.blockID = blockID
    }

    enum CodingKeys: String, CodingKey {
        case path, branch
        case sessionID = "session_id"
        case windowID = "window_id"
        case blockID = "block_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        windowID = try c.decodeIfPresent(String.self, forKey: .windowID)
        blockID = try c.decodeIfPresent(String.self, forKey: .blockID)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(branch, forKey: .branch)
        if let sessionID, !sessionID.isEmpty { try c.encode(sessionID, forKey: .sessionID) }
        if let windowID, !windowID.isEmpty { try c.encode(windowID, forKey: .windowID) }
        if let blockID, !blockID.isEmpty { try c.encode(blockID, forKey: .blockID) }
    }
}

/// Thrown where Go returned (Result, error) from Start so recovery keeps the
/// preserved worktree and opened session IDs even on failure.
public struct StartError: Error, CustomStringConvertible {
    public let result: TaskResult
    public let cause: any Error
    public var description: String { String(describing: cause) }
}

/// Lenient rex window-new response: missing keys decode as Go zero values.
struct OpenedWindowResponse: Decodable {
    var windowID: String?
    var blockIDs: [String]?
    enum CodingKeys: String, CodingKey {
        case windowID = "window_id"
        case blockIDs = "block_ids"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windowID = try? c.decodeIfPresent(String.self, forKey: .windowID)
        blockIDs = try? c.decodeIfPresent([String].self, forKey: .blockIDs)
    }
}

struct OpenedSessionResponse: Decodable {
    var sessionID: String?
    var initialWindows: [OpenedWindowResponse]?
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case initialWindows = "initial_windows"
    }
}

public extension RaptorTask {
    /// Start preserves the worktree/session on later failure. resumePath reuses an
    /// existing registered worktree, avoiding another branch on a retry.
    static func start(ctx: Ctx, cfg: RaptorConfig, explicitRepo: String, resumePath: String, inSession: Bool = false) throws -> TaskResult {
        var result = TaskResult()
        func fail(_ error: any Error) -> StartError {
            StartError(result: result, cause: error)
        }
        if ctx.session.isEmpty {
            throw fail(MessageError("no session context"))
        }
        if ctx.client.isEmpty {
            throw fail(MessageError("no app client context; target the Rex app with -C"))
        }
        guard let pi = lookPath("pi") else {
            throw fail(MessageError("pi executable not found; install Pi on this host before creating a task"))
        }
        let repo: String
        do {
            repo = try Catalog.resolveRepo(ctx, explicitRepo)
        } catch {
            throw fail(error)
        }
        if repo.isEmpty {
            throw fail(MessageError("current pane is not in a Git repository"))
        }
        var tree = Worktree()
        var createdErr: (any Error)?
        if !resumePath.isEmpty {
            for existing in WorktreeKit.list(repo: repo) where canonical(existing.path) == canonical(resumePath) {
                tree = existing
                break
            }
            if tree.path.isEmpty {
                throw fail(MessageError("retry path is not a registered worktree of this repository: \(resumePath)"))
            }
        } else {
            let setup: LocalCreation
            do {
                setup = try Pullrequest.preflightLocal(source: repo)
            } catch {
                throw fail(error)
            }
            do {
                tree = try WorktreeKit.createTask(repo: repo, cfg: cfg)
            } catch let error as TaskCreateError {
                tree = error.tree
                createdErr = error.cause
            } catch {
                createdErr = error
            }
            if !tree.path.isEmpty {
                do {
                    try setup.register(path: tree.path, branch: tree.branch, base: "")
                } catch {
                    result.path = tree.path
                    result.branch = tree.branch
                    // Go formatted the creation error with %v; a nil error prints %!v(<nil>).
                    let creation = createdErr.map { String(describing: $0) } ?? "%!v(<nil>)"
                    throw fail(MessageError("worktree preserved at \(tree.path); creation error: \(creation); could not register setup: \(error)"))
                }
            }
            if let err = createdErr {
                result.path = tree.path
                result.branch = tree.branch
                if !tree.path.isEmpty {
                    throw fail(MessageError("worktree preserved at \(tree.path) (\(tree.branch)): \(err); inspect it before retrying"))
                }
                throw fail(err)
            }
        }
        result.path = tree.path
        result.branch = tree.branch
        // Rex quotes command arguments and uses the user's login environment. Pass
        // only the executable: no initial prompt, --resume, --fork, or shared session.
        let pending: Bool
        do {
            pending = try Pullrequest.localPending(tree.path)
        } catch {
            throw fail(error)
        }
        var command = [pi]
        if pending {
            var prior = OpenResult()
            var resumed = false
            do {
                let r = try Pullrequest.resumeLocal(path: tree.path, target: "task", ctx: ctx)
                prior = r.result
                resumed = r.handled
            } catch let error as ResumeError {
                prior = error.result
                resumed = error.handled
                result.sessionID = prior.sessionID
                result.windowID = prior.windowID
                result.blockID = prior.blockID
                throw fail(error)
            } catch {
                result.sessionID = prior.sessionID
                result.windowID = prior.windowID
                result.blockID = prior.blockID
                throw fail(error)
            }
            result.sessionID = prior.sessionID
            result.windowID = prior.windowID
            result.blockID = prior.blockID
            if resumed {
                return result
            }
            do {
                command = try Pullrequest.localStartup(path: tree.path, target: "task", after: pi)
            } catch {
                throw fail(error)
            }
        }
        let args = (inSession
            ? ["window", "new", "-s", ctx.session, tree.branch, "-c", tree.path, "--json", "--"]
            : ["new", tree.branch, "-c", tree.path, "--json", "--"]) + command
        var out = ""
        var createErr: (any Error)?
        do {
            out = try taskRexRun(args)
        } catch {
            createErr = error
        }
        let opened = Rex.decodeJSON(OpenedSessionResponse.self, from: Data(out.utf8))
        let window = inSession
            ? Rex.decodeJSON(OpenedWindowResponse.self, from: Data(out.utf8))
            : opened?.initialWindows?.first
        result.sessionID = inSession ? ctx.session : opened?.sessionID
        result.windowID = window?.windowID
        result.blockID = window?.blockIDs?.first
        if createErr == nil, let sessionID = result.sessionID, !sessionID.isEmpty {
            Rex.recordLauncherCreation("", sessionID, tree.branch, tree.path)
        }
        let destination = OpenResult(path: tree.path, sessionID: result.sessionID, windowID: result.windowID, blockID: result.blockID)
        if pending {
            do {
                try Pullrequest.localDestination(path: tree.path, result: destination, released: false)
            } catch {
                throw fail(error)
            }
        }
        if let err = createErr {
            throw fail(MessageError("worktree preserved at \(tree.path) (\(tree.branch)); could not open Pi session: \(err); retry with task --resume PATH"))
        }
        if window == nil || (result.sessionID ?? "").isEmpty || (result.windowID ?? "").isEmpty || (pending && (result.blockID ?? "").isEmpty) {
            throw fail(MessageError("worktree preserved at \(tree.path); session creation response was invalid; inspect the session before retrying"))
        }
        do {
            if inSession {
                _ = try taskRexRun(["session", "rename", ctx.session, tree.branch])
            }
            try Rex.doAction(client: ctx.client, action: "session.select",
                             kv: ["session_id=" + (result.sessionID ?? ""), "window_id=" + (result.windowID ?? "")])
        } catch {
            throw fail(MessageError("Pi session \(result.sessionID ?? "") and worktree \(tree.path) were created, but switching the app failed: \(error); select that session instead of creating another task"))
        }
        if pending {
            do {
                try Pullrequest.localDestination(path: tree.path, result: destination, released: true)
            } catch {
                throw fail(error)
            }
        }
        return result
    }
}

/// rex.Run's two-value shape: stdout survives nonzero exits for parsing.
func taskRexRun(_ args: [String]) throws -> String {
    let r = try Rex.runCmd(dir: "", timeout: 15, name: "rex", args: args)
    if r.code != 0 {
        throw RexError("rex \(args.joined(separator: " ")): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    return r.stdout
}

/// Go's task.canonical: abs then EvalSymlinks, degrading independently.
func canonical(_ path: String) -> String {
    guard let absolute = absPath(path) else { return pathClean(path) }
    if let real = evalSymlinks(absolute) { return real }
    return absolute
}
