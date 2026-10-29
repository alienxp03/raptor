package worktree

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/execx"
	"github.com/alienxp03/raptor/internal/paths"
)

type Worktree struct {
	Path   string
	Branch string
	IsMain bool
}

func GitOut(dir string, args ...string) (string, error) {
	r, err := execx.Run(dir, 10*time.Second, "git", args...)
	if err != nil {
		return "", err
	}
	if r.Code != 0 {
		return "", fmt.Errorf("%s", strings.TrimSpace(r.Stderr))
	}
	return strings.TrimSpace(r.Stdout), nil
}

func RepoRoot(dir string) string {
	if dir == "" {
		dir, _ = os.Getwd()
	}
	out, _ := GitOut(dir, "rev-parse", "--show-toplevel")
	return out
}

func IsGitRepo(dir string) bool { return RepoRoot(dir) != "" }

func List(repo string) []Worktree {
	out, err := GitOut(repo, "worktree", "list", "--porcelain", "-z")
	if err != nil {
		return nil
	}
	var result []Worktree
	var current *Worktree
	for _, field := range strings.Split(out, "\x00") {
		switch {
		case strings.HasPrefix(field, "worktree "):
			result = append(result, Worktree{Path: strings.TrimPrefix(field, "worktree "), IsMain: len(result) == 0})
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

func Folder(branch string) string {
	if strings.HasPrefix(branch, "feat/") {
		branch = "feature/" + strings.TrimPrefix(branch, "feat/")
	}
	return strings.ReplaceAll(branch, "/", "-")
}

func RepoFolder(name string) string {
	name = strings.TrimLeft(name, ".")
	if name == "" {
		return "repository"
	}
	return name
}

func Path(repo, branch string, cfg config.Config) string {
	// Always use the primary repository's name, even when launched inside a worktree.
	name := paths.Basename(repo)
	if trees := List(repo); len(trees) > 0 {
		name = paths.Basename(trees[0].Path)
	}
	return filepath.Join(cfg.WorktreeRoot, RepoFolder(name), Folder(branch))
}

func ValidateNewBranch(repo, branch string) error {
	if branch == "" {
		return fmt.Errorf("enter a branch name")
	}
	if _, err := GitOut(repo, "check-ref-format", "--branch", branch); err != nil {
		return fmt.Errorf("invalid branch name: %s", branch)
	}
	if _, err := GitOut(repo, "show-ref", "--verify", "--quiet", "refs/heads/"+branch); err == nil {
		return fmt.Errorf("branch already exists: %s", branch)
	}
	return nil
}

func Validate(repo, branch, base, path string) error {
	if err := ValidateNewBranch(repo, branch); err != nil {
		return err
	}
	if base == "" {
		return fmt.Errorf("choose a local base branch")
	}
	if _, err := GitOut(repo, "show-ref", "--verify", "--quiet", "refs/heads/"+base); err != nil {
		return fmt.Errorf("local base branch not found: %s", base)
	}
	if _, err := os.Lstat(path); err == nil {
		return fmt.Errorf("destination already exists: %s", path)
	} else if !os.IsNotExist(err) {
		return err
	}
	for _, w := range List(repo) {
		if w.Path == path {
			return fmt.Errorf("destination is already registered as a worktree")
		}
	}
	return nil
}

func CreateLocal(repo, branch, base, path string) error {
	if err := Validate(repo, branch, base, path); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	_, err := GitOut(repo, "worktree", "add", "-b", branch, path, base)
	return err
}

func Remove(repo string, w Worktree) error {
	if w.IsMain {
		return fmt.Errorf("cannot remove the primary worktree")
	}
	// No --force and no branch deletion: Git refuses dirty/locked worktrees.
	_, err := GitOut(repo, "worktree", "remove", w.Path)
	return err
}

func LocalBranches(repo string) []string {
	out, _ := GitOut(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads/")
	if out == "" {
		return nil
	}
	return strings.Split(out, "\n")
}
