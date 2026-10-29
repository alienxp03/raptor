package main

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

func TestSearchDoesNotConsumeLetters(t *testing.T) {
	m := &dirModel{cfg: defaultConfig()}
	for _, letter := range "wqnx" {
		_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{letter}})
		if cmd != nil {
			t.Fatalf("%c triggered an action", letter)
		}
	}
	if m.filter != "wqnx" {
		t.Fatalf("query = %q", m.filter)
	}
	repo := fixtureRepo(t)
	m.rows = []row{{kind: "dir", path: repo}}
	m.view = []int{0}
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyCtrlW})
	if m.next != "wt" || cmd == nil {
		t.Fatal("Ctrl+W did not open worktrees")
	}
}

func TestDirectoryRowLayout(t *testing.T) {
	for _, width := range []int{22, 38, 78} {
		for _, selected := range []bool{false, true} {
			line := pickerDirectory("/workspace/demo", width, selected)
			plain := ansi.Strip(line)
			if lipgloss.Width(line) != width+2 {
				t.Fatalf("row width = %d, want %d", lipgloss.Width(line), width+2)
			}
			if strings.Count(plain, "demo") != 1 {
				t.Fatalf("project label missing or repeated: %q", plain)
			}
			if !strings.Contains(plain, "/workspace/demo") {
				t.Fatalf("path split into columns: %q", plain)
			}
		}
	}
}

func TestCompactPalette(t *testing.T) {
	for _, size := range [][2]int{{80, 20}, {52, 16}, {40, 12}, {24, 8}, {18, 5}} {
		m := &dirModel{width: size[0], height: size[1], cfg: defaultConfig(), target: "session", rows: []row{{kind: "dir", path: "/tmp/romhandbook", label: "romhandbook"}}, view: []int{0}}
		output := m.View()
		lines := strings.Split(output, "\n")
		if len(lines) != m.height {
			t.Fatalf("height %d, want %d", len(lines), m.height)
		}
		for _, line := range lines {
			if lipgloss.Width(line) > m.width {
				t.Fatalf("overflow: %q", line)
			}
		}
		plain := ansi.Strip(output)
		if !strings.Contains(plain, "│") {
			t.Fatal("missing empty cursor")
		}
		if !strings.Contains(ansi.Strip(lines[2]), "romhandbook") {
			t.Fatal("missing directory name in result row")
		}
		if strings.Count(plain, "romhandbook") != 1 || strings.Contains(plain, "1/1") {
			t.Fatal("unexpected selected-path or result-count footer")
		}
		if !strings.Contains(plain, "Open as: session") {
			t.Fatal("target missing from footer")
		}
		if strings.Contains(plain, "[tab]") {
			t.Fatal("unexpected Tab hint")
		}
		if strings.Contains(plain, "enter open") {
			t.Fatal("unexpected Enter hint")
		}
		if !strings.Contains(plain, "dir ❯ ") {
			t.Fatal("missing search prompt")
		}
		if strings.Contains(plain, "╭") {
			t.Fatal("unexpected decorative frame")
		}
		m.filter = "rom"
		if !strings.Contains(ansi.Strip(m.View()), "rom│") {
			t.Fatal("missing typed cursor")
		}
	}
}
