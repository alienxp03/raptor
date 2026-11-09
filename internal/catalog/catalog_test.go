package catalog

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/paths"
	"github.com/alienxp03/raptor/internal/rex"
	"github.com/alienxp03/raptor/internal/worktree"
	"github.com/sahilm/fuzzy"
)

func TestDirectoryOrderAndMatching(t *testing.T) {
	dirs := []string{"/workspace/beta", "/workspace/alpha", "/workspace/beta", "/other/alphabet"}
	items := DirectoryItems(dirs, false)
	if len(items) != len(dirs) {
		t.Fatal("directory entries were removed")
	}
	for i, item := range items {
		if item.Path != dirs[i] || item.Label != paths.Basename(dirs[i]) {
			t.Fatalf("order or label changed: %+v", items)
		}
	}
	if got := FilterDirectories(items, ""); !reflect.DeepEqual(got, []int{0, 1, 2, 3}) {
		t.Fatal(got)
	}
	if got := FilterDirectories(items, "beta"); !reflect.DeepEqual(got, []int{2, 0, 3}) {
		t.Fatal(got)
	}
	if got := FilterDirectories(items, "not-a-match"); len(got) != 0 {
		t.Fatal(got)
	}
	entries := make([]string, len(items))
	for i, item := range items {
		entries[i] = item.Label + " " + paths.HomeRelative(item.Path)
	}
	for _, query := range []string{"alp", "wrkbet", "oth", "aa"} {
		want := []int{}
		for _, m := range fuzzy.Find(query, entries) {
			want = append(want, m.Index)
		}
		if got := FilterDirectories(items, query); !reflect.DeepEqual(got, want) {
			t.Fatalf("query %q: %v want %v", query, got, want)
		}
	}
}

func TestWorktreeMatching(t *testing.T) {
	items := []worktree.Worktree{
		{Path: "/repos/project", Branch: "main", IsMain: true},
		{Path: "/trees/project/feature-login", Branch: "feat/login"},
		{Path: "/trees/project/fix-api", Branch: "fix/api"},
	}
	if got := FilterWorktrees(items, ""); !reflect.DeepEqual(got, []int{0, 1, 2}) {
		t.Fatal(got)
	}
	if got := FilterWorktrees(items, "flgn"); !reflect.DeepEqual(got, []int{1}) {
		t.Fatal(got)
	}
	if got := FilterWorktrees(items, "fapi"); !reflect.DeepEqual(got, []int{2, 1}) {
		t.Fatal(got)
	}
	if got := FilterWorktrees(items, "no-such-tree"); len(got) != 0 {
		t.Fatal(got)
	}
	entries := make([]string, len(items))
	for i, item := range items {
		entries[i] = item.Branch + " " + paths.HomeRelative(item.Path)
	}
	for _, query := range []string{"prj", "ft", "main", "trees"} {
		want := []int{}
		for _, m := range fuzzy.Find(query, entries) {
			want = append(want, m.Index)
		}
		if got := FilterWorktrees(items, query); !reflect.DeepEqual(got, want) {
			t.Fatalf("query %q: %v want %v", query, got, want)
		}
	}
}

