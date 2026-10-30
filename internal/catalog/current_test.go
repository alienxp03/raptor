package catalog

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/alienxp03/raptor/internal/worktree"
)

func TestCurrentDirectoryPinned(t *testing.T) {
	cwd := t.TempDir()
	items := DirectoryItemsForCwd([]string{"/other", cwd, cwd}, cwd, false)
	if len(items) != 2 || items[0].Path != cwd || !items[0].Current || items[0].Label != "Current directory" {
		t.Fatalf("current directory not pinned and deduplicated: %+v", items)
	}
	if got := FilterDirectories(items, "no-match"); len(got) != 1 || got[0] != 0 {
		t.Fatalf("current directory lost during search: %v", got)
	}
	if got := FilterDirectories(items, "other"); len(got) != 2 || got[0] != 0 || got[1] != 1 {
		t.Fatalf("matching directories must follow current entry: %v", got)
	}
	if got := DirectoryItemsForCwd(nil, cwd, true); len(got) != 0 {
		t.Fatalf("non-repository included in repository picker: %+v", got)
	}
	if got := DirectoryItemsForCwd(nil, "", false); len(got) != 0 {
		t.Fatalf("missing context must not use backend cwd: %+v", got)
	}
}

func TestCurrentRepositoryFromSubdirectory(t *testing.T) {
	repo := t.TempDir()
	if _, err := worktree.GitOut(repo, "init"); err != nil {
		t.Fatal(err)
	}
	repo = worktree.RepoRoot(repo)
	sub := filepath.Join(repo, "sub")
	if err := os.Mkdir(sub, 0755); err != nil {
		t.Fatal(err)
	}
	for _, reposOnly := range []bool{false, true} {
		items := DirectoryItemsForCwd([]string{repo, sub}, sub, reposOnly)
		if len(items) == 0 || items[0].Path != repo || items[0].Label != "Current repo" || !items[0].Current {
			t.Fatalf("origin repo not pinned: %+v", items)
		}
		for _, item := range items[1:] {
			if item.Path == repo {
				t.Fatalf("duplicate current repo: %+v", items)
			}
		}
	}
}
