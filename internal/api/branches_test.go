package api

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
	"github.com/alienxp03/raptor/internal/worktree"
)

func TestLocalBranchSearch(t *testing.T) {
	repo := fixtureRepo(t)
	for _, args := range [][]string{
		{"branch", "feat/long-login"}, {"branch", "fix/login"}, {"branch", "login"},
		{"update-ref", "refs/remotes/origin/remote-only", "HEAD"},
		{"tag", "tag-only"},
		// An unusable remote must not affect local branch search.
		{"remote", "add", "origin", filepath.Join(t.TempDir(), "missing.git")},
	} {
		if _, err := worktree.GitOut(repo, args...); err != nil {
			t.Fatal(err)
		}
	}
	sub := filepath.Join(repo, "sub")
	if err := os.Mkdir(sub, 0755); err != nil {
		t.Fatal(err)
	}
	call := client(t, New(rex.Ctx{}, config.Default()))
	branches := []string{"feat/long-login", "fix/login", "login", "main"}
	for _, query := range []string{"", "login", "flgn", "MAIN", "remote-only", "tag-only", "no-such-branch"} {
		t.Run(query, func(t *testing.T) {
			var result struct {
				Branches []string `json:"branches"`
			}
			if err := call("worktrees.branches", map[string]any{"repo": sub, "query": query}, &result); err != "" {
				t.Fatal(err)
			}
			want := catalog.FilterBranches(branches, query)
			if !reflect.DeepEqual(result.Branches, want) {
				t.Fatalf("got %#v, want %#v", result.Branches, want)
			}
			if query == "login" && result.Branches[0] != "login" {
				t.Fatalf("exact match not first: %v", result.Branches)
			}
		})
	}
	// Search reads current local refs, not a cached worktree listing.
	if _, err := worktree.GitOut(repo, "branch", "new-local"); err != nil {
		t.Fatal(err)
	}
	var result branchesResult
	if err := call("worktrees.branches", map[string]any{"repo": repo, "query": "new-local"}, &result); err != "" || !reflect.DeepEqual(result.Branches, []string{"new-local"}) {
		t.Fatalf("fresh branches: %+v, %s", result, err)
	}
}

func TestLocalBranchSearchEmptyRepo(t *testing.T) {
	repo := t.TempDir()
	if _, err := worktree.GitOut(repo, "init", "-b", "main"); err != nil {
		t.Fatal(err)
	}
	call := client(t, New(rex.Ctx{}, config.Default()))
	for _, query := range []string{"", "main"} {
		var result branchesResult
		if err := call("worktrees.branches", map[string]any{"repo": repo, "query": query}, &result); err != "" || result.Branches == nil || len(result.Branches) != 0 {
			t.Fatalf("empty repo: %+v, %s", result, err)
		}
	}
}

func TestLocalBranchSearchRepoResolutionAndErrors(t *testing.T) {
	repo := fixtureRepo(t)
	t.Setenv("RAPTOR_TEST_CWD", repo)
	fakeTool(t, "rex", "printf '%s\\n' \"$RAPTOR_TEST_CWD\"\n")
	origin := client(t, New(rex.Ctx{Block: "origin"}, config.Default()))
	var result branchesResult
	if err := origin("worktrees.branches", map[string]any{"query": "main"}, &result); err != "" || !reflect.DeepEqual(result.Branches, []string{"main"}) {
		t.Fatalf("origin resolution: %+v, %s", result, err)
	}
	call := client(t, New(rex.Ctx{}, config.Default()))
	for _, tc := range []struct {
		params map[string]any
		want   string
	}{
		{map[string]any{}, "choose a repository"},
		{map[string]any{"repo": ""}, "choose a repository"},
		{map[string]any{"repo": t.TempDir()}, "not a git repository"},
		{map[string]any{"repo": filepath.Join(t.TempDir(), "missing")}, "not a git repository"},
		{map[string]any{"repo": 42}, "cannot unmarshal"},
		{map[string]any{"repo": repo, "query": 42}, "cannot unmarshal"},
	} {
		if err := call("worktrees.branches", tc.params, nil); !strings.Contains(err, tc.want) {
			t.Fatalf("params %v: got %q, want %q", tc.params, err, tc.want)
		}
	}
	// Invalid origin also must not fall back to the backend working directory.
	t.Setenv("RAPTOR_TEST_CWD", t.TempDir())
	if err := origin("worktrees.branches", map[string]any{}, nil); err != "choose a repository" {
		t.Fatalf("invalid origin: %s", err)
	}
}
