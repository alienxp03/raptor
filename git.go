package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type worktree struct {
	Path   string
	Branch string
	IsMain bool
}

func gitOut(dir string, args ...string) (string, error) {
	r, err := runCmd(dir, 10*time.Second, "git", args...)
	if err != nil {
		return "", err
	}
	if r.Code != 0 {
		return "", fmt.Errorf("%s", strings.TrimSpace(r.Stderr))
	}
	return strings.TrimSpace(r.Stdout), nil
}
func repoRoot(dir string) string {
	if dir == "" {
		dir, _ = os.Getwd()
	}
	out, _ := gitOut(dir, "rev-parse", "--show-toplevel")
	return out
}
func isGitRepo(dir string) bool { return repoRoot(dir) != "" }

func listWorktrees(repo string) []worktree {
	out, err := gitOut(repo, "worktree", "list", "--porcelain", "-z")
	if err != nil {
		return nil
	}
	var result []worktree
	var current *worktree
	for _, field := range strings.Split(out, "\x00") {
		switch {
		case strings.HasPrefix(field, "worktree "):
			result = append(result, worktree{Path: strings.TrimPrefix(field, "worktree "), IsMain: len(result) == 0})
			current = &result[len(result)-1]
		case current != nil && strings.HasPrefix(field, "branch "):
			current.Branch = strings.TrimPrefix(field, "branch refs/heads/")
		case current != nil && strings.HasPrefix(field, "HEAD "):
			hash := strings.TrimPrefix(field, "HEAD ")
			if len(hash) > 7 {
				hash = hash[:7]
			}
			current.Branch = "detached " + hash
		}
	}
	return result
}

func worktreeFolder(branch string) string {
	if strings.HasPrefix(branch, "feat/") {
		branch = "feature/" + strings.TrimPrefix(branch, "feat/")
	}
	return strings.ReplaceAll(branch, "/", "-")
}
func worktreePath(repo, branch string, cfg Config) string {
	// Always use the primary repository's name, even when launched inside a worktree.
	name := basename(repo)
	if trees := listWorktrees(repo); len(trees) > 0 {
		name = basename(trees[0].Path)
	}
	return filepath.Join(cfg.WorktreeRoot, name, worktreeFolder(branch))
}
func validateWorktree(repo, branch, base, path string) error {
	if branch == "" {
		return fmt.Errorf("enter a branch name")
	}
	if _, err := gitOut(repo, "check-ref-format", "--branch", branch); err != nil {
		return fmt.Errorf("invalid branch name: %s", branch)
	}
	if _, err := gitOut(repo, "show-ref", "--verify", "--quiet", "refs/heads/"+branch); err == nil {
		return fmt.Errorf("branch already exists: %s", branch)
	}
	if base == "" {
		return fmt.Errorf("choose a local base branch")
	}
	if _, err := gitOut(repo, "show-ref", "--verify", "--quiet", "refs/heads/"+base); err != nil {
		return fmt.Errorf("local base branch not found: %s", base)
	}
	if _, err := os.Lstat(path); err == nil {
		return fmt.Errorf("destination already exists: %s", path)
	} else if !os.IsNotExist(err) {
		return err
	}
	for _, w := range listWorktrees(repo) {
		if w.Path == path {
			return fmt.Errorf("destination is already registered as a worktree")
		}
	}
	return nil
}
func createLocalWorktree(repo, branch, base, path string) error {
	if err := validateWorktree(repo, branch, base, path); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	_, err := gitOut(repo, "worktree", "add", "-b", branch, path, base)
	return err
}
func removeWorktree(repo string, w worktree) error {
	if w.IsMain {
		return fmt.Errorf("cannot remove the primary worktree")
	}
	// No --force and no branch deletion: Git refuses dirty/locked worktrees.
	_, err := gitOut(repo, "worktree", "remove", w.Path)
	return err
}
func localBranches(repo string) []string {
	out, _ := gitOut(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads/")
	if out == "" {
		return nil
	}
	return strings.Split(out, "\n")
}
