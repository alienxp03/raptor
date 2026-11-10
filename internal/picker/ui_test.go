package picker

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/rex"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
)

func TestLauncherLoadsPathsOnly(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PATH", dir)
	if err := os.WriteFile(filepath.Join(dir, "zoxide"), []byte("#!/bin/sh\nprintf '%s\\n' /demo/example /demo/tools\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	m := &dirModel{cfg: config.Default(), target: "tab", width: 60, height: 10,
		hostDirs: map[string][]catalog.Directory{}, launcherLoaded: true, ctx: rex.Ctx{}}
	m.hostOrder = []string{rex.LocalHostLabel}
	m.hostDirs[rex.LocalHostLabel] = catalog.DirectoriesOn(rex.LocalHostLabel, false)
	m.applyLauncher()
	if len(m.launcher) != 2 {
		t.Fatalf("got %d rows, want 2", len(m.launcher))
	}
	for _, r := range m.launcher {
		if r.dir == nil {
			t.Fatalf("unexpected row: %+v", r)
		}
	}
	if m.Init() == nil {
		t.Fatal("launcher must schedule background loads")
	}
	if m.agentsLoading {
		t.Fatal("activity retrieval must not load the selectable agent view")
	}
	plain := ansi.Strip(m.View())
	for _, icon := range []string{"📁", "◉", "▣", "├─", "└─"} {
		if strings.Contains(plain, icon) {
			t.Fatalf("unexpected launcher icon %q", icon)
		}
	}
	if !strings.Contains(plain, "❯") || !strings.Contains(plain, "example") || !strings.Contains(plain, "tools") {
		t.Fatal("launcher rows must show the zoxide directories")
	}
}

func TestSearchDoesNotConsumeLetters(t *testing.T) {
	m := &dirModel{cfg: config.Default()}
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
	m.filter = ""
	seedLauncher(m, []launcherRow{{dir: &catalog.Directory{Label: "repo", Path: repo}, host: rex.LocalHostLabel}})
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlN})
	if m.next != "wt-create" {
		t.Fatal("Ctrl+N did not open worktree creation")
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
		m := &dirModel{width: size[0], height: size[1], cfg: config.Default(), target: "session",
			hostDirs:  map[string][]catalog.Directory{rex.LocalHostLabel: {{Label: "demo", Path: "/tmp/demo"}}},
			hostOrder: []string{rex.LocalHostLabel}, launcherLoaded: true}
		m.applyLauncher()
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
		rowLine := 2
		if !strings.Contains(ansi.Strip(lines[rowLine]), "demo") {
			t.Fatalf("missing directory name in result row %d", rowLine)
		}
		if strings.Count(plain, "demo") != 1 || strings.Contains(plain, "1/1") {
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
		if !strings.Contains(plain, "❯") {
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
