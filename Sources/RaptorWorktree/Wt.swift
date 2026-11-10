import Foundation
import RaptorExecx

/// Preserves Worktrunk diagnostics, including a failed command's JSON output.
/// Callers must retain any returned worktree when this error is thrown.
public struct CommandError: Error, CustomStringConvertible {
    public let args: [String]
    public let code: Int
    public let stderr: String
    public let stdout: String
    public let cause: (any Error)?

    public init(args: [String], code: Int, stderr: String, stdout: String, cause: (any Error)? = nil) {
        self.args = args
        self.code = code
        self.stderr = stderr
        self.stdout = stdout
        self.cause = cause
    }

    public var description: String {
        var detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty, let cause { detail = String(describing: cause) }
        return "wt \(args.joined(separator: " ")) (exit \(code)): \(detail)"
    }
}

/// Switch outcome for Go's `(Worktree, bool, error)` with a non-empty worktree
/// preserved on failure: recovery needs both even when an error occurred.
public struct SwitchError: Error, CustomStringConvertible {
    public let tree: Worktree
    public let created: Bool
    public let cause: any Error
    public init(tree: Worktree, created: Bool, cause: any Error) {
        self.tree = tree
        self.created = created
        self.cause = cause
    }
    public var description: String { String(describing: cause) }
}

struct SwitchOutcome {
    var tree: Worktree
    var created: Bool
    var error: (any Error)?
}

/// Worktrunk (`wt`) integration. Ported from internal/worktree/wt.go.
extension WorktreeKit {
    static func wtOut(repo: String, args: [String]) throws -> String {
        try wtRun(repo: repo, env: [], args: args)
    }

    /// Env entries are `NAME=value` prefixes passed through /usr/bin/env, so the
    /// child `wt` argument vector stays byte-identical to the Go original.
    static func wtRun(repo: String, env: [String], args: [String]) throws -> String {
        let name = env.isEmpty ? "wt" : "env"
        let command = env.isEmpty ? args : env + ["wt"] + args
        let r: ExecResult
        do {
            r = try Execx.run(dir: repo, timeout: 120, name: name, args: command)
        } catch let e as ExecxError {
            // No usable process exit status on launch failure or timeout.
            throw CommandError(args: args, code: e.result.code == 0 ? -1 : e.result.code,
                               stderr: e.result.stderr, stdout: e.result.stdout, cause: e)
        } catch {
            throw CommandError(args: args, code: -1, stderr: "", stdout: "", cause: error)
        }
        if r.code != 0 {
            throw CommandError(args: args, code: r.code, stderr: r.stderr, stdout: r.stdout, cause: nil)
        }
        return r.stdout
    }

    /// Evaluates Worktrunk's configured template without creating refs,
    /// directories, or running hooks. Existing worktrees keep their current paths.
    public static func previewPath(repo: String, branch: String) throws -> String {
        if branch.isEmpty {
            throw MessageError("enter a branch name")
        }
        for tree in list(repo: repo) where tree.branch == branch {
            return tree.path
        }
        let configJSON: String
        do {
            configJSON = try wtOut(repo: repo, args: ["config", "show", "--format=json"])
        } catch {
            throw error
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(configJSON.utf8))) as? [String: Any] else {
            throw MessageError("parse wt config: invalid JSON")
        }
        let user = settings((object["user"] as? [String: Any])?["config"])
        let system = settings((object["system"] as? [String: Any])?["config"])
        let identifier = (object["project"] as? [String: Any])?["identifier"] as? String ?? ""

