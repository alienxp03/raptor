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
    public var needsForce: Bool { hasChanges || unmerged }
    public var hasChanges: Bool { statusKinds.changes }
    public var hasIgnoredFiles: Bool { statusKinds.ignored }

    private var statusKinds: (changes: Bool, ignored: Bool) {
        let records = status.split(separator: "\0")
        var changes = false, ignored = false, index = 0
        while index < records.count {
            let code = records[index].prefix(2)
            index += 1
            if code == "!!" { ignored = true }
            else {
                changes = true
                // Porcelain -z includes a second path for renames/copies.
                if code.contains("R") || code.contains("C") { index += 1 }
            }
        }
        return (changes, ignored)
    }

    /// Only registrations removed by this operation may differ from the preview.
    public func accountingForDeletedWorktrees(_ paths: Set<String>) -> DeletionPlan {
        let records = registration.components(separatedBy: "\0\0").filter { record in
            !paths.contains(where: { record.hasPrefix("worktree " + $0 + "\0") })
        }
        return DeletionPlan(repo: repo, path: path, branch: branch, head: head,
                            registration: records.joined(separator: "\0\0"), commonDir: commonDir,
                            defaultBranch: defaultBranch, defaultHead: defaultHead, status: status,
                            diff: diff, fileHashes: fileHashes, unmerged: unmerged)
    }
}

public struct DeletionOutcome {
    public var worktreeRemoved: Bool
    public var branchRemoved: Bool
    public var error: String?
}

