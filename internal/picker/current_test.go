package picker

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
	worktreepkg "github.com/alienxp03/raptor/internal/worktree"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

func TestTerminalDirectoryFlow(t *testing.T) {
	repo := worktreepkg.RepoRoot(fixtureRepo(t))
	bin := t.TempDir()
	t.Setenv("RAPTOR_TEST_REPO", repo)
	script := "printf '%s\\n' \"$RAPTOR_TEST_REPO\"\n"
	if err := os.WriteFile(filepath.Join(bin, "zoxide"), []byte("#!/bin/sh\n"+script), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	ctx := rex.Ctx{Block: "origin"}
	rows := loadDirRows(ctx)
	if len(rows) != 1 || rows[0].path != repo {
		t.Fatalf("directory list must follow zoxide without pinning: %+v", rows)
	}
	newModel := func() *dirModel {
		m := &dirModel{ctx: ctx, cfg: config.Default(), rows: rows, target: "session", width: 100, height: 12}
		m.applyFilter()
		return m
	}
	m := newModel()
	if strings.Contains(ansi.Strip(m.View()), "Current repo") {
		t.Fatal("stale current repo label")
	}
	m.filter = "no-match"
	m.applyFilter()
	if len(m.view) != 0 || m.selected() != nil {
		t.Fatal("filter must hide non-matching directories")
	}
	for _, target := range []string{"session", "tab", "pane_right"} {
		m = newModel()
		m.target = target
		_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
		if cmd == nil || m.picked == nil || m.picked.path != repo || m.target != target {
			t.Fatalf("directory not used for %s", target)
		}
	}
	m = newModel()
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyCtrlT})
	if cmd == nil || m.next != "wt" || m.nextRepo != repo {
		t.Fatal("worktree flow must use the selected repo")
	}
	for _, key := range []tea.KeyType{tea.KeyCtrlN, tea.KeyF2} {
		m = newModel()
		_, cmd = m.Update(tea.KeyMsg{Type: key})
		if cmd == nil || m.next != "wt-create" || m.nextRepo != repo {
			t.Fatal("new worktree shortcut must open Create for the selected repo")
		}
	}
	m = newModel()
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlP})
	_, cmd = m.Update(tea.KeyMsg{Type: tea.KeyRight})
	if cmd == nil || m.picked == nil || m.picked.path != repo || m.target != "pane_right" {
		t.Fatal("split flow must use the selected repo")
	}
}
