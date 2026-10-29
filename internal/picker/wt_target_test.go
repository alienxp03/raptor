package picker

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
)

func TestWorktreeTargetCycle(t *testing.T) {
	cfg := config.Default()
	m := &wtModel{cfg: cfg, target: cfg.Enter}

	m.Update(tea.KeyMsg{Type: tea.KeyTab})
	if m.target != "here" {
		t.Fatalf("Tab target = %q, want here", m.target)
	}
	m.Update(tea.KeyMsg{Type: tea.KeyShiftTab})
	if m.target != "tab" {
		t.Fatalf("Shift+Tab target = %q, want tab", m.target)
	}
}

func TestWorktreeSplitTargetOpensSelection(t *testing.T) {
	m := &wtModel{
		ctx:    rex.Ctx{Block: "origin-pane"},
		rows:   []worktree{{Branch: "feat/login", Path: "/tmp/login"}},
		view:   []int{0},
		target: "tab",
	}
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlP})
	if !m.splitMode {
		t.Fatal("Ctrl+P did not enter split mode")
	}
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'h'}})
	if m.target != "pane_left" || m.chosen == nil || m.chosen.Path != "/tmp/login" || cmd == nil {
		t.Fatalf("split selection = target %q, chosen %#v, cmd %v", m.target, m.chosen, cmd)
	}
}
