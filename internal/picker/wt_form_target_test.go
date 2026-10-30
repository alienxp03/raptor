package picker

import (
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"
)

func TestWorktreeFormTargetChoice(t *testing.T) {
	m := &wtModel{cfg: config.Default(), ctx: rex.Ctx{Block: "origin"}, form: true, field: 2, target: "tab"}
	for _, want := range []string{"session", "here", "pane", "pane_left", "pane_above", "pane_below", "tab"} {
		_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRight})
		if cmd != nil || m.busy || m.target != want || m.field != 2 {
			t.Fatalf("target = %q, want %q; selection must not submit", m.target, want)
		}
	}
	m.Update(tea.KeyMsg{Type: tea.KeyLeft})
	if m.target != "pane_below" {
		t.Fatal("Left must cycle backwards")
	}
	m.Update(tea.KeyMsg{Type: tea.KeyTab})
	if m.field != 3 || m.target != "pane_below" {
		t.Fatal("Tab must focus Create without changing the target")
	}
	m.Update(tea.KeyMsg{Type: tea.KeyTab})
	if m.field != 0 {
		t.Fatal("Tab must wrap to branch")
	}
	m.Update(tea.KeyMsg{Type: tea.KeyShiftTab})
	if m.field != 3 {
		t.Fatal("Shift+Tab must wrap backwards")
	}
	m.field = 0
	m.Update(tea.KeyMsg{Type: tea.KeyRight})
	if m.target != "pane_below" {
		t.Fatal("Arrows outside target field must not change the target")
	}
}

func TestWorktreeFormTargetsWithoutOrigin(t *testing.T) {
	m := &wtModel{cfg: config.Default(), form: true, field: 2, target: "tab"}
	for _, want := range []string{"session", "tab"} {
		m.Update(tea.KeyMsg{Type: tea.KeyRight})
		if m.target != want {
			t.Fatalf("target = %q, want %q without origin pane", m.target, want)
		}
	}
}

func TestWorktreeFormGreenFocus(t *testing.T) {
	previous := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(previous) })
	for field, value := range []string{"feat/demo│", "main ›", "session", "▸ Create"} {
		m := &wtModel{form: true, field: field, branch: "feat/demo", base: "main", target: "session", width: 80, height: 18}
		view := m.View()
		if !strings.Contains(view, pickerAccent.Bold(true).Render(value)) {
			t.Fatalf("field %d must use green focus", field)
		}
		if field != 3 && !strings.Contains(view, pickerAccent.Render("Create")) {
			t.Fatal("Create action must use green")
		}
	}
}

func TestWorktreeFormDefaultPathAndBottomAction(t *testing.T) {
	m := &wtModel{form: true, root: "/trees/project", base: "main", target: "tab", width: 80, height: 18}
	view := ansi.Strip(m.View())
	if !strings.Contains(view, "Destination /trees/project") {
		t.Fatal("Default destination must be visible before entering a branch")
	}
	lines := strings.Split(view, "\n")
	action := lines[m.height-3]
	if !strings.HasSuffix(strings.TrimRight(action, " "), "Create") || strings.Index(action, "Create") < m.width/2 {
		t.Fatalf("Create action must be anchored at bottom right: %q", action)
	}
}

func TestWorktreeFormLabeledPaths(t *testing.T) {
	m := &wtModel{form: true, repo: "/source/project", root: "/trees/project", branch: "feat/demo", base: "main", target: "session", width: 80, height: 18}
	plain := ansi.Strip(m.View())
	for _, text := range []string{"Repo        /source/project", "Destination /trees/project/feature-demo"} {
		if !strings.Contains(plain, text) {
			t.Fatalf("missing labeled path %q: %s", text, plain)
		}
	}
}

func TestWorktreeFormTargetVisible(t *testing.T) {
	for _, size := range [][2]int{{80, 22}, {40, 18}, {24, 12}} {
		m := &wtModel{form: true, field: 2, target: "session", branch: "feat/demo", base: "main", width: size[0], height: size[1]}
		view := m.View()
		plain := ansi.Strip(view)
		for _, label := range []string{"Repo", "Branch", "Base", "Open in", "session", "Destination", "Create"} {
			if !strings.Contains(plain, label) {
				t.Fatalf("%v: missing %q: %s", size, label, plain)
			}
		}
		if strings.Count(plain, "^o") != 1 || strings.Contains(plain, "Create & open as") {
			t.Fatalf("%v: repeated target or shortcut noise: %s", size, plain)
		}
		lines := strings.Split(view, "\n")
		if len(lines) != size[1] {
			t.Fatalf("%v: unexpected height %d", size, len(lines))
		}
		for _, line := range lines {
			if lipgloss.Width(line) > size[0] {
				t.Fatalf("%v: overflowing line %q", size, line)
			}
		}
	}
}
