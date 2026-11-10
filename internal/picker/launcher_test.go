package picker

import (
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
	worktreepkg "github.com/alienxp03/raptor/internal/worktree"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

func launcherFixture(t *testing.T, path string) *dirModel {
	t.Helper()
	cfg := config.Default()
	cfg.Targets = []string{"tab", "session", "here", "pane_right", "pane_below"}
	dir := catalog.Directory{Label: "project", Path: path}
	m := &dirModel{cfg: cfg, ctx: rex.Ctx{Block: "origin"}, launcherMode: true,
		target: "tab", width: 40, height: 12,
		hostDirs:  map[string][]catalog.Directory{rex.LocalHostLabel: {dir}},
		hostOrder: []string{rex.LocalHostLabel}, launcherLoaded: true}
	m.applyLauncher()
	return m
}

func TestLauncherEnterPreviewsBeforeDispatch(t *testing.T) {
	m := launcherFixture(t, t.TempDir())
	m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if !m.actionMenu || m.picked != nil {
		t.Fatal("first Enter must only show actions")
	}
	if len(m.actions) != 5 {
		t.Fatalf("unexpected actions: %+v", m.actions)
	}
	m.Update(tea.KeyMsg{Type: tea.KeyDown})
	m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if m.picked == nil || m.target != "session" {
		t.Fatal("second Enter must execute the selected action")
	}
}

func TestLauncherBackPreservesPathSearch(t *testing.T) {
	m := launcherFixture(t, t.TempDir())
	m.filter = "project"
	m.applyLauncher()
	m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	m.Update(tea.KeyMsg{Type: tea.KeyEsc})
	if m.actionMenu || m.filter != "project" || m.sel != 0 || m.picked != nil {
		t.Fatal("back must preserve path selection/query")
	}
}

func TestLauncherGitActionsAndContext(t *testing.T) {
	repo := fixtureRepo(t)
	m := launcherFixture(t, repo)
	m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if len(m.actions) != 6 {
		t.Fatalf("Git actions missing: %+v", m.actions)
	}
	for _, action := range m.actions {
		if action.next == "wt" || action.next == "agents" {
			t.Fatal("removed browser action exposed")
		}
	}
	m.actionSel = 5
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil || m.next != "wt-create" || m.nextRepo != worktreepkg.RepoRoot(repo) || m.picked != nil {
		t.Fatal("new worktree must carry selected repository without dispatch")
	}
	m = launcherFixture(t, t.TempDir())
	m.ctx.Block = ""
	m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if len(m.actions) != 2 {
		t.Fatal("without origin block, only session/tab should be offered")
	}
}

func TestLauncherEmptyAndNarrow(t *testing.T) {
	m := launcherFixture(t, t.TempDir())
	m.filter = "no-match"
	m.applyLauncher()
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd != nil || m.actionMenu {
		t.Fatal("empty results must not close or open actions")
	}
	m.filter = ""
	m.applyLauncher()
	m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	for _, width := range []int{20, 32, 60} {
		m.width = width
		m.actionSel = len(m.actions) - 1
		lines := strings.Split(ansi.Strip(m.View()), "\n")
		if len(lines) != m.height {
			t.Fatalf("height overflow at %d: %d", width, len(lines))
		}
		for _, line := range lines {
			if lipgloss.Width(line) > width {
				t.Fatalf("width overflow at %d: %q", width, line)
			}
		}
	}
}
