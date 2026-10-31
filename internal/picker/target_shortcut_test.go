package picker

import (
	"testing"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
	tea "github.com/charmbracelet/bubbletea"
)

func TestCtrlOCyclesListTargets(t *testing.T) {
	cfg := config.Default()
	dirs := &dirModel{cfg: cfg, ctx: rex.Ctx{Block: "origin"}, target: "tab"}
	trees := &wtModel{cfg: cfg, ctx: rex.Ctx{Block: "origin"}, target: "tab"}
	for _, want := range []string{"session", "here", "pane_right", "pane_below", "tab"} {
		_, dirCmd := dirs.Update(tea.KeyMsg{Type: tea.KeyCtrlO})
		_, treeCmd := trees.Update(tea.KeyMsg{Type: tea.KeyCtrlO})
		if dirs.target != want || trees.target != want || dirCmd != nil || treeCmd != nil {
			t.Fatalf("Ctrl+O must cycle list targets without submitting; want %s", want)
		}
	}
}

func TestCtrlOTargetParity(t *testing.T) {
	for _, cfg := range []config.Config{config.Default(), {Targets: []string{"tab", "pane_below", "session"}}} {
		for _, block := range []string{"", "origin"} {
			ctx := rex.Ctx{Block: block}
			dirs := &dirModel{cfg: cfg, ctx: ctx, target: "tab"}
			trees := &wtModel{cfg: cfg, ctx: ctx, target: "tab"}
			form := &wtModel{cfg: cfg, ctx: ctx, form: true, target: "tab"}
			// The API uses this same source for native target order.
			targets := cfg.AvailableTargets(block != "")
			for i := 1; i <= len(targets); i++ {
				want := targets[i%len(targets)]
				for _, model := range []tea.Model{dirs, trees, form} {
					model.Update(tea.KeyMsg{Type: tea.KeyCtrlO})
				}
				if dirs.target != want || trees.target != want || form.target != want {
					t.Fatalf("Ctrl+O order differs across lists/form/API: want %s", want)
				}
			}
		}
	}
}

func TestCtrlOCyclesTargetFromAnyFormField(t *testing.T) {
	for field := 0; field < 4; field++ {
		m := &wtModel{cfg: config.Default(), ctx: rex.Ctx{Block: "origin"}, form: true, field: field, target: "tab", branch: "feat/test", base: "main"}
		_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyCtrlO})
		if m.target != "session" || m.field != field || m.branch != "feat/test" || m.base != "main" || m.busy || cmd != nil {
			t.Fatalf("field %d: Ctrl+O must change target only", field)
		}
	}
}

func TestCtrlODoesNotChangeTargetBehindModal(t *testing.T) {
	for _, m := range []*wtModel{
		{cfg: config.Default(), form: true, baseSelecting: true, target: "tab"},
		{cfg: config.Default(), confirm: true, target: "tab"},
		{cfg: config.Default(), busy: true, target: "tab"},
	} {
		m.Update(tea.KeyMsg{Type: tea.KeyCtrlO})
		if m.target != "tab" {
			t.Fatal("Ctrl+O changed target behind a modal or during an operation")
		}
	}
}