func TestRepositoryDiscoveryAndMetadata(t *testing.T) {
	isolateWorktrunk(t)
	repo := filepath.Join(t.TempDir(), ".project")
	if err := os.Mkdir(repo, 0755); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{
		{"init", "-b", "main"}, {"config", "user.name", "Test"}, {"config", "user.email", "test@example.com"},
		{"-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "initial"},
	} {
		if _, err := worktree.GitOut(repo, args...); err != nil {
			t.Fatal(err)
		}
	}
	repo = worktree.RepoRoot(repo)
	sub := filepath.Join(repo, "sub")
	if err := os.Mkdir(sub, 0755); err != nil {
		t.Fatal(err)
	}
	items := DirectoryItems([]string{t.TempDir(), sub, repo, sub}, true)
	if !reflect.DeepEqual(items, []Directory{{Path: repo, Label: ".project"}}) {
		t.Fatalf("roots not unique: %+v", items)
	}
	cfg := config.Default()
	cfg.WorktreeRoot = t.TempDir()
	info := ListWorktrees(repo, cfg)
	if len(info.Items) != 1 || !info.Items[0].IsMain || info.BaseBranch != "main" || !reflect.DeepEqual(info.Branches, []string{"main"}) {
		t.Fatalf("metadata: %+v", info)
	}
	if info.SuggestedBranch == "" {
		t.Fatal("missing default branch suggestion")
	}
	if err := worktree.Validate(repo, info.SuggestedBranch, info.BaseBranch, worktree.Path(repo, info.SuggestedBranch, cfg)); err != nil {
		t.Fatalf("unavailable suggestion: %v", err)
	}
	if entries, err := os.ReadDir(cfg.WorktreeRoot); err != nil || len(entries) != 0 {
		t.Fatalf("metadata created destinations: %v %v", entries, err)
	}
	if len(worktree.LocalBranches(repo)) != 1 || len(worktree.List(repo)) != 1 {
		t.Fatal("metadata created a branch or worktree")
	}
	if got := filepath.Join(info.Root, "feat-shared"); got != worktree.Path(repo, "feat/shared", cfg) {
		t.Fatalf("destination differs: %s", got)
	}
	// Invoking from a secondary worktree must retain the primary repo's folder.
	secondary := worktree.Path(repo, "feat/shared", cfg)
	if err := worktree.CreateLocal(repo, "feat/shared", "main", secondary); err != nil {
		t.Fatal(err)
	}
	linked := ListWorktrees(secondary, cfg)
	if linked.Root != info.Root || linked.BaseBranch != "feat/shared" || len(linked.Items) != 2 {
		t.Fatalf("linked metadata: %+v", linked)
	}
	if _, err := worktree.GitOut(repo, "checkout", "--detach"); err != nil {
		t.Fatal(err)
	}
	detached := ListWorktrees(repo, cfg)
	if len(detached.Branches) == 0 || detached.BaseBranch != detached.Branches[0] {
		t.Fatalf("detached fallback: %+v", detached)
	}
}

func TestWorktreeSuggestionUnavailableKeepsMetadata(t *testing.T) {
	for _, committed := range []bool{false, true} {
		t.Run(map[bool]string{false: "unborn", true: "destination-error"}[committed], func(t *testing.T) {
			isolateWorktrunk(t)
			repo := t.TempDir()
			if _, err := worktree.GitOut(repo, "init", "-b", "main"); err != nil {
				t.Fatal(err)
			}
			root := t.TempDir()
			cfg := config.Config{WorktreeRoot: root}
			if committed {
				if _, err := worktree.GitOut(repo, "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "initial"); err != nil {
					t.Fatal(err)
				}
				cfg.WorktreeRoot = filepath.Join(root, "loop")
				t.Setenv("WORKTRUNK_WORKTREE_PATH", filepath.Join(cfg.WorktreeRoot, "{{ branch | sanitize }}"))
				if err := os.Symlink(cfg.WorktreeRoot, cfg.WorktreeRoot); err != nil {
					t.Fatal(err)
				}
			}
			info := ListWorktrees(repo, cfg)
			if info.SuggestedBranch != "" || len(info.Items) != 1 || !info.Items[0].IsMain || info.BaseBranch != "main" {
				t.Fatalf("suggestion failure changed metadata: %+v", info)
			}
			if committed && !reflect.DeepEqual(info.Branches, []string{"main"}) {
				t.Fatalf("branches lost: %v", info.Branches)
			}
		})
	}
}

func TestResolveRepoWithoutOrigin(t *testing.T) {
	// RepoRoot("") normally uses cwd. The backend must not infer its own repo.
	if root, err := ResolveRepo(rex.Ctx{}, ""); err != nil || root != "" {
		t.Fatalf("unexpected fallback: %q %v", root, err)
	}
	if root, err := ResolveRepo(rex.Ctx{}, t.TempDir()); err == nil || root != "" {
		t.Fatalf("invalid explicit repo accepted: %q %v", root, err)
	}
}
