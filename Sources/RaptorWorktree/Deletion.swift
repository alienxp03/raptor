import Foundation
import RaptorExecx

/// Commands must run on the same machine as the Rex session. No shell fallback.
public typealias DeletionCommand = (_ directory: String, _ name: String, _ arguments: [String]) throws -> ExecResult

public struct DeletionPlan: Equatable {
    public let repo: String
    public let path: String
    public let branch: String
    public let head: String
    public let registration: String
    public let commonDir: String
    public let defaultBranch: String
    public let defaultHead: String
    public let status: String
    public let diff: String
    public let fileHashes: String
    public let unmerged: Bool
    public var needsForce: Bool { !status.isEmpty || unmerged }
}

public struct DeletionOutcome {
    public var worktreeRemoved: Bool
    public var branchRemoved: Bool
    public var error: String?
}

public extension WorktreeKit {
    static func inspectDeletion(cwd: String, run: DeletionCommand) throws -> DeletionPlan {
        guard cwd.hasPrefix("/"), !cwd.contains("\0") else { throw MessageError("unknown session directory") }
        func command(_ dir: String, _ name: String, _ args: [String]) throws -> String {
            let result = try run(dir, name, args)
            guard result.ok else { throw MessageError("\(name): \(result.stderr) \(result.stdout)") }
            return result.stdout
        }
        func git(_ dir: String, _ args: [String]) throws -> String {
            try command(dir, "git", args).trimmingCharacters(in: .newlines)
        }
        let path = try git(cwd, ["rev-parse", "--show-toplevel"])
        let common = try git(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        let registration = try command(path, "git", ["worktree", "list", "--porcelain", "-z"])
        let records = registration.components(separatedBy: "\0\0").filter { !$0.isEmpty }
            .map { $0.components(separatedBy: "\0") }
        guard let primary = records.first?.first, primary.hasPrefix("worktree ") else {
            throw MessageError("unknown primary worktree")
        }
        let repo = String(primary.dropFirst(9))
        guard path != repo else { throw MessageError("primary worktree cannot be deleted") }
        let matches = records.filter { $0.first == "worktree " + path }
        guard matches.count == 1, let record = matches.first,
              !record.contains(where: { $0 == "locked" || $0.hasPrefix("locked ") || $0.hasPrefix("prunable") }) else {
            throw MessageError("worktree is not uniquely registered or is locked/prunable")
        }
        let ref = try git(path, ["symbolic-ref", "--quiet", "HEAD"])
        guard ref.hasPrefix("refs/heads/"), record.contains("branch " + ref),
              records.filter({ $0.contains("branch " + ref) }).count == 1 else {
            throw MessageError("worktree has no unique local Git branch")
        }
        let branch = String(ref.dropFirst(11))
        let head = try git(path, ["rev-parse", "--verify", "HEAD"])
        guard record.contains("HEAD " + head), try git(repo, ["rev-parse", "--verify", ref]) == head else {
            throw MessageError("worktree branch changed during inspection")
        }
        let listing = try command(repo, "wt", ["--config-set", "list.json-schema=2", "--config-set", "list.full=false", "list", "--format=json"])
        guard let object = try JSONSerialization.jsonObject(with: Data(listing.utf8)) as? [String: Any],
              let info = object["repo"] as? [String: Any], let base = info["default_branch"] as? String,
              !base.isEmpty else { throw MessageError("cannot determine Worktrunk default branch") }
        let defaultHead = try git(repo, ["rev-parse", "--verify", "refs/heads/" + base])
        let merged = try run(repo, "git", ["merge-base", "--is-ancestor", head, defaultHead])
        guard merged.code == 0 || merged.code == 1 else { throw MessageError("cannot check unmerged commits") }
        let status = try command(path, "git", ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored"])
        let diff = try command(path, "git", ["diff", "--no-ext-diff", "--no-textconv", "HEAD", "--"])
            + command(path, "git", ["diff", "--cached", "--no-ext-diff", "--no-textconv", "HEAD", "--"])
        // Git quotes unusual filenames for --stdin-paths. Hash in one host
        // command, not one Rex round trip per ignored dependency file. Check
        // each producer before the final digest; no pipe can hide a Git error.
        let fingerprint = """
        files=$(git -c core.quotePath=true ls-files --others) || exit $?
        hashes=''
        if [ -n "$files" ]; then
          hashes=$(printf '%s\\n' "$files" | git hash-object --stdin-paths --no-filters) || exit $?
        fi
        printf '%s\\n%s\\n' "$files" "$hashes" | git hash-object --stdin
        """
        let hashes = try command(path, "/bin/sh", ["-c", fingerprint])
        return DeletionPlan(repo: repo, path: path, branch: branch, head: head, registration: registration,
                            commonDir: common, defaultBranch: base, defaultHead: defaultHead,
                            status: status, diff: diff, fileHashes: hashes, unmerged: merged.code == 1)
    }

    /// Call only with a freshly revalidated plan. Worktrunk owns both removals;
    /// no Git branch-delete, remote operations, hooks, or filesystem deletion.
    static func executeDeletion(_ plan: DeletionPlan, force: Bool, run: DeletionCommand) -> DeletionOutcome {
        do {
            guard try inspectDeletion(cwd: plan.path, run: run) == plan else {
                throw MessageError("worktree state changed; preview again")
            }
        } catch {
            return DeletionOutcome(worktreeRemoved: false, branchRemoved: false,
                                   error: "final worktree validation failed: \(error)")
        }
        guard force || !plan.needsForce else {
            return DeletionOutcome(worktreeRemoved: false, branchRemoved: false,
                                   error: "worktree has dirty/ignored files or unmerged commits")
        }
        var args = ["remove", "--foreground", "--format=json", "--no-hooks", "--yes"]
        if force { args += ["--force", "--force-delete"] }
        args += ["--", plan.path]
        var diagnostic: String?
        do {
            let result = try run(plan.repo, "wt", args)
            let whole = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
            let objects = (whole as? [[String: Any]]) ?? (whole as? [String: Any]).map { [$0] } ?? result.stdout.split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
            let object = objects.first { $0["path"] as? String == plan.path && $0["branch"] as? String == plan.branch }
            if !result.ok || object?["branch_outcome"] as? String != "deleted" {
                diagnostic = "Worktrunk removal incomplete: \(object?["branch_outcome"] as? String ?? "unknown outcome"). \(result.stderr) \(result.stdout)"
            }
        } catch { diagnostic = "Worktrunk removal failed: \(error)" }
        // Check actual resources even on a timeout or a malformed result. Never
        // turn a partially removed worktree into an unsafe Force retry.
        do {
            let listing = try run(plan.repo, "git", ["worktree", "list", "--porcelain", "-z"])
            guard listing.ok, listing.stdout.hasPrefix("worktree " + plan.repo + "\0") else {
                throw MessageError("cannot verify worktree removal")
            }
            let exists = try run(plan.repo, "test", ["-e", plan.path])
            let symlink = try run(plan.repo, "test", ["-L", plan.path])
            guard [0, 1].contains(exists.code), [0, 1].contains(symlink.code) else {
                throw MessageError("cannot verify worktree directory removal")
            }
            let removed = !listing.stdout.components(separatedBy: "\0").contains("worktree " + plan.path)
                && exists.code == 1 && symlink.code == 1
            let branch = try run(plan.repo, "git", ["show-ref", "--verify", "--quiet", "refs/heads/" + plan.branch])
            guard branch.code == 0 || branch.code == 1 else { throw MessageError("cannot verify branch removal") }
            let branchRemoved = branch.code == 1
            if !removed || !branchRemoved {
                diagnostic = diagnostic ?? "Worktrunk retained the worktree or local branch"
            }
            return DeletionOutcome(worktreeRemoved: removed, branchRemoved: branchRemoved, error: diagnostic)
        } catch {
            return DeletionOutcome(worktreeRemoved: false, branchRemoved: false,
                                   error: "\(diagnostic ?? "removal returned"); verification failed: \(error)")
        }
    }
}
