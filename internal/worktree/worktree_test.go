package worktree

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/config"
)

func fixtureRepo(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	isolateWT(t, root)
	dir := filepath.Join(root, "repo")
	if err := os.Mkdir(dir, 0755); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"init", "-b", "main"}, {"config", "user.name", "Test"}, {"config", "user.email", "test@example.com"}, {"-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "initial"}} {
		if _, err := GitOut(dir, args...); err != nil {
			t.Fatal(err)
		}
	}
	return RepoRoot(dir)
}

func TestRepoFolder(t *testing.T) {
	for input, want := range map[string]string{
		".dotfiles": "dotfiles",
		"raptor":    "raptor",
		"...":       "repository",
	} {
		if got := RepoFolder(input); got != want {
			t.Errorf("RepoFolder(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestLocalWorktreeLifecycle(t *testing.T) {
	repo := fixtureRepo(t)
	root := t.TempDir()
	for _, pair := range [][2]string{{"feat/login", "feature-login"}, {"fix/crash", "fix-crash"}, {"chore/deps", "chore-deps"}, {"refactor/auth/session", "refactor-auth-session"}} {
		if got := Folder(pair[0]); got != pair[1] {
			t.Fatalf("%s -> %s", pair[0], got)
		}
	}
	path := Path(repo, "feat/login", config.Config{WorktreeRoot: root})
	if !strings.HasSuffix(path, "repo/feat-login") {
		t.Fatal(path)
	}
	if err := CreateLocal(repo, "feat/login", "main", path); err != nil {
		t.Fatal(err)
	}
	trees := List(repo)
	if len(trees) != 2 || !trees[0].IsMain || trees[1].Branch != "feat/login" {
		t.Fatalf("%+v", trees)
	}
	if err := CreateLocal(repo, "feat/login", "main", path); err == nil {
		t.Fatal("duplicate accepted")
	}
	if err := Validate(repo, "../escape", "main", path); err == nil {
		t.Fatal("invalid name accepted")
	}
	if err := Validate(repo, "feat/new", "missing", path+"new"); err == nil {
		t.Fatal("invalid base accepted")
	}
	if err := os.WriteFile(filepath.Join(path, "unsaved"), []byte("keep me"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := Remove(repo, trees[1]); err == nil {
		t.Fatal("dirty worktree removed")
	}
	if err := os.Remove(filepath.Join(path, "unsaved")); err != nil {
		t.Fatal(err)
	}
	if err := Remove(repo, trees[1]); err != nil {
		t.Fatal(err)
	}
	if _, err := GitOut(repo, "show-ref", "--verify", "refs/heads/feat/login"); err != nil {
		t.Fatal("branch should be kept")
	}
	if err := Remove(repo, trees[0]); err == nil {
		t.Fatal("primary removable")
	}
}
