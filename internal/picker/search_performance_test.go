package picker

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
	tea "github.com/charmbracelet/bubbletea"
)

func cachedSearchModel(t testing.TB, count int) *dirModel {
	t.Helper()
	root := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", root)
	t.Setenv("PATH", root+string(os.PathListSeparator)+os.Getenv("PATH"))
	if err := os.WriteFile(filepath.Join(root, "rex"), []byte("#!/bin/sh\necho '{}'\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	items := make([]catalog.Directory, count)
	for i := range items {
		label := fmt.Sprintf("project-%03d", i)
		path := filepath.Join(root, label)
		if err := os.Mkdir(path, 0o700); err != nil {
			t.Fatal(err)
		}
		items[i] = catalog.Directory{Path: path, Label: label}
	}
	m := newDirModel(rex.Ctx{}, config.Default(), false, 0)
	m.hostOrder = []string{rex.LocalHostLabel}
	m.hostDirs[rex.LocalHostLabel] = items
	m.activityEntries = []rex.AgentEntry{{Cwd: items[0].Path, State: "working"}}
	m.applyLauncher()
	return m
}

func TestTypingFiltersExistingLauncherSnapshot(t *testing.T) {
	m := cachedSearchModel(t, 32)
	before := &m.launcher[0]
	if !before.dir.Working || !before.local {
		t.Fatal("local activity must be projected before filtering")
	}
	// Pending discovery/activity changes are not part of this snapshot yet.
	// Search must not read/recompose those sources or redo filesystem work.
	m.hostDirs[rex.LocalHostLabel] = nil
	m.activityEntries = nil
	for _, key := range []tea.KeyMsg{
		{Type: tea.KeyRunes, Runes: []rune("project-00")},
		{Type: tea.KeyBackspace},
		{Type: tea.KeyCtrlU},
	} {
		m.Update(key)
		if len(m.launcher) != 32 || &m.launcher[0] != before || !m.launcher[0].dir.Working {
			t.Fatal("typing rebuilt the catalog instead of filtering cached rows")
		}
	}
	if len(m.launcherView) != 32 {
		t.Fatal("clearing search did not restore the full snapshot")
	}
	m.applyLauncher()
	if len(m.launcher) != 0 {
		t.Fatal("a real catalog refresh must still replace the snapshot")
	}
}

func BenchmarkLauncherComposeAndFilter(b *testing.B) {
	m := cachedSearchModel(b, 192)
	m.filter = "project-1"
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		m.applyLauncher()
	}
}

func BenchmarkLauncherSnapshotFilter(b *testing.B) {
	m := cachedSearchModel(b, 192)
	m.filter = "project-1"
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		m.filterLauncher()
	}
}
