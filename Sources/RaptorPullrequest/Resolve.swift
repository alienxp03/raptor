import Foundation
import RaptorRex
import RaptorWorktree

func command(_ dir: String, _ name: String, _ args: String...) throws -> String {
    try commandContext(timeout: 120, dir: dir, name: name, args: args)
}

func command(_ dir: String, _ name: String, _ args: [String]) throws -> String {
    try commandContext(timeout: 120, dir: dir, name: name, args: args)
}

/// Go's command(): two-minute budget, trimmed stdout; failures throw CmdError
/// carrying partial stdout like cmd.Output did.
func commandContext(timeout: TimeInterval, dir: String, name: String, args: [String]) throws -> String {
    let (out, _) = try Procs.capture(dir: dir, timeout: timeout, name: name, args: args)
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
}

func canonical(_ path: String) throws -> String {
    if path.isEmpty {
        throw MessageError("empty path")
    }
    guard let p = absPath(path) else {
        throw MessageError("empty path")
    }
    guard let resolved = evalSymlinks(p) else {
        throw MessageError("evalsymlinks \(p): no such file or directory")
    }
    return resolved
}

/// ^[A-Za-z0-9_][A-Za-z0-9_.-]*$
func isComponent(_ s: String) -> Bool {
    let chars = Array(s.unicodeScalars)
    if chars.isEmpty { return false }
    func inClass(_ c: Unicode.Scalar, first: Bool) -> Bool {
        let v = c.value
        if v >= 48 && v <= 57 { return true } // 0-9
        if (v >= 65 && v <= 90) || (v >= 97 && v <= 122) { return true } // A-Z a-z
        if first { return v == 95 } // _
        return v == 95 || v == 46 || v == 45 // _ . -
    }
    if !inClass(chars[0], first: true) { return false }
    for c in chars.dropFirst() where !inClass(c, first: false) { return false }
    return true
}

/// ^[1-9][0-9]*$
func isNumber(_ s: String) -> Bool {
    if s.isEmpty { return false }
    let chars = Array(s.unicodeScalars)
    if chars[0].value < 49 || chars[0].value > 57 { return false }
    for c in chars.dropFirst() where c.value < 48 || c.value > 57 { return false }
    return true
}

func identity(_ remote: String) throws -> String {
    var remote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
    if remote.hasPrefix("git@github.com:") {
        remote = "https://github.com/" + String(remote.dropFirst("git@github.com:".count))
    }
    guard let u = URL(string: remote),
          (u.scheme?.lowercased() == "https" || u.scheme?.lowercased() == "ssh"),
          (u.host?.lowercased() ?? "") == "github.com",
          u.query == nil, u.fragment == nil else {
        throw MessageError("unsupported GitHub origin \(remote)")
    }
    var trimmed = u.path
    while trimmed.hasPrefix("/") { trimmed.removeFirst() }
    if trimmed.hasSuffix(".git") { trimmed = String(trimmed.dropLast(".git".count)) }
    let parts = trimmed.components(separatedBy: "/")
    if parts.count != 2 || !isComponent(parts[0]) || !isComponent(parts[1]) || parts[1] == "." || parts[1] == ".." {
        throw MessageError("invalid GitHub repository")
    }
    return parts.joined(separator: "/")
}

func parse(_ input: String, _ repo: String) throws -> (id: String, number: String) {
    if isNumber(input) {
        if repo.isEmpty {
            throw MessageError("a PR number requires a local repository")
        }
        let origin = try command(repo, "git", ["remote", "get-url", "origin"])
        let id = try identity(origin)
        return (id, input)
    }
    guard let u = URL(string: input),
          u.scheme?.lowercased() == "https",
          (u.host?.lowercased() ?? "") == "github.com",
          u.user == nil,
          u.query == nil, u.fragment == nil else {
        throw MessageError("enter a github.com PR URL or a PR number with a repository")
    }
    var pathStr = u.path
    if pathStr.hasSuffix("/") { pathStr = String(pathStr.dropLast()) }
    let p = pathStr.components(separatedBy: "/")
    if p.count != 5 || !p[0].isEmpty || p[3] != "pull" || !isNumber(p[4]) {
        throw MessageError("invalid PR URL")
    }
    let id = try identity("https://github.com/" + p[1] + "/" + p[2])
    return (id, p[4])
}

