package worktree

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/config"
)

func isolateWT(t *testing.T, root string) {
	t.Helper()
	resolved, err := filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal(err)
	}
	root = resolved
	empty := filepath.Join(root, "empty.toml")
	if err := os.WriteFile(empty, []byte(""), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WORKTRUNK_CONFIG_PATH", empty)
	t.Setenv("WORKTRUNK_SYSTEM_CONFIG_PATH", empty)
	t.Setenv("WORKTRUNK_PROJECT_CONFIG_PATH", filepath.Join(root, "no-project.toml"))
	t.Setenv("WORKTRUNK_WORKTREE_PATH", filepath.Join(root, "trees", "{{ repo }}", "{{ branch | sanitize }}"))
}

func TestPreviewConfiguredPathAndErrors(t *testing.T) {
	repo := fixtureRepo(t)
	configured := filepath.Join(filepath.Dir(repo), "configured paths", "{{ branch }}")
	t.Setenv("WORKTRUNK_WORKTREE_PATH", configured)
	path, err := PreviewPath(repo, "feat/login")
	want := filepath.Join(filepath.Dir(repo), "configured paths", "feat", "login")
	if err != nil || path != want {
		t.Fatalf("preview: %q %v, want %s", path, err, want)
	}
	if got := Path(repo, "feat/login", config.Config{WorktreeRoot: "/ignored"}); got != want {
		t.Fatal(got)
	}
	if _, err := os.Stat(filepath.Dir(want)); !os.IsNotExist(err) {
		t.Fatal("preview created directories")
	}
	t.Setenv("WORKTRUNK_WORKTREE_PATH", "{{ missing_variable }}")
	if _, err := PreviewPath(repo, "feat/login"); err == nil {
		t.Fatal("preview error hidden")
	}
	if err := Validate(repo, "feat/login", "main", ""); err == nil {
		t.Fatal("validation error hidden")
	}
	if err := CreateLocal(repo, "feat/login", "main", ""); err == nil {
		t.Fatal("creation error hidden")
	}
}

func TestSwitchKeepsExistingAndDefersHooks(t *testing.T) {
	repo := fixtureRepo(t)
	hook := filepath.Join(filepath.Dir(repo), "hook-ran")
	project := filepath.Join(repo, "project.toml")
	if err := os.WriteFile(project, []byte("pre-start = 'touch "+hook+"'\npost-start = 'touch "+hook+"'\n"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WORKTRUNK_PROJECT_CONFIG_PATH", project)
	tree, created, err := switchWorktree(repo, "--create", "feat/login", "--base", "main")
	if err != nil || !created || tree.Branch != "feat/login" {
		t.Fatalf("%+v %v %v", tree, created, err)
	}
	if _, err := os.Stat(hook); !os.IsNotExist(err) {
		t.Fatal("creation ran hooks")
	}
	if err := os.WriteFile(filepath.Join(tree.Path, "dirty"), []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	// Changing the configured path must not relocate an existing worktree.
	t.Setenv("WORKTRUNK_WORKTREE_PATH", filepath.Join(filepath.Dir(repo), "elsewhere", "{{ branch | sanitize }}"))
	path, err := PreviewPath(repo, "feat/login")
	if err != nil || path != tree.Path {
		t.Fatalf("existing preview: %s %v", path, err)
	}
	reused, created, err := switchWorktree(repo, "feat/login")
	if err != nil || created || reused != tree {
		t.Fatalf("%+v %v %v", reused, created, err)
	}
	if data, err := os.ReadFile(filepath.Join(tree.Path, "dirty")); err != nil || string(data) != "keep" {
		t.Fatal("existing changes lost")
	}
}

func TestSwitchPRPartialFailure(t *testing.T) {
	repo := fixtureRepo(t)
	realWT, err := exec.LookPath("wt")
	if err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join(filepath.Dir(repo), "bin")
	if err := os.Mkdir(bin, 0700); err != nil {
		t.Fatal(err)
	}
	// Simulate failure after wt has registered the PR worktree, without stdout.
	script := "#!/bin/sh\n[ \"$1\" = switch ] && [ \"$2\" = --no-hooks ] && [ \"$3\" = --no-cd ] && [ \"$4\" = --format=json ] && [ \"$5\" = https://github.com/owner/repo/pull/1 ] && [ \"$#\" = 5 ] || exit 99\n\"" + realWT + "\" switch --no-hooks --no-cd --format=json --create feat/pr --base main >/dev/null\necho after-create-failure >&2\nexit 7\n"
	if err := os.WriteFile(filepath.Join(bin, "wt"), []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	tree, created, err := SwitchPR(repo, "https://github.com/owner/repo/pull/1")
	if !created || tree.Branch != "feat/pr" || err == nil || !strings.Contains(err.Error(), "after-create-failure") {
		t.Fatalf("%+v %v %v", tree, created, err)
	}
}
