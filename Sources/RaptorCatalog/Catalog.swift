import Foundation
import RaptorConfig
import RaptorPaths
import RaptorRex
import RaptorWorktree

/// Package catalog shares picker data and fuzzy matching with native clients.
public enum Catalog {}

/// Directory is one frecency row of the dir picker.
public struct Directory: Equatable, Encodable {
    public var path: String
    public var label: String
    public var pinned: Bool
    public var state: String
    public var working: Bool

    public init(path: String = "", label: String = "", pinned: Bool = false, state: String = "", working: Bool = false) {
        self.path = path
        self.label = label
        self.pinned = pinned
        self.state = state
        self.working = working
    }

    enum CodingKeys: String, CodingKey {
        case path, label
        case pinned = "is_pinned"
        case state, working
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(label, forKey: .label)
        if pinned {
            try c.encode(pinned, forKey: .pinned)
        }
        if !state.isEmpty {
            try c.encode(state, forKey: .state)
        }
        if working {
            try c.encode(working, forKey: .working)
        }
    }
}

/// filepath.EvalSymlinks + filepath.Abs, as Go's paths.Canonical. Foundation's
/// destinationOfSymbolicLink only unwraps a final symlink chain; EvalSymlinks
/// resolves every component, which symlinked zoxide entries need.
func canonicalPath(_ path: String) -> String {
    if path.isEmpty {
        return ""
    }
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    return (resolved as NSString).standardizingPath
}

public extension Catalog {
    static func directories(reposOnly: Bool) -> [Directory] {
        directoriesOn(host: "", reposOnly: reposOnly)
    }

    /// DirectoriesOn scopes frecency directories to one host. The empty host and
    /// "This Mac" read the local zoxide database; remote hosts answer over SSH.
    /// The fd scan is appended after zoxide: frecency order stays untouched, and
    /// never-visited directories surface below the established ones.
    /// RAPTOR_DISABLE_DIR_SCAN isolates fixture-backed tests from the real
    /// filesystem: the scan runs real commands that PATH stubs cannot intercept
    /// (find exists everywhere), which would leak home directories into rows.
    static func directoriesOn(host: String, reposOnly: Bool) -> [Directory] {
        let scan = (RaptorPaths.env("RAPTOR_DISABLE_DIR_SCAN") ?? "").isEmpty
            ? Rex.dirScanOn(host) : []
        let dirs = mergeDirScan(zoxide: Rex.zoxideListOn(host), scan: scan)
        return directoryItems(dirs, reposOnly)
    }

    /// MergeDirScan keeps zoxide order, then appends scan entries that are not
    /// already present, compared by canonical path so symlinked zoxide entries
    /// still suppress their scan twins. The scan contribution is capped: it is a
    /// fallback, not a second index.
    static func mergeDirScan(zoxide: [String], scan: [String], cap: Int = 100) -> [String] {
        var seen = Set<String>()
        for dir in zoxide {
            seen.insert(canonicalPath(dir))
        }
        var merged = zoxide
        merged.reserveCapacity(zoxide.count + min(scan.count, cap))
        for dir in scan {
            if merged.count - zoxide.count >= cap {
                break
            }
            let canonical = canonicalPath(dir)
            if seen.contains(canonical) {
                continue
            }
            seen.insert(canonical)
            merged.append(dir)
        }
        return merged
    }

    /// DirectoryItems keeps zoxide order. Repository discovery also accepts subdirectories.
    static func directoryItems(_ dirs: [String], _ reposOnly: Bool) -> [Directory] {
        var items: [Directory] = []
        items.reserveCapacity(dirs.count)
        var seen = Set<String>()
        for dir in dirs {
            var dir = dir
            if reposOnly {
                dir = WorktreeKit.repoRoot(dir: dir)
                if dir.isEmpty || seen.contains(dir) {
                    continue
                }
                seen.insert(dir)
            }
            items.append(Directory(path: dir, label: RaptorPaths.basename(dir)))
        }
        return items
    }

    static func filterDirectories(_ items: [Directory], _ query: String) -> [Int] {
        let entries = items.map { $0.label + " " + RaptorPaths.homeRelative($0.path) }
        return match(entries, query)
    }

    /// TypedPathDirectory recognizes a query that is a path, not a name: `~/`,
    /// `/`, `./`, `../`, or `.` prefixes. It closes the sesh gap — sesh opens any
    /// path you hand it, while a list-only picker makes unlisted directories
    /// unreachable. Local paths only; an existing directory becomes one extra
    /// row after the listed matches. nil when the query is not an openable path.
    static func typedPathDirectory(_ query: String, _ items: [Directory]) -> Directory? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let pathLike = trimmed.hasPrefix("~") || trimmed.hasPrefix("/")
            || trimmed.hasPrefix("./") || trimmed.hasPrefix("../") || trimmed == "."
        guard pathLike else { return nil }
        var path = trimmed
        if path.hasPrefix("~") {
            path = RaptorPaths.home() + path.dropFirst()
        }
        let canonical = canonicalPath(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        if items.contains(where: { canonicalPath($0.path) == canonical }) {
            return nil
        }
        return Directory(path: canonical, label: RaptorPaths.basename(canonical))
    }

