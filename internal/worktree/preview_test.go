package worktree

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestPreviewConfigPrecedence(t *testing.T) {
	repo := fixtureRepo(t)
	t.Setenv("WORKTRUNK_WORKTREE_PATH", "")
	if err := os.Unsetenv("WORKTRUNK_WORKTREE_PATH"); err != nil {
		t.Fatal(err)
	}
	root := filepath.Dir(repo)
	system := os.Getenv("WORKTRUNK_SYSTEM_CONFIG_PATH")
	user := filepath.Join(root, "user.toml")
	t.Setenv("WORKTRUNK_CONFIG_PATH", user)
	// Use a remote identifier to exercise wildcard matching across slashes.
	if _, err := GitOut(repo, "remote", "add", "origin", "git@github.com:team/subgroup/project.git"); err != nil {
		t.Fatal(err)
	}
	cases := []struct{ system, user, want string }{
		{"", "", filepath.Join(root, "repo.feat-login")},
		{"worktree-path = '../system/{{ branch | sanitize }}'", "", filepath.Join(root, "system/feat-login")},
		{"worktree-path = '../system/{{ branch | sanitize }}'", "worktree-path = '../user/{{ branch | sanitize }}'", filepath.Join(root, "user/feat-login")},
		{"", "worktree-path = '../global/{{ branch | sanitize }}'\n[projects.'github.com/*']\nworktree-path = '../host/{{ branch | sanitize }}'\n[projects.'github.com/team/*']\nworktree-path = '../team/{{ branch | sanitize }}'", filepath.Join(root, "team/feat-login")},
		{"", "[projects.'github.com/team/*']\nworktree-path = '../team/{{ branch | sanitize }}'\n[projects.'github.com/team/subgroup/project']\nworktree-path = '../exact/{{ branch }}'", filepath.Join(root, "exact/feat/login")},
	}
	for i, tc := range cases {
		t.Run(fmt.Sprint(i), func(t *testing.T) {
			if err := os.WriteFile(system, []byte(tc.system), 0600); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(user, []byte(tc.user), 0600); err != nil {
				t.Fatal(err)
			}
			got, err := PreviewPath(repo, "feat/login")
			if err != nil || got != tc.want {
				t.Fatalf("got %q %v, want %s", got, err, tc.want)
			}
		})
	}
}

func TestPreviewAndCreationAgreeFromLinkedWorktree(t *testing.T) {
	repo := fixtureRepo(t)
	tree, _, err := switchWorktree(repo, "--create", "feat/first", "--base", "main")
	if err != nil {
		t.Fatal(err)
	}
	primary, err := PreviewPath(repo, "feat/second")
	if err != nil {
		t.Fatal(err)
	}
	linked, err := PreviewPath(tree.Path, "feat/second")
	if err != nil || linked != primary {
		t.Fatalf("%q %v, want %s", linked, err, primary)
	}
	if err := CreateLocal(tree.Path, "feat/second", "main", linked); err != nil {
		t.Fatal(err)
	}
	for _, tree := range List(repo) {
		if tree.Branch == "feat/second" && tree.Path == linked {
			return
		}
	}
	t.Fatal("creation did not use preview path")
}
