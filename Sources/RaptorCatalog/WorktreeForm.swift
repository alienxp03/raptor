import RaptorWorktree

public extension Catalog {
    /// New Worktree form metadata only. No Worktrunk, worktree enumeration,
    /// destination evaluation, or validation; the suggestion is provisional.
    static func worktreeForm(_ repo: String) -> Worktrees {
        let refs = (try? WorktreeKit.gitOut(
            dir: repo, args: ["for-each-ref", "--format=%(refname:strip=2)%00%(HEAD)", "refs/heads/"])) ?? ""
        // One refs read supplies both local branches and the current-branch
        // marker; avoid a separate `git branch --show-current` subprocess.
        let rows = refs.split(separator: "\n").map {
            $0.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
        }
        let branches = rows.map { String($0[0]) }
        let current = rows.first { $0.count == 2 && $0[1] == "*" }.map { String($0[0]) } ?? ""
        return Worktrees(
            branches: branches,
            baseBranch: branches.contains(current) ? current : (branches.first ?? ""),
            suggestedBranch: WorktreeKit.suggestTaskNameFast(branches: branches))
    }
}