public extension WorktreeKit {
    static func inspectDeletion(cwd: String, run: DeletionCommand) throws -> DeletionPlan {
        guard cwd.hasPrefix("/"), !cwd.contains("\0") else { throw MessageError("unknown session directory") }
        // Nine base64 lines, including empty fields. pipefail and errexit make
        // producer failures fatal; stdout contains no diagnostics or shell data.
        let snapshot = """
        set -e
        export GIT_OPTIONAL_LOCKS=0
        emit() { "$@" | base64 | tr -d '\\n'; printf '\\n'; }
        root=$(git rev-parse --show-toplevel && printf '.')
        root=${root%.}
        root=${root%$'\\n'}
        cd -- "$root"
        emit printf '%s' "$root"
        emit git rev-parse --path-format=absolute --git-common-dir
        emit git worktree list --porcelain -z
        symbolic_ref() { git symbolic-ref --quiet HEAD || { code=$?; [ "$code" -eq 1 ]; }; }
        emit symbolic_ref
        emit git rev-parse --verify HEAD
        local_refs() { git show-ref --heads || { code=$?; [ "$code" -eq 1 ]; }; }
        emit local_refs
        emit wt --config-set list.json-schema=2 --config-set list.full=false list --format=json
        emit git status --porcelain=v1 -z --untracked-files=normal
        emit find . -path ./.git -prune -o -name .git -print -quit
        """
        let result = try run(cwd, "/bin/bash", ["-o", "pipefail", "-c", snapshot])
        guard result.ok else { throw MessageError("worktree snapshot: \(result.stderr) \(result.stdout)") }
        var lines = result.stdout.components(separatedBy: "\n")
        // Require the final terminator as well as all nine fields.
        guard lines.count == 10, lines.removeLast().isEmpty else {
            throw MessageError("incomplete worktree snapshot")
        }
        let fields = try lines.map { line -> String in
            guard let data = Data(base64Encoded: line), data.base64EncodedString() == line,
                  let value = String(data: data, encoding: .utf8) else {
                throw MessageError("malformed worktree snapshot")
            }
            return value
        }
        func scalar(_ index: Int) -> String {
            fields[index].hasSuffix("\n") ? String(fields[index].dropLast()) : fields[index]
        }
        let path = fields[0]
        let common = scalar(1)
        guard path.hasPrefix("/"), common.hasPrefix("/"),
              !path.contains("\0"), !common.contains("\0") else {
            throw MessageError("invalid worktree snapshot paths")
        }
        let registration = fields[2]
        guard registration.hasSuffix("\0\0") else { throw MessageError("incomplete worktree registration") }
        let records = registration.components(separatedBy: "\0\0").filter { !$0.isEmpty }
            .map { $0.components(separatedBy: "\0") }
        guard let primary = records.first?.first, primary.hasPrefix("worktree ") else {
            throw MessageError("unknown primary worktree")
        }
        let repo = String(primary.dropFirst(9))
        guard path != repo else {
            if let ref = records.first?.first(where: { $0.hasPrefix("branch refs/heads/") }) {
                let branch = String(ref.dropFirst("branch refs/heads/".count))
                throw MessageError("Cannot delete branch `\(branch)`.")
            }
            throw MessageError("Cannot delete the primary worktree (detached HEAD).")
        }
        let matches = records.filter { $0.first == "worktree " + path }
        guard matches.count == 1, let record = matches.first,
              !record.contains(where: { $0 == "locked" || $0.hasPrefix("locked ") || $0.hasPrefix("prunable") }) else {
            throw MessageError("worktree is not uniquely registered or is locked/prunable")
        }
        let ref = scalar(3)
        guard ref.hasPrefix("refs/heads/"), record.contains("branch " + ref),
              records.filter({ $0.contains("branch " + ref) }).count == 1 else {
            throw MessageError("worktree has no unique local Git branch")
        }
        let branch = String(ref.dropFirst(11))
        // A nested checkout may have no Rex pane and can belong to another
        // repository. Never let Force remove its Git metadata through a parent.
        let nested = scalar(8)
        guard nested.isEmpty else {
            throw MessageError("Cannot delete this worktree: nested Git metadata found at `\(nested)`.")
        }
        let head = scalar(4)
        var refs: [String: String] = [:]
        for line in fields[5].split(separator: "\n") {
            let pair = line.split(separator: " ", omittingEmptySubsequences: false)
            guard pair.count == 2, pair[1].hasPrefix("refs/heads/"), refs[String(pair[1])] == nil else {
                throw MessageError("malformed local branch snapshot")
            }
            refs[String(pair[1])] = String(pair[0])
        }
        guard !head.isEmpty, record.contains("HEAD " + head), refs[ref] == head else {
            throw MessageError("worktree branch changed during inspection")
        }
        guard let object = try JSONSerialization.jsonObject(with: Data(fields[6].utf8)) as? [String: Any],
              object["schema"] as? Int == 2,
              let info = object["repo"] as? [String: Any], let base = info["default_branch"] as? String,
              !base.isEmpty, let defaultHead = refs["refs/heads/" + base] else {
            throw MessageError("cannot determine Worktrunk default branch")
        }
        let rows = (object["items"] as? [[String: Any]] ?? []).filter {
            ($0["worktree"] as? [String: Any])?["path"] as? String == path
        }
        guard rows.count == 1, let row = rows.first, row["branch"] as? String == branch,
              (row["head"] as? [String: Any])?["sha"] as? String == head else {
            throw MessageError("Worktrunk worktree identity changed during inspection")
        }
        let relation = row["default_branch"] as? [String: Any]
        let integration = relation?["integration"] as? [String: Any]
        // Never infer integration from display.state: dirty trees can still
        // have integrated commits. Missing/unknown checks require Force.
        let reasons: Set<String> = ["same_commit", "ancestor", "no_added_changes", "trees_match", "merge_adds_nothing", "patch_id_match"]
        let integrated = (integration?["reason"] as? String).map { reasons.contains($0) } ?? false
        return DeletionPlan(repo: repo, path: path, branch: branch, head: head, registration: registration,
                            commonDir: common, defaultBranch: base, defaultHead: defaultHead,
                            status: fields[7], diff: "", fileHashes: "", unmerged: !integrated)
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
                                   error: "worktree has uncommitted changes or unmerged commits")
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
        var worktreeRemoved = false
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
            worktreeRemoved = removed
            let branch = try run(plan.repo, "git", ["show-ref", "--verify", "--quiet", "refs/heads/" + plan.branch])
            guard branch.code == 0 || branch.code == 1 else { throw MessageError("cannot verify branch removal") }
            let branchRemoved = branch.code == 1
            if !removed || !branchRemoved {
                diagnostic = diagnostic ?? "Worktrunk retained the worktree or local branch"
            }
            return DeletionOutcome(worktreeRemoved: removed, branchRemoved: branchRemoved, error: diagnostic)
        } catch {
            return DeletionOutcome(worktreeRemoved: worktreeRemoved, branchRemoved: false,
                                   error: "\(diagnostic ?? "removal returned"); verification failed: \(error)")
        }
    }
}
