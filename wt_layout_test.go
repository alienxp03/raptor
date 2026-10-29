package main

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

func TestWorktreeRemovalShortcut(t *testing.T) {
	m := &wtModel{width: 80, height: 20, rows: []worktree{{Branch: "feat/login", Path: "/tmp/login"}}, view: []int{0}}
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlD})
	if m.confirm {
		t.Fatal("Ctrl+D must not remove worktrees")
	}
	footer := ansi.Strip(m.View())
	if !strings.Contains(footer, "^n New   ^x Remove") {
		t.Fatal("missing lowercase shortcut hints")
	}
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlX})
	if !m.confirm {
		t.Fatal("Ctrl+X must request removal confirmation")
	}
}

func TestWorktreeSelectedPathDetail(t *testing.T) {
	path := "/workspace/worktrees/sample-project/feature-login-with-long-name"
	m := &wtModel{width: 40, height: 14, rows: []worktree{{Branch: "feat/login", Path: path}}, view: []int{0}}
	lines := strings.Split(ansi.Strip(m.View()), "\n")
	var detail []string
	for _, line := range lines[len(lines)-3 : len(lines)-1] {
		detail = append(detail, strings.TrimSpace(line))
	}
	if strings.Join(detail, "") != path {
		t.Fatalf("selected path was not shown in full: %q", detail)
	}
}

func TestWorktreeListFitsViewports(t *testing.T) {
	for _, path := range []string{"/tmp/sample-project", "/tmp/" + strings.Repeat("parent/", 60) + "feature-login", "/tmp/" + strings.Repeat("界/", 80)} {
		for _, size := range [][2]int{{80, 20}, {40, 12}, {39, 10}, {24, 8}, {3, 3}} {
			m := &wtModel{width: size[0], height: size[1], rows: []worktree{{Branch: "feat/login", Path: path}}, view: []int{0}}
			lines := strings.Split(m.View(), "\n")
			if len(lines) != m.height {
				t.Fatalf("%v: got %d rows", size, len(lines))
			}
			for _, line := range lines {
				if lipgloss.Width(line) > m.width {
					t.Fatalf("%v: row overflow: %q", size, line)
				}
			}
			if m.height >= 10 && !strings.Contains(ansi.Strip(lines[2]), "▍ feat/login") {
				t.Fatalf("%v: selected row missing", size)
			}
		}
	}
}
