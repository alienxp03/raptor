import Foundation
import RaptorCatalog
import RaptorConfig
import RaptorPullrequest
import RaptorRex
import RaptorWorktree

/// Namespace for the ported internal/task package: the noninteractive
/// new-worktree → tab → fresh Pi flow shared by the CLI and Rex action.
public enum RaptorTask {}

/// Start outcome. Mirrors Go's Result JSON tags; window_id/block_id are
/// omitempty, so absent IDs stay nil.
public struct TaskResult: Codable, Equatable {
    public var path: String
    public var branch: String
    public var windowID: String?
    public var blockID: String?

    public init(path: String = "", branch: String = "", windowID: String? = nil, blockID: String? = nil) {
        self.path = path
        self.branch = branch
        self.windowID = windowID
        self.blockID = blockID
    }

    enum CodingKeys: String, CodingKey {
        case path, branch
        case windowID = "window_id"
        case blockID = "block_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        windowID = try c.decodeIfPresent(String.self, forKey: .windowID)
        blockID = try c.decodeIfPresent(String.self, forKey: .blockID)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(branch, forKey: .branch)
        if let windowID, !windowID.isEmpty { try c.encode(windowID, forKey: .windowID) }
        if let blockID, !blockID.isEmpty { try c.encode(blockID, forKey: .blockID) }
    }
}

/// Thrown where Go returned (Result, error) from Start so recovery keeps the
/// preserved worktree and opened tab IDs even on failure.
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

public extension RaptorTask {
    /// Start preserves the worktree/tab on later failure. resumePath reuses an
    /// existing registered worktree, avoiding another branch on a retry.
    static func start(ctx: Ctx, cfg: RaptorConfig, explicitRepo: String, resumePath: String) throws -> TaskResult {
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
                result.windowID = prior.windowID
                result.blockID = prior.blockID
                throw fail(error)
            } catch {
                result.windowID = prior.windowID
                result.blockID = prior.blockID
                throw fail(error)
            }
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
        let args = ["window", "new", "-s", ctx.session, tree.branch, "-c", tree.path, "--json", "--"] + command
        var out = ""
        var createErr: (any Error)?
        do {
            out = try taskRexRun(args)
        } catch {
            createErr = error
        }
        let opened = Rex.decodeJSON(OpenedWindowResponse.self, from: Data(out.utf8))
        result.windowID = opened?.windowID ?? ""
        if let first = opened?.blockIDs?.first {
            result.blockID = first
        }
        let destination = OpenResult(path: tree.path, sessionID: ctx.session, windowID: result.windowID, blockID: result.blockID)
        if pending {
            do {
                try Pullrequest.localDestination(path: tree.path, result: destination, released: false)
            } catch {
                throw fail(error)
            }
        }
        if let err = createErr {
            throw fail(MessageError("worktree preserved at \(tree.path) (\(tree.branch)); could not open Pi tab: \(err); retry with task --resume PATH"))
        }
        if opened == nil || (result.windowID ?? "").isEmpty || (pending && (result.blockID ?? "").isEmpty) {
            throw fail(MessageError("worktree preserved at \(tree.path); tab creation response was invalid; inspect the session before retrying"))
        }
        do {
            try Rex.doAction(client: ctx.client, action: "session.select",
                             kv: ["session_id=" + ctx.session, "window_id=" + (opened?.windowID ?? "")])
        } catch {
            throw fail(MessageError("Pi tab \(opened?.windowID ?? "") and worktree \(tree.path) were created, but switching the app failed: \(error); select that tab instead of creating another task"))
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