    /// ApplyPins marks and floats pinned directories. Stable sort keeps each
    /// group's order; a canonical match survives symlinked zoxide entries.
    static func applyPins(_ items: inout [Directory]) {
        let pins = Set(RaptorConfig.loadPins())
        var firstUnpinned = 0
        for i in items.indices {
            items[i].pinned = pins.contains(canonicalPath(items[i].path))
            if items[i].pinned {
                let item = items[i]
                items.replaceSubrange(firstUnpinned...i, with: [item] + items[firstUnpinned..<i])
                firstUnpinned += 1
            }
        }
    }

    /// FilterSessions fuzzy-matches each row's label, retaining parent sessions for
    /// matching tabs. Results keep sidebar order, not fuzzy score order. A matching
    /// session does not include tabs whose own labels do not match.
    static func filterSessions(_ entries: [SessionEntry], _ query: String) -> [Int] {
        var texts = [String](repeating: "", count: entries.count)
        var parents = [String: Int]()
        for (i, entry) in entries.enumerated() {
            texts[i] = entry.label
            if entry.kind == "session" {
                parents[entry.sessionID] = i
            }
        }
        var keep = [Bool](repeating: false, count: entries.count)
        for i in match(texts, query) {
            keep[i] = true
            if entries[i].kind == "window" {
                if let parent = parents[entries[i].sessionID] {
                    keep[parent] = true
                }
            }
        }
        var indices: [Int] = []
        indices.reserveCapacity(entries.count)
        for i in entries.indices where keep[i] {
            indices.append(i)
        }
        return indices
    }

    static func filterWorktrees(_ items: [Worktree], _ query: String) -> [Int] {
        let entries = items.map { $0.branch + " " + RaptorPaths.homeRelative($0.path) }
        return match(entries, query)
    }

    /// FilterBranches ranks fuzzy matches, keeping the original order for an empty query.
    static func filterBranches(_ branches: [String], _ query: String) -> [String] {
        match(branches, query).map { branches[$0] }
    }

    /// ResolveRepo returns an empty path when no origin repository is available.
    /// Do not let RepoRoot("") fall back to the backend process's working directory.
    static func resolveRepo(_ ctx: Ctx, _ repo: String) throws -> String {
        let explicit = !repo.isEmpty
        var repo = repo
        if !explicit {
            repo = Rex.blockCwdInSession(ctx.session, ctx.block)
            if repo.isEmpty {
                return ""
            }
        }
        let root = WorktreeKit.repoRoot(dir: repo)
        if root.isEmpty && explicit {
            throw MessageError("not a git repository: \(repo)")
        }
        return root
    }
}

/// Worktrees is the worktree picker payload for one repository.
public struct Worktrees: Equatable {
    public var items: [Worktree]
    public var branches: [String]
    public var baseBranch: String
    public var suggestedBranch: String
    public var root: String

    public init(
        items: [Worktree] = [], branches: [String] = [], baseBranch: String = "",
        suggestedBranch: String = "", root: String = ""
    ) {
        self.items = items
        self.branches = branches
        self.baseBranch = baseBranch
        self.suggestedBranch = suggestedBranch
        self.root = root
    }

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case branches = "Branches"
        case baseBranch = "BaseBranch"
        case suggestedBranch = "SuggestedBranch"
        case root = "Root"
    }
}

public extension Catalog {
    static func listWorktrees(_ repo: String, _ cfg: RaptorConfig) -> Worktrees {
        var info = Worktrees(items: WorktreeKit.list(repo: repo), branches: WorktreeKit.localBranches(repo: repo))
        // Suggestions are read-only and optional; unavailable names must not hide trees.
        info.suggestedBranch = (try? WorktreeKit.suggestTaskName(repo: repo, cfg: cfg)) ?? ""
        // Root is informational only; branch-specific destinations must use
        // PreviewPath because Worktrunk templates can include nested branch paths.
        if !info.suggestedBranch.isEmpty {
            if let destination = try? WorktreeKit.previewPath(repo: repo, branch: info.suggestedBranch) {
                info.root = pathDir(destination)
            }
        }
        info.baseBranch = (try? WorktreeKit.gitOut(dir: repo, args: ["branch", "--show-current"])) ?? ""
        if info.baseBranch.isEmpty && !info.branches.isEmpty {
            info.baseBranch = info.branches[0]
        }
        return info
    }
}

/// Index-based fuzzy match over prebuilt texts; an empty query keeps order.
func match(_ entries: [String], _ query: String) -> [Int] {
    var indices: [Int] = []
    indices.reserveCapacity(entries.count)
    if query.isEmpty {
        for i in entries.indices {
            indices.append(i)
        }
    } else {
        for m in Fuzzy.find(query, entries) {
            indices.append(m.index)
        }
    }
    return indices
}
