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

func TestTerminalCurrentRepoFlow(t *testing.T) {
	repo := worktreepkg.RepoRoot(fixtureRepo(t))
	sub := filepath.Join(repo, "sub")
	if err := os.Mkdir(sub, 0755); err != nil {
		t.Fatal(err)
	}
	bin := t.TempDir()
	t.Setenv("RAPTOR_TEST_CWD", sub)
	t.Setenv("RAPTOR_TEST_REPO", repo)
	for name, script := range map[string]string{
		"rex":    "printf '%s\\n' \"$RAPTOR_TEST_CWD\"\n",
		"zoxide": "printf '%s\\n' /other \"$RAPTOR_TEST_REPO\" \"$RAPTOR_TEST_REPO\"\n",
	} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte("#!/bin/sh\n"+script), 0755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	ctx := rex.Ctx{Block: "origin"}
	rows := loadDirRows(ctx)
	if len(rows) != 2 || !rows[0].current || rows[0].path != repo || rows[0].label != "Current repo" {
		t.Fatalf("origin repo not pinned and deduplicated: %+v", rows)
	}
	newModel := func() *dirModel {
		m := &dirModel{ctx: ctx, cfg: config.Default(), rows: rows, target: "session", width: 100, height: 12}
		m.applyFilter()
		return m
	}
	m := newModel()
	if !strings.Contains(ansi.Strip(m.View()), "Current repo") {
		t.Fatal("current repo label missing")
	}
	m.filter = "no-match"
	m.applyFilter()
	if len(m.view) != 1 || m.selected().path != repo {
		t.Fatal("current repo lost during search")
	}
	for _, target := range []string{"session", "tab", "pane"} {
		m = newModel()
		m.target = target
		_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
		if cmd == nil || m.picked == nil || m.picked.path != repo || m.target != target {
			t.Fatalf("current repo not used for %s", target)
		}
	}
	m = newModel()
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyCtrlT})
	if cmd == nil || m.next != "wt" || m.nextRepo != repo {
		t.Fatal("worktree flow must use the current repo")
	}
	for _, key := range []tea.KeyType{tea.KeyCtrlN, tea.KeyF2} {
		m = newModel()
		_, cmd = m.Update(tea.KeyMsg{Type: key})
		if cmd == nil || m.next != "wt-create" || m.nextRepo != repo {
			t.Fatal("new worktree shortcut must open Create for the current repo")
		}
	}
	m = newModel()
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlP})
	_, cmd = m.Update(tea.KeyMsg{Type: tea.KeyRight})
	if cmd == nil || m.picked == nil || m.picked.path != repo || m.target != "pane" {
		t.Fatal("split flow must use the current repo")
	}
}
