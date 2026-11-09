package picker

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
	worktreepkg "github.com/alienxp03/raptor/internal/worktree"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

func TestTerminalLauncherFlow(t *testing.T) {
	repo := worktreepkg.RepoRoot(fixtureRepo(t))
	bin := t.TempDir()
	t.Setenv("RAPTOR_TEST_REPO", repo)
	script := "printf '%s\\n' \"$RAPTOR_TEST_REPO\"\n"
	if err := os.WriteFile(filepath.Join(bin, "zoxide"), []byte("#!/bin/sh\n"+script), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	ctx := rex.Ctx{Block: "origin"}
	newModel := func() *dirModel {
		m := &dirModel{ctx: ctx, cfg: config.Default(), target: "session", width: 100, height: 12,
			hostDirs: map[string][]catalog.Directory{}, launcherLoaded: true,
			hostOrder: []string{rex.LocalHostLabel}}
		m.loadPins()
		m.hostDirs[rex.LocalHostLabel] = catalog.DirectoriesOn(rex.LocalHostLabel, false)
		m.applyLauncher()
		return m
	}
	m := newModel()
	if len(m.launcherView) != 1 || m.launcher[m.launcherView[0].index].dir == nil || m.launcher[m.launcherView[0].index].dir.Path != repo {
		t.Fatalf("launcher must list the zoxide directory: %+v", launcherLabels(m))
	}
	if strings.Contains(ansi.Strip(m.View()), "Current repo") {
		t.Fatal("stale current repo label")
	}
	m.filter = "no-match"
	m.applyLauncher()
	if len(m.launcherView) != 0 || m.selectedLauncher() != nil {
		t.Fatal("filter must hide non-matching rows")
	}
	// Overridden targets dispatch the directory; the default creates a session.
	for _, target := range []string{"tab", "pane_right"} {
		m = newModel()
		m.target = target
		m.Update(tea.KeyMsg{Type: tea.KeyEnter})
		if m.picked == nil || m.picked.path != repo || m.target != target {
			t.Fatalf("directory not used for %s", target)
		}
	}
	m = newModel()
	m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if m.launchDir == nil || m.launchDir.Path != repo || m.launchDir.Host != rex.LocalHostLabel {
		t.Fatalf("default Enter must launch a session at the directory: %+v", m.launchDir)
	}
	m = newModel()
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlT})
	if m.next != "wt" || m.nextRepo != repo {
		t.Fatal("worktree flow must use the selected repo")
	}
	for _, key := range []tea.KeyType{tea.KeyCtrlN, tea.KeyF2} {
		m = newModel()
		m.Update(tea.KeyMsg{Type: key})
		if m.next != "wt-create" || m.nextRepo != repo {
			t.Fatal("new worktree shortcut must open Create for the selected repo")
		}
	}
	m = newModel()
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlP})
	m.Update(tea.KeyMsg{Type: tea.KeyRight})
	if m.picked == nil || m.picked.path != repo || m.target != "pane_right" {
		t.Fatal("split flow must use the selected repo")
	}
}
