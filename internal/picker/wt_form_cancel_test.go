package picker

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestDirectCreateEscapeCloses(t *testing.T) {
	m := &wtModel{form: true, closeOnCancel: true, branch: "feat/test"}
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEsc})
	if cmd == nil {
		t.Fatal("Escape must close a directly opened form")
	}
	if _, ok := cmd().(tea.QuitMsg); !ok {
		t.Fatal("Escape must quit the picker")
	}
	if m.action == "back" || m.chosen != nil {
		t.Fatal("Direct form cancellation must not navigate or open a worktree")
	}
}

func TestListCreateEscapeReturnsToList(t *testing.T) {
	m := &wtModel{form: true}
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEsc})
	if cmd != nil || m.form {
		t.Fatal("A form opened from the list must return to the list")
	}
}

func TestDirectCreateBaseEscapeDismissesChooserFirst(t *testing.T) {
	m := &wtModel{form: true, closeOnCancel: true, baseSelecting: true}
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEsc})
	if cmd != nil || m.baseSelecting || !m.form {
		t.Fatal("Escape in the base chooser must return to the form first")
	}
	_, cmd = m.Update(tea.KeyMsg{Type: tea.KeyEsc})
	if cmd == nil {
		t.Fatal("The next Escape must close the directly opened form")
	}
}
