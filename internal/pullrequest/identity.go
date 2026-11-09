package pullrequest

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"

	"github.com/alienxp03/raptor/internal/worktree"
)

// Fallback for filesystems without creation time. Nanosecond modification time
// makes inode reuse detectable; changed files fail closed on these filesystems.
func fileIdentity(path string) (string, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return "", err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return "", fmt.Errorf("file identity unavailable: %s", path)
	}
	return fmt.Sprintf("%d:%d:%d", stat.Dev, stat.Ino, info.ModTime().UnixNano()), nil
}

func instance(path string) (string, error) {
	root, err := command(path, "git", "rev-parse", "--show-toplevel")
	if err != nil {
		return "", err
	}
	root, err = canonical(root)
	if err != nil || root != path {
		return "", fmt.Errorf("not a worktree root: %s", path)
	}
	registered := false
	for _, tree := range worktree.List(path) {
		p, err := canonical(tree.Path)
		if err == nil && p == path {
			registered = true
			break
		}
	}
	if !registered {
		return "", fmt.Errorf("worktree is not registered: %s", path)
	}
	gitfile := filepath.Join(path, ".git")
	info, err := os.Lstat(gitfile)
	if err != nil {
		return "", err
	}
	if info.IsDir() {
		gitfile = filepath.Join(gitfile, "HEAD")
	}
	return cloneIdentity(gitfile)
}

func validState(path string, s setupState) bool {
	if s.Path != path || s.Instance == "" {
		return false
	}
	id, err := instance(path)
	if err != nil || id != s.Instance {
		return false
	}
	branch, err := command(path, "git", "symbolic-ref", "--short", "HEAD")
	return err == nil && branch == s.Branch
}

// Ready reports whether Open can use the registered worktree and its journal.
// A registration alone is not proof that Prepare reached a recoverable state.
func Ready(path string) bool {
	path, err := canonical(path)
	if err != nil {
		return false
	}
	unlock, err := lock(path, false)
	if err != nil {
		return false
	}
	defer unlock()
	s, err := load(path)
	return err == nil && validState(path, s)
}
