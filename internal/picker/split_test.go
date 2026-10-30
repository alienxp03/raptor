package picker

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/dispatch"
	"github.com/alienxp03/raptor/internal/rex"
)

func splitFixture() *dirModel {
	return &dirModel{
		ctx: rex.Ctx{Block: "origin-pane"}, target: "tab", filter: "project",
		rows: []row{{kind: "dir", path: "/tmp/project"}}, view: []int{0},
		width: 80, height: 16,
	}
}

func TestSplitModeDirections(t *testing.T) {
	for _, tt := range []struct {
		letter    string
		arrow     tea.KeyType
		target    string
		direction string
	}{
		{"h", tea.KeyLeft, "pane_left", "left"},
		{"j", tea.KeyDown, "pane_below", "below"},
		{"k", tea.KeyUp, "pane_above", "above"},
		{"l", tea.KeyRight, "pane", "right"},
	} {
		for _, key := range []tea.KeyMsg{{Type: tea.KeyRunes, Runes: []rune(tt.letter)}, {Type: tt.arrow}} {
			m := splitFixture()
			_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyCtrlP})
			if cmd != nil || !m.splitMode || m.picked != nil {
				t.Fatal("Ctrl+P must enter split mode without submitting")
			}
			_, cmd = m.Update(key)
			if cmd == nil || m.picked != &m.rows[0] || m.target != tt.target || m.filter != "project" {
				t.Fatalf("%s did not select the direction without changing search", key.String())
			}
			if _, ok := cmd().(tea.QuitMsg); !ok {
				t.Fatal("direction must submit immediately")
			}
			if got := dispatch.SplitDirection(m.target); got != tt.direction {
				t.Fatalf("split direction = %q, want %q", got, tt.direction)
			}
		}
	}
}

func TestSplitModeWithoutSelectionOrOrigin(t *testing.T) {
	for _, m := range []*dirModel{
		{ctx: rex.Ctx{Block: "origin-pane"}, target: "tab"},
		{target: "tab", rows: []row{{kind: "dir", path: "/tmp/project"}}, view: []int{0}},
		{ctx: rex.Ctx{Block: "origin-pane"}, target: "tab", rows: []row{{kind: "session"}}, view: []int{0}},
	} {
		_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyCtrlP})
		if cmd != nil || m.splitMode || m.picked != nil || m.target != "tab" {
			t.Fatal("split mode requires a directory and an origin pane")
		}
	}
}

func TestSplitModeCancelAndIgnoreOtherKeys(t *testing.T) {
	for _, cancel := range []tea.KeyType{tea.KeyEsc, tea.KeyCtrlP} {
		m := splitFixture()
		m.Update(tea.KeyMsg{Type: tea.KeyCtrlP})
		for _, key := range []tea.KeyMsg{{Type: tea.KeyTab}, {Type: tea.KeyEnter}, {Type: tea.KeyCtrlT}, {Type: tea.KeyRunes, Runes: []rune("x")}} {
			_, cmd := m.Update(key)
			if cmd != nil || !m.splitMode || m.filter != "project" || m.target != "tab" || m.picked != nil {
				t.Fatal("unbound keys must not affect search or submit in split mode")
			}
		}
		_, cmd := m.Update(tea.KeyMsg{Type: cancel})
		if cmd != nil || m.splitMode || m.filter != "project" || m.target != "tab" || m.sel != 0 {
			t.Fatal("cancel must restore search without clearing the query or selection")
		}
	}
}

func TestSplitModeHasNoModifiedDirectionAliases(t *testing.T) {
	for _, key := range []tea.KeyMsg{
		{Type: tea.KeyShiftLeft}, {Type: tea.KeyShiftRight}, {Type: tea.KeyShiftUp}, {Type: tea.KeyShiftDown},
		{Type: tea.KeyLeft, Alt: true}, {Type: tea.KeyRight, Alt: true}, {Type: tea.KeyUp, Alt: true}, {Type: tea.KeyDown, Alt: true},
	} {
		for _, active := range []bool{false, true} {
			m := splitFixture()
			m.splitMode = active
			_, cmd := m.Update(key)
			if cmd != nil || m.picked != nil || m.target != "tab" {
				t.Fatalf("unexpected modified direction alias: %s", key.String())
			}
		}
	}
}

func TestSplitModeHints(t *testing.T) {
	for _, width := range []int{24, 40, 80} {
		m := splitFixture()
		m.width = width
		if width >= 40 && !strings.Contains(ansi.Strip(m.View()), "^p split") {
			t.Fatal("missing split-mode entry hint")
		}
		m.Update(tea.KeyMsg{Type: tea.KeyCtrlP})
		output := ansi.Strip(m.View())
		if !strings.Contains(output, "h← j↓ k↑ l→") || !strings.Contains(output, "esc") {
			t.Fatal("missing direction or cancel hints")
		}
	}
}

func TestPlainArrowsStillNavigate(t *testing.T) {
	m := &dirModel{target: "tab", rows: []row{{kind: "dir"}, {kind: "dir"}}, view: []int{0, 1}}
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyDown})
	if cmd != nil || m.sel != 1 || m.picked != nil {
		t.Fatal("Down must navigate, not split")
	}
	_, cmd = m.Update(tea.KeyMsg{Type: tea.KeyUp})
	if cmd != nil || m.sel != 0 || m.picked != nil {
		t.Fatal("Up must navigate, not split")
	}
	_, cmd = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("hjkl")})
	if cmd != nil || m.filter != "hjkl" || m.picked != nil {
		t.Fatal("Vim direction letters must remain searchable outside split mode")
	}
}

func TestDefaultTargetCycle(t *testing.T) {
	cfg := config.Default()
	if cfg.Enter != "tab" {
		t.Fatal("default target must remain tab")
	}
	for _, config := range []config.Config{cfg, {}} {
		target := "tab"
		for _, want := range []string{"session", "here", "pane", "pane_left", "pane_above", "pane_below", "tab"} {
			target = dispatch.NextTarget(config, target, true)
			if target != want {
				t.Fatalf("next target = %q, want %q", target, want)
			}
		}
		if dispatch.NextTarget(config, "tab", false) != "pane_below" {
			t.Fatal("reverse cycling must wrap to pane below")
		}
	}
}