// MARK: - Resolve / Prepare

extension Pullrequest {
    /// Resolve performs read-only metadata, origin and worktree checks.
    /// Repo is a local path. On failure the partial Info rides on ResolveError,
    /// like Go's (Info, error) pair.
    public static func resolve(repo: String, input: String) throws -> Info {
        try resolveWithOptions(repo: repo, input: input, checkoutCommit: false)
    }

    /// ResolveWithOptions previews an isolated pr/N branch when checkoutCommit
    /// is explicit.
    public static func resolveWithOptions(repo: String, input: String, checkoutCommit: Bool) throws -> Info {
        var info = Info(input: input)
        do {
            info = try resolveWithOptionsImpl(repo: repo, input: input, checkoutCommit: checkoutCommit)
            return info
        } catch {
            throw ResolveError(info: info, cause: error)
        }
    }

    static func resolveWithOptionsImpl(repo: String, input: String, checkoutCommit: Bool) throws -> Info {
        var info = Info(input: input)
        let (id, n) = try parse(input, repo)
        // The REST PR response names the base repository, including for fork PRs.
        let raw = try command("", "gh", ["api", "--hostname", "github.com", "repos/" + id + "/pulls/" + n])
        guard let baseObj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
            throw MessageError("invalid JSON: \(raw.prefix(200))")
        }
        let fullName = ((baseObj["base"] as? [String: Any])?["repo"] as? [String: Any])?["full_name"] as? String ?? ""
        let baseID = try identity("https://github.com/" + fullName)
        if baseID.lowercased() != id.lowercased() {
            throw MessageError("GitHub returned a different base repository")
        }
        info.url = "https://github.com/" + baseID + "/pull/" + n
        let rawMeta = try command("", "gh", ["pr", "view", info.url, "--json", "number,title,headRefName,url,state,headRefOid"])
        guard let meta = (try? JSONSerialization.jsonObject(with: Data(rawMeta.utf8))) as? [String: Any] else {
            throw MessageError("invalid JSON: \(rawMeta.prefix(200))")
        }
        let metadataNumber = meta["number"] as? Int ?? 0
        let metadataTitle = meta["title"] as? String ?? ""
        let metadataHeadRefName = meta["headRefName"] as? String ?? ""
        let metadataState = meta["state"] as? String ?? ""
        let metadataHeadRefOid = meta["headRefOid"] as? String ?? ""
        guard let expected = Int(n), metadataNumber == expected, !metadataHeadRefName.isEmpty else {
            throw MessageError("invalid PR metadata")
        }
        info.number = metadataNumber
        info.title = metadataTitle
        info.branch = metadataHeadRefName
        info.state = metadataState
        info.headOID = metadataHeadRefOid
        if !info.state.isEmpty {
            try resolveHead(&info, baseID)
        }
        if checkoutCommit {
            info.branch = "pr/\(info.number)"
        }
        let home = userHome()
        let destination = pathJoin([home, "workspace"] + baseID.components(separatedBy: "/"))
        var candidates = [repo]
        let cwd = FileManager.default.currentDirectoryPath
        candidates.append(contentsOf: [cwd, destination])
        if let zout = try? command("", "zoxide", ["query", "-l"]) {
            candidates.append(contentsOf: zout.components(separatedBy: "\n"))
        }
        for candidate in candidates {
            if candidate.isEmpty { continue }
            let origin: String
            do {
                origin = try command(candidate, "git", ["remote", "get-url", "origin"])
            } catch {
                if candidate == repo {
                    throw MessageError("invalid repository context: \(error)")
                }
                continue
            }
            let localID: String?
            do {
                localID = try identity(origin)
            } catch {
                localID = nil
            }
            if localID == nil || localID!.lowercased() != baseID.lowercased() {
                if candidate == repo {
                    throw MessageError("repository context does not match \(baseID)")
                }
                continue
            }
            let root: String
            do {
                root = try command(candidate, "git", ["rev-parse", "--path-format=absolute", "--git-common-dir"])
            } catch {
                continue
            }
            // Resolve linked worktrees back to their primary clone, not the selected worktree.
            let primary = dirOf(root)
            if baseOf(root) != ".git" {
                continue // bare clones are not supported
            }
            guard let repoCanonical = try? canonical(primary) else { continue }
            info.repo = repoCanonical
            let sourceRoot = try command(candidate, "git", ["rev-parse", "--show-toplevel"])
            info.source = try canonical(sourceRoot)
            info.path = try WorktreeKit.previewPath(repo: info.source, branch: info.branch)
            for tree in WorktreeKit.list(repo: info.repo) where tree.branch == info.branch {
                info.path = tree.path
                info.existing = true
                break
            }
            return info
        }
        info.repo = destination
        info.cloneRequired = true
        return info
    }

    /// Prepare clones into an absent or verified owned empty destination, then
    /// creates/reuses via Worktrunk. Valid existing clones resume without recloning.
    public static func prepare(repo: String, input: String) throws -> Info {
        try prepareWithOptions(repo: repo, input: input, checkoutCommit: false)
    }

    /// PrepareWithOptions requires explicit consent before checking out a
    /// retained PR commit.
    public static func prepareWithOptions(repo: String, input: String, checkoutCommit: Bool) throws -> Info {
        var info: Info
        do {
            info = try resolveWithOptionsImpl(repo: repo, input: input, checkoutCommit: checkoutCommit)
        } catch {
            throw PrepareError(info: Info(input: input), cause: error)
        }
        func fail(_ error: any Error) -> any Error {
            PrepareError(info: info, cause: error)
        }
        if !checkoutCommit && info.headDeleted && (info.state == "CLOSED" || info.state == "MERGED") {
            throw fail(MessageError("PR #\(info.number) is \(info.state) and its head branch was deleted; choose 'Check out PR commit' (checkout_commit:true) to use isolated branch pr/\(info.number)"))
        }
        if checkoutCommit && !matchesCommitOID(info.headOID) {
            throw fail(MessageError("explicit PR commit checkout requires a verified head OID"))
        }
        let prepareUnlock: () -> Void
        do {
            prepareUnlock = try lock("prepare:" + prospectivePath(info.repo), false)
        } catch {
            throw fail(error)
        }
        defer { prepareUnlock() }
        if info.cloneRequired {
            do {
                try claimClone(info.repo)
            } catch {
                throw fail(error)
            }
            let (id, _) = (try? parse(info.url, "")) ?? ("", "")
            do {
                _ = try command("", "gh", ["repo", "clone", "https://github.com/" + id + ".git", info.repo])
            } catch {
                throw fail(error)
            }
            info.cloneRequired = false
            let origin: String
            do {
                origin = try command(info.repo, "git", ["remote", "get-url", "origin"])
                let actual = try identity(origin)
                if actual.lowercased() != id.lowercased() {
                    throw MessageError("cloned origin does not match \(id)")
                }
            } catch {
                throw fail(MessageError("cloned origin does not match \(id)"))
            }
        }
        do {
            _ = try command(info.repo, "git", ["rev-parse", "--verify", "HEAD"])
        } catch {
            throw fail(MessageError("clone is incomplete; inspect before retry: \(error)"))
        }
        var source = info.source
        if source.isEmpty {
            source = info.repo
        }
        do {
            try checkPreSwitch(source)
        } catch {
            throw fail(error)
        }
        let preview: String
        do {
            preview = try WorktreeKit.previewPath(repo: source, branch: info.branch)
        } catch {
            throw fail(error)
        }
        let previewUnlock: () -> Void
        do {
            previewUnlock = try lock(preview, false)
        } catch {
            throw fail(error)
        }
        defer { previewUnlock() }
        // Journal before mutation. On an interrupted switch, creation hooks remain pending.
        var s: SetupState
        do {
            s = try load(preview)
        } catch {
            throw fail(error)
        }
        // A bound journal belongs to one registration, not to a pathname. An
        // unbound preparation journal survives a crash between switch and save.
        if (s.instance != nil && !(s.instance ?? "").isEmpty && !validState(preview, s))
            || ((s.instance ?? "").isEmpty && (s.complete || s.opening || s.stage != 0)) {
            s = SetupState()
        }
        let newJournal = s.path.isEmpty
        if newJournal {
            s = SetupState(path: preview, source: source, branch: info.branch, url: info.url, new: !info.existing)
            s.base = (try? command(source, "git", ["symbolic-ref", "--short", "HEAD"])) ?? ""
            do {
                s.config = try configStamp(source)
            } catch {
                throw fail(error)
            }
            do {
                try save(preview, s)
            } catch {
                throw fail(error)
            }
        }
        var tree = Worktree()
        var created = false
        var switchErr: (any Error)?
        if checkoutCommit {
            do {
                try prepareCommit(info)
            } catch {
                throw fail(error)
            }
            do {
                let r = try WorktreeKit.switchBranch(repo: source, branch: info.branch)
                tree = r.tree
                created = r.created
            } catch let e as SwitchError {
                tree = e.tree
                created = e.created
                switchErr = e
            } catch {
                switchErr = error
            }
        } else {
            do {
                let r = try WorktreeKit.switchPR(repo: source, url: info.url)
                tree = r.tree
                created = r.created
            } catch let e as SwitchError {
                tree = e.tree
                created = e.created
                switchErr = e
            } catch {
                switchErr = error
            }
        }
        if tree.path.isEmpty {
            if switchErr == nil {
                switchErr = MessageError("Worktrunk returned no destination")
            }
            throw fail(switchErr!)
        }
        if checkoutCommit {
            var oid = ""
            var verifyErr: (any Error)?
            do {
                oid = try command(tree.path, "git", ["rev-parse", "--verify", "HEAD"])
            } catch {
                verifyErr = error
            }
            if verifyErr != nil || oid != info.headOID || tree.branch != info.branch {
                switchErr = joinErrors(switchErr, MessageError("PR commit destination changed during checkout; inspect preserved resources before setup"))
            }
        }
        info.path = tree.path
        info.existing = !created
        let path: String
        do {
            path = try canonical(tree.path)
        } catch {
            throw fail(error)
        }
        info.path = path
        let destinationUnlock: (() -> Void)?
        if prospectivePath(preview) != path {
            do {
                destinationUnlock = try lock(path, false)
            } catch {
                throw fail(error)
            }
        } else {
            destinationUnlock = nil
        }
        defer { destinationUnlock?() }
        let prior: SetupState
        do {
            prior = try load(path)
        } catch {
            throw fail(error)
        }
        var saveErr: (any Error)?
        if prior.path.isEmpty || newJournal || (prior.instance ?? "").isEmpty {
            s.path = path
            s.branch = tree.branch
            if newJournal {
                s.new = created
            }
            do {
                s.instance = try instance(path)
                try save(path, s)
            } catch {
                saveErr = error
            }
        } else if !validState(path, prior) {
            throw fail(MessageError("worktree branch differs from saved setup state; resources preserved"))
        }
        if let joined = joinErrors(switchErr, saveErr) {
            throw fail(joined)
        }
        return info
    }
}