        var template = "{{ repo_path }}/../{{ repo }}.{{ branch | sanitize }}"
        for source in [system, user] {
            if !source.path.isEmpty { template = source.path }
            let keys = source.projects.keys.sorted { a, b in
                let wildcardA = a.contains("*"), wildcardB = b.contains("*")
                if wildcardA != wildcardB { return wildcardA }
                let lenA = a.replacingOccurrences(of: "*", with: "").count
                let lenB = b.replacingOccurrences(of: "*", with: "").count
                if lenA != lenB { return lenA < lenB }
                return a < b
            }
            for key in keys {
                guard let value = source.projects[key], !value.isEmpty else { continue }
                if matchesPattern(key: key, value: identifier) {
                    template = value
                }
            }
        }
        if let override = ProcessInfo.processInfo.environment["WORKTRUNK_WORKTREE_PATH"] {
            template = override
        }
        // Let Worktrunk evaluate its own variables and filters, not a Raptor clone
        // of MiniJinja. JSON quotes are also valid MiniJinja string literals.
        let expression = "{% set branch = " + goQuote(branch) + " %}" + template
        // step eval also builds hook context and caches default-branch detection
        // in .git/config. Path templates do not use that variable. Supply a valid
        // branch through Git's command environment to keep previews read-only.
        var env: [String] = []
        let branches = localBranches(repo: repo)
        if !branches.isEmpty {
            var n = 0
            let rawCount = ProcessInfo.processInfo.environment["GIT_CONFIG_COUNT"]
            if let rawCount, !rawCount.isEmpty {
                guard let parsed = Int(rawCount) else {
                    throw MessageError("invalid GIT_CONFIG_COUNT: strconv.Atoi: parsing \"\(rawCount)\": invalid syntax")
                }
                n = parsed
            }
            env = [
                "GIT_CONFIG_COUNT=\(n + 1)",
                "GIT_CONFIG_KEY_\(n)=worktrunk.default-branch",
                "GIT_CONFIG_VALUE_\(n)=\(branches[0])",
            ]
        }
        let evalOut: String
        do {
            evalOut = try wtRun(repo: repo, env: env, args: ["step", "eval", "--format=json", expression])
        } catch {
            throw error
        }
        guard let evalObject = (try? JSONSerialization.jsonObject(with: Data(evalOut.utf8))) as? [String: Any],
              let result = evalObject["result"] as? String else {
            throw MessageError("parse wt preview: invalid JSON")
        }
        var path = result
        if path.isEmpty {
            throw MessageError("wt returned an empty destination")
        }
        if path == "~" || path.hasPrefix("~/") {
            guard let cHome = getenv("HOME"), !String(cString: cHome).isEmpty else {
                throw MessageError("$HOME is not defined")
            }
            path = pathJoin([String(cString: cHome), String(path.dropFirst())])
        }
        if !path.hasPrefix("/") {
            let trees = list(repo: repo)
            if trees.isEmpty {
                throw MessageError("cannot find primary worktree for relative wt destination")
            }
            path = pathJoin([trees[0].path, path])
        }
        return pathClean(path)
    }

    /// Switches to a PR through Worktrunk. `created` reports a newly registered
    /// worktree, not a newly created branch. Setup hooks are deferred: callers
    /// must run visible setup only for newly created worktrees. On failure a
    /// SwitchError preserves the worktree and created flag for recovery.
    public static func switchPR(repo: String, url: String) throws -> (tree: Worktree, created: Bool) {
        if url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || url.hasPrefix("-") {
            throw MessageError("enter a PR URL")
        }
        return try finishSwitch(switchWorktree(repo: repo, args: [url]))
    }

    /// Reuses a local branch through the same no-hooks switch and registration
    /// reconciliation as switchPR. It never creates or resets a branch.
    public static func switchBranch(repo: String, branch: String) throws -> (tree: Worktree, created: Bool) {
        if branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || branch.hasPrefix("-") {
            throw MessageError("enter a branch name")
        }
        return try finishSwitch(switchWorktree(repo: repo, args: [branch]))
    }

    private static func finishSwitch(_ outcome: SwitchOutcome) throws -> (tree: Worktree, created: Bool) {
        if let error = outcome.error {
            throw SwitchError(tree: outcome.tree, created: outcome.created, cause: error)
        }
        return (outcome.tree, outcome.created)
    }

    /// Core reconciliation. Mirrors Go's switchWorktree: the returned worktree
    /// and created flag survive errors so callers can recover partial state.
    static func switchWorktree(repo: String, args: [String]) -> SwitchOutcome {
        let before: [Worktree]
        do {
            before = try listWorktrees(repo: repo)
        } catch {
            return SwitchOutcome(tree: Worktree(), created: false, error: error)
        }
        var known = Set<String>()
        for tree in before { known.insert(tree.path) }
        let command = ["switch", "--no-hooks", "--no-cd", "--format=json"] + args
        var out = ""
        var runErr: (any Error)?
        do {
            out = try wtOut(repo: repo, args: command)
        } catch let e as CommandError {
            out = e.stdout
            runErr = e
        } catch {
            runErr = error
        }
        var path = ""
        var branch = ""
        var parseErr: (any Error)?
        if let object = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] {
            path = object["path"] as? String ?? ""
            branch = object["branch"] as? String ?? ""
            if path.isEmpty {
                parseErr = MessageError("wt returned no worktree destination")
            }
        } else {
            parseErr = MessageError("parse wt switch: invalid JSON")
        }
        if let parseErr {
            runErr = joinErrors(runErr, parseErr)
        }
        let after: [Worktree]
        do {
            after = try listWorktrees(repo: repo)
        } catch {
            return SwitchOutcome(tree: Worktree(path: path, branch: branch), created: false,
                                 error: joinErrors(runErr, error))
        }
        if !path.isEmpty, let resolved = evalSymlinks(path) {
            path = resolved
        }
        for tree in after where !path.isEmpty && tree.path == path {
            return SwitchOutcome(tree: tree, created: !known.contains(tree.path), error: runErr)
        }
        // wt can fail after registration but before printing JSON. Recover only an
        // unambiguous addition; never guess among concurrent worktree creations.
        let added = after.filter { !known.contains($0.path) }
        if added.count == 1 {
            if runErr == nil {
                runErr = MessageError("wt result did not identify registered destination: \(added[0].path)")
            }
            return SwitchOutcome(tree: added[0], created: true, error: runErr)
        }
        if !path.isEmpty {
            return SwitchOutcome(tree: Worktree(path: path, branch: branch), created: false,
                                 error: joinErrors(runErr, MessageError("wt destination not registered: \(path)")))
        }
        return SwitchOutcome(tree: Worktree(), created: false, error: runErr)
    }

    // MARK: - wt config parsing

    private typealias Settings = (path: String, projects: [String: String])

    private static func settings(_ obj: Any?) -> Settings {
        guard let dict = obj as? [String: Any] else { return ("", [:]) }
        var projects: [String: String] = [:]
        if let entries = dict["projects"] as? [String: Any] {
            for (key, value) in entries {
                projects[key] = (value as? [String: Any])?["worktree-path"] as? String ?? ""
            }
        }
        return (dict["worktree-path"] as? String ?? "", projects)
    }

    /// "^" + QuoteMeta(key) with `\*` replaced by ".*" + "$", like Go.
    private static func matchesPattern(key: String, value: String) -> Bool {
        let pattern = "^" + quoteMeta(key).replacingOccurrences(of: "\\*", with: ".*") + "$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(value.startIndex..., in: value)
        return regex.firstMatch(in: value, range: range) != nil
    }
}
