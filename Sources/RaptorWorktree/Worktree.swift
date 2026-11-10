import Foundation
import RaptorConfig
import RaptorExecx

/// A registered git worktree. Ported from internal/worktree/worktree.go.
public struct Worktree: Equatable {
    public var path: String
    public var branch: String
    public var isMain: Bool

    public init(path: String = "", branch: String = "", isMain: Bool = false) {
        self.path = path
        self.branch = branch
        self.isMain = isMain
    }
}

/// Worktrunk-backed worktree operations. Ported from internal/worktree.
public enum WorktreeKit {
    /// Runs git in `dir`, returning trimmed stdout. Non-zero exits throw the
    /// trimmed stderr as the error message.
    public static func gitOut(dir: String, args: [String]) throws -> String {
        let r = try Execx.run(dir: dir, timeout: 10, name: "git", args: args)
        if r.code != 0 {
            throw MessageError(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func repoRoot(dir: String) -> String {
        var d = dir
        if d.isEmpty { d = FileManager.default.currentDirectoryPath }
        return (try? gitOut(dir: d, args: ["rev-parse", "--show-toplevel"])) ?? ""
    }

    public static func isGitRepo(dir: String) -> Bool { repoRoot(dir: dir) != "" }

    /// Best-effort listing: errors collapse to an empty result, like Go's List.
    public static func list(repo: String) -> [Worktree] {
        (try? listWorktrees(repo: repo)) ?? []
    }

    static func listWorktrees(repo: String) throws -> [Worktree] {
        let out = try gitOut(dir: repo, args: ["worktree", "list", "--porcelain", "-z"])
        var result: [Worktree] = []
        var current = -1
        for field in out.split(separator: "\0", omittingEmptySubsequences: false).map(String.init) {
            if field.hasPrefix("worktree ") {
                result.append(Worktree(path: String(field.dropFirst("worktree ".count)), isMain: result.isEmpty))
                current = result.count - 1
            } else if current >= 0, field.hasPrefix("branch ") {
                result[current].branch = field.hasPrefix("branch refs/heads/")
                    ? String(field.dropFirst("branch refs/heads/".count))
                    : field
            } else if current >= 0, field.hasPrefix("HEAD ") {
                var hash = String(field.dropFirst("HEAD ".count))
                if hash.count > 7 { hash = String(hash.prefix(7)) }
                result[current].branch = "detached " + hash
            }
        }
        return result
    }

    /// feat/x -> feature-x; every remaining slash becomes a dash.
    public static func folder(_ branch: String) -> String {
        var b = branch
        if b.hasPrefix("feat/") { b = "feature/" + String(b.dropFirst("feat/".count)) }
        return b.replacingOccurrences(of: "/", with: "-")
    }

    /// Leading dots are stripped; a fully dotted name falls back to "repository".
    public static func repoFolder(_ name: String) -> String {
        var n = name
        while n.hasPrefix(".") { n.removeFirst() }
        if n.isEmpty { return "repository" }
        return n
    }

    /// Compatibility wrapper. Use previewPath to retain preview errors.
    /// cfg.worktreeRoot is intentionally ignored: Worktrunk owns destination rules.
    public static func path(repo: String, branch: String, cfg: RaptorConfig) -> String {
        (try? previewPath(repo: repo, branch: branch)) ?? ""
    }

    public static func validateNewBranch(repo: String, branch: String) throws {
        if branch.isEmpty { throw MessageError("enter a branch name") }
        do {
            _ = try gitOut(dir: repo, args: ["check-ref-format", "--branch", branch])
        } catch {
            throw MessageError("invalid branch name: \(branch)")
        }
        if (try? gitOut(dir: repo, args: ["show-ref", "--verify", "--quiet", "refs/heads/" + branch])) != nil {
            throw MessageError("branch already exists: \(branch)")
        }
    }

    public static func validate(repo: String, branch: String, base: String, path: String) throws {
        try validateNewBranch(repo: repo, branch: branch)
        if base.isEmpty { throw MessageError("choose a local base branch") }
        do {
            _ = try gitOut(dir: repo, args: ["show-ref", "--verify", "--quiet", "refs/heads/" + base])
        } catch {
            throw MessageError("local base branch not found: \(base)")
        }
        let destination = try previewPath(repo: repo, branch: branch)
        if !path.isEmpty && path != destination {
            throw MessageError("destination differs from Worktrunk configuration: \(path) (expected \(destination))")
        }
        let p = destination
        if try lstatExists(p) {
            throw MessageError("destination already exists: \(p)")
        }
        for w in list(repo: repo) where w.path == p {
            throw MessageError("destination is already registered as a worktree")
        }
    }

    /// Creates through Worktrunk without hooks. Callers must run any approved
    /// setup visibly in the destination terminal, not behind the picker.
    /// path is a compatibility assertion, never a Worktrunk path override.
    public static func createLocal(repo: String, branch: String, base: String, path: String) throws {
        try validate(repo: repo, branch: branch, base: base, path: path)
        let outcome = switchWorktree(repo: repo, args: ["--create", branch, "--base", base])
        if let error = outcome.error { throw error }
    }

    public static func remove(repo: String, tree: Worktree) throws {
        if tree.isMain {
            throw MessageError("cannot remove the primary worktree")
        }
        // No force or branch deletion. Wait until removal finishes before refreshing.
        _ = try wtOut(repo: repo, args: ["remove", "--no-delete-branch", "--foreground", tree.path])
    }

    public static func localBranches(repo: String) -> [String] {
        let out = (try? gitOut(dir: repo, args: ["for-each-ref", "--format=%(refname:short)", "refs/heads/"])) ?? ""
        if out.isEmpty { return [] }
        return out.components(separatedBy: "\n")
    }
}
