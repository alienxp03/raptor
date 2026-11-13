import Foundation
import RaptorConfig
import RaptorExecx

/// CreateTask outcome for Go's `(Worktree, error)` with a non-empty worktree
/// preserved on failure: recovery needs the registered tree even on error.
public struct TaskCreateError: Error, CustomStringConvertible {
    public let tree: Worktree
    public let cause: any Error
    public init(tree: Worktree, cause: any Error) {
        self.tree = tree
        self.cause = cause
    }
    public var description: String { String(describing: cause) }
}

/// Task worktree creation: names are generated, validated, and never overwrite
/// an existing branch or destination. Ported from internal/worktree/task.go.
extension WorktreeKit {
    /// Starts from the origin worktree's committed HEAD, including when
    /// detached. Dirty files stay in the original worktree.
    ///
    /// Skips Worktrunk hooks. Callers must arrange visible setup for a new
    /// worktree, and preserve a non-empty returned worktree even on error
    /// (thrown as TaskCreateError).
    public static func createTask(repo: String, cfg: RaptorConfig) throws -> Worktree {
        try createTask(repo: repo, cfg: cfg, names: taskNamePairs(shuffledTaskWords()))
    }

    /// Returns an available task name without claiming it or changing the
    /// repository or filesystem. Creation must still validate the name.
    public static func suggestTaskName(repo: String, cfg: RaptorConfig) throws -> String {
        try suggestTaskName(repo: repo, cfg: cfg, names: taskNamePairs(shuffledTaskWords()))
    }

    /// Provisional form suggestion using only refs the caller already read.
    /// Does not inspect HEAD, destinations, or the filesystem; preview and create
    /// must still perform fresh, full validation. Empty means no candidate remains.
    public static func suggestTaskNameFast(branches: [String]) -> String {
        suggestTaskNameFast(branches: branches, names: taskNamePairs(shuffledTaskWords()))
    }

    static func suggestTaskNameFast(branches: [String], names: [String]) -> String {
        let existing = Set(branches)
        var blocked = existing
        for branch in branches {
            var prefix = ""
            for component in branch.split(separator: "/").dropLast() {
                prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
                blocked.insert(prefix)
            }
        }
        return names.first { candidate in
            if blocked.contains(candidate) { return false }
            var prefix = ""
            for component in candidate.split(separator: "/").dropLast() {
                prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
                if existing.contains(prefix) { return false }
            }
            return true
        } ?? ""
    }

    static func suggestTaskName(repo: String, cfg: RaptorConfig, names: [String]) throws -> String {
        _ = try taskHEAD(repo: repo)
        let blocked = try taskBlockedBranches(repo: repo)
        for branch in names {
            let path = try taskDestination(repo: repo, branch: branch, cfg: cfg, blocked: blocked)
            if !path.isEmpty { return branch }
        }
        throw MessageError(taskNamesExhausted(names.count))
    }

    /// Shuffle once so collisions always try another pair, never a suffix or a
    /// repeated candidate. Each name joins a word from each half of the shuffled
    /// list, so every word is used at most once and every pair is considered
    /// before declaring exhaustion.
    static func taskNamePairs(_ words: [String]) -> [String] {
        let half = words.count / 2
        var pairs: [String] = []
        pairs.reserveCapacity(half)
        for i in 0..<half {
            pairs.append(words[i] + "-" + words[i + half])
        }
        return pairs
    }

    /// Cryptographically seeded Fisher-Yates, like crypto/rand in Go.
    static func shuffledTaskWords() -> [String] {
        var names = taskWordList.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var rng = SystemRandomNumberGenerator()
        if names.count > 1 {
            for i in stride(from: names.count - 1, through: 1, by: -1) {
                names.swapAt(i, Int.random(in: 0...i, using: &rng))
            }
        }
        return names
    }

    static func taskHEAD(repo: String) throws -> String {
        do {
            return try gitOut(dir: repo, args: ["rev-parse", "--verify", "HEAD^{commit}"])
        } catch {
            throw MessageError("repository needs a committed HEAD: \(error)")
        }
    }

    /// Read refs with errors intact: a failed read must not suggest a taken name.
    static func taskBlockedBranches(repo: String) throws -> Set<String> {
        let out = try gitOut(dir: repo, args: ["for-each-ref", "--format=%(refname:strip=2)", "refs/heads/"])
        var blocked = Set<String>()
        for existing in out.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            blocked.insert(existing)
            // A branch such as otter/topic also prevents creating the word otter.
            if let slash = existing.firstIndex(of: "/") {
                blocked.insert(String(existing[existing.startIndex..<slash]))
            }
        }
        return blocked
    }

    /// An empty destination means a collision or invalid candidate. Lstat also
    /// rejects dangling symlinks; other filesystem errors stop selection.
    static func taskDestination(repo: String, branch: String, cfg: RaptorConfig, blocked: Set<String>) throws -> String {
        if blocked.contains(branch) { return "" }
        do {
            try validateNewBranch(repo: repo, branch: branch)
        } catch {
            return ""
        }
        let path = try previewPath(repo: repo, branch: branch)
        if try lstatExists(path) { return "" }
        return path
    }

    static func taskNamesExhausted(_ count: Int) -> String {
        "all \(count) two-word branch names are taken by existing branches or destinations"
    }

    static func createTask(repo: String, cfg: RaptorConfig, names: [String]) throws -> Worktree {
        let head = try taskHEAD(repo: repo)
        let blocked = try taskBlockedBranches(repo: repo)
        for branch in names {
            let path = try taskDestination(repo: repo, branch: branch, cfg: cfg, blocked: blocked)
            if path.isEmpty { continue }
            let outcome = switchWorktree(repo: repo, args: ["--create", branch, "--base", head])
            if let err = outcome.error {
                if outcome.created {
                    throw TaskCreateError(tree: outcome.tree, cause: MessageError("create task worktree: \(err)"))
                }
                // Another shortcut/process can claim a name between validation and
                // creation. Git is the final arbiter; never overwrite its result.
                let text = String(describing: err)
                if text.contains("already exists") || text.contains("exists; cannot create") {
                    continue
                }
                throw MessageError("create task worktree: \(err)")
            }
            return outcome.tree
        }
        throw MessageError(taskNamesExhausted(names.count))
    }
}
