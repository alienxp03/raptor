package picker

import (
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

func TestLegacyAgentsStartupNormalizesToSessions(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	pickerRexLog(t)
	m := newDirModel(rex.Ctx{}, config.Config{Enter: "tab"}, false, 2)
	if m.viewMode != 0 || m.target != "session" {
		t.Fatal("legacy Agents must open sessions")
	}
	m.Update(tea.WindowSizeMsg{Width: 70, Height: 10})
	if strings.Contains(ansi.Strip(m.View()), "Agents") {
		t.Fatal("removed Agents UI")
	}
	if m.Init() == nil || !m.launcherSessionsLoading || m.agentsLoading {
		t.Fatal("startup must load sessions, not Agents")
	}
}

func TestRemovedShortcutsDoNotExposeBrowsers(t *testing.T) {
	m := &dirModel{width: 80, height: 10}
	for _, key := range []tea.KeyType{tea.KeyCtrlA, tea.KeyTab, tea.KeyShiftTab, tea.KeyCtrlT} {
		m.Update(tea.KeyMsg{Type: key})
		if m.viewMode != 0 || m.next != "" || m.agentsLoading {
			t.Fatalf("removed shortcut exposed UI: %v", key)
		}
	}
	for _, modal := range []wtModel{{}, {form: true}, {loading: true}, {confirm: true}, {baseSelecting: true}, {splitMode: true}, {busy: true}} {
		modal.Update(tea.KeyMsg{Type: tea.KeyCtrlA})
		if modal.action == "agents" {
			t.Fatal("worktree shortcut exposed Agents")
		}
	}
}

func TestWorktreeBrowserPublicEntryRemoved(t *testing.T) {
	if code := RunWorktrees(rex.Ctx{}, config.Config{}, ""); code != 2 {
		t.Fatalf("browser exit=%d", code)
	}
	if code := runWorktreePicker(rex.Ctx{}, config.Config{}, "", false, false); code != 2 {
		t.Fatalf("browser flow exit=%d", code)
	}
}

func TestCtrlADoesNotInterruptModalInput(t *testing.T) {
	m := &dirModel{actionMenu: true}
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlA})
	if m.viewMode != 0 || m.agentsLoading || !m.actionMenu {
		t.Fatal("Ctrl+A interrupted modal input")
	}
}
