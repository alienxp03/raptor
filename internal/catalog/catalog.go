// Package catalog shares picker data and fuzzy matching with native clients.
package catalog

import (
	"fmt"
	"path/filepath"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/paths"
	"github.com/alienxp03/raptor/internal/rex"
	"github.com/alienxp03/raptor/internal/worktree"
	"github.com/sahilm/fuzzy"
)

type Directory struct {
	Path  string `json:"path"`
	Label string `json:"label"`
}

func Directories(reposOnly bool) []Directory {
	return DirectoryItems(rex.ZoxideList(), reposOnly)
}

// DirectoryItems keeps zoxide order. Repository discovery also accepts subdirectories.
func DirectoryItems(dirs []string, reposOnly bool) []Directory {
	items := make([]Directory, 0, len(dirs))
	seen := make(map[string]bool)
	for _, dir := range dirs {
		if reposOnly {
			dir = worktree.RepoRoot(dir)
			if dir == "" || seen[dir] {
				continue
			}
			seen[dir] = true
		}
		items = append(items, Directory{Path: dir, Label: paths.Basename(dir)})
	}
	return items
}

func FilterDirectories(items []Directory, query string) []int {
	entries := make([]string, len(items))
	for i, item := range items {
		entries[i] = item.Label + " " + paths.HomeRelative(item.Path)
	}
	return match(entries, query)
}

func FilterWorktrees(items []worktree.Worktree, query string) []int {
	entries := make([]string, len(items))
	for i, item := range items {
		entries[i] = item.Branch + " " + paths.HomeRelative(item.Path)
	}
	return match(entries, query)
}

// FilterBranches ranks fuzzy matches, keeping the original order for an empty query.
func FilterBranches(branches []string, query string) []string {
	result := make([]string, 0, len(branches))
	for _, i := range match(branches, query) {
		result = append(result, branches[i])
	}
	return result
}

func match(entries []string, query string) []int {
	indices := make([]int, 0, len(entries))
	if query == "" {
		for i := range entries {
			indices = append(indices, i)
		}
	} else {
		for _, match := range fuzzy.Find(query, entries) {
			indices = append(indices, match.Index)
		}
	}
	return indices
}

// ResolveRepo returns an empty path when no origin repository is available.
// Do not let RepoRoot("") fall back to the backend process's working directory.
func ResolveRepo(ctx rex.Ctx, repo string) (string, error) {
	explicit := repo != ""
	if !explicit {
		repo = rex.BlockCwdInSession(ctx.Session, ctx.Block)
		if repo == "" {
			return "", nil
		}
	}
	root := worktree.RepoRoot(repo)
	if root == "" && explicit {
		return "", fmt.Errorf("not a git repository: %s", repo)
	}
	return root, nil
}

type Worktrees struct {
	Items      []worktree.Worktree
	Branches   []string
	BaseBranch string
	Root       string
}

func ListWorktrees(repo string, cfg config.Config) Worktrees {
	info := Worktrees{Items: worktree.List(repo), Branches: worktree.LocalBranches(repo)}
	primary := repo
	if len(info.Items) > 0 {
		primary = info.Items[0].Path
	}
	info.Root = filepath.Join(cfg.WorktreeRoot, worktree.RepoFolder(paths.Basename(primary)))
	info.BaseBranch, _ = worktree.GitOut(repo, "branch", "--show-current")
	if info.BaseBranch == "" && len(info.Branches) > 0 {
		info.BaseBranch = info.Branches[0]
	}
	return info
}
