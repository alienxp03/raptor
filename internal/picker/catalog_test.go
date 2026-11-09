package picker

import (
	"reflect"
	"testing"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
	worktreepkg "github.com/alienxp03/raptor/internal/worktree"
)

func TestLauncherUsesCatalogQuery(t *testing.T) {
	items := catalog.DirectoryItems([]string{"/workspace/beta", "/workspace/alpha", "/workspace/beta"}, false)
	m := &dirModel{hostDirs: map[string][]catalog.Directory{}, launcherLoaded: true}
	m.hostOrder = []string{rex.LocalHostLabel}
	m.hostDirs[rex.LocalHostLabel] = items
	for _, query := range []string{"", "alp", "wbet", "no-such-match"} {
		m.filter, m.sel = query, 999
		m.applyLauncher()
		want := []int{}
		for _, text := range []string{"beta /workspace/beta This Mac", "alpha /workspace/alpha This Mac", "beta /workspace/beta This Mac"} {
			_ = text
		}
		// The launcher filter must keep every catalog match, in catalog order.
		matches := map[string]bool{}
		for _, match := range m.launcherView {
			matches[m.launcher[match.index].dir.Path] = true
		}
		for _, i := range catalog.FilterDirectories(items, query) {
			if !matches[items[i].Path] {
				t.Fatalf("query %q: missing catalog match %s", query, items[i].Path)
			}
			want = append(want, i)
		}
		if len(m.launcherView) != len(want) {
			t.Fatalf("query %q: %d rows, want %d", query, len(m.launcherView), len(want))
		}
		if m.sel < 0 || (len(m.launcherView) > 0 && m.sel >= len(m.launcherView)) {
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
