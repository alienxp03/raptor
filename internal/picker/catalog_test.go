package picker

import (
	"reflect"
	"testing"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
	worktreepkg "github.com/alienxp03/raptor/internal/worktree"
)

func TestDirectoryPickerUsesCatalogQuery(t *testing.T) {
	items := catalog.DirectoryItems([]string{"/workspace/beta", "/workspace/alpha", "/workspace/beta"}, false)
	m := &dirModel{}
	for _, item := range items {
		m.rows = append(m.rows, row{kind: "dir", path: item.Path, label: item.Label})
	}
	for _, query := range []string{"", "alp", "wbet", "no-such-match"} {
		m.filter, m.sel = query, 999
		m.applyFilter()
		if want := catalog.FilterDirectories(items, query); !reflect.DeepEqual(m.view, want) {
			t.Fatalf("query %q: %v want %v", query, m.view, want)
		}
		if m.sel < 0 || (len(m.view) > 0 && m.sel >= len(m.view)) {
			t.Fatalf("invalid selection: %d", m.sel)
		}
	}
}

func TestWorktreePickerUsesCatalog(t *testing.T) {
	repo := fixtureRepo(t)
	cfg := config.Default()
	cfg.WorktreeRoot = t.TempDir()
	path := worktreepkg.Path(repo, "feat/shared", cfg)
	if err := worktreepkg.CreateLocal(repo, "feat/shared", "main", path); err != nil {
		t.Fatal(err)
	}
	for _, origin := range []string{repo, path} {
		m := newWtModel(rex.Ctx{}, cfg, origin)
		info := catalog.ListWorktrees(origin, cfg)
		if !reflect.DeepEqual(m.rows, info.Items) || !reflect.DeepEqual(m.branches, info.Branches) || m.base != info.BaseBranch || m.root != info.Root {
			t.Fatal("picker metadata differs from catalog")
		}
		m.branch = "fix/next"
		if m.destination() != worktreepkg.Path(origin, m.branch, cfg) {
			t.Fatal("picker destination differs from API destination")
		}
		for _, query := range []string{"", "fsh", "main", "no-such-match"} {
			m.filter, m.sel = query, 999
			m.applyFilter()
			if want := catalog.FilterWorktrees(info.Items, query); !reflect.DeepEqual(m.view, want) {
				t.Fatalf("query %q: %v want %v", query, m.view, want)
			}
		}
	}
}
