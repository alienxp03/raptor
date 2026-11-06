package picker

import (
	"fmt"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
)

func TestSessionRowsShowHierarchy(t *testing.T) {
	for _, width := range []int{24, 44, 78} {
		for _, selected := range []bool{false, true} {
			parent := ansi.Strip(pickerSessionRow(rex.SessionEntry{Kind: "session", Label: "personal"}, 1, width, selected))
			child := ansi.Strip(pickerSessionRow(rex.SessionEntry{Kind: "tab", Label: "dotfiles", SessionLabel: "personal"}, 2, width, selected))
			if strings.Contains(child, "personal") || strings.Index(child, "dotfiles") <= strings.Index(parent, "personal") {
				t.Fatalf("tabs must be indented without repeated session labels: %q / %q", parent, child)
			}
			if lipgloss.Width(parent) != width+2 || lipgloss.Width(child) != width+2 {
				t.Fatalf("session row overflow: %q / %q", parent, child)
			}
		}
	}
	pills := ansi.Strip(pickerPills(1, 78))
	if !strings.Contains(pills, "Sessions") || !strings.Contains(pills, "⇥ Switch view") || strings.Contains(pills, "Tabs") {
		t.Fatalf("incorrect view labels: %q", pills)
	}
}

func TestPickerPaintRestoresBackground(t *testing.T) {
	previous := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(previous) })
	for _, style := range []lipgloss.Style{pickerSurface, pickerInput, pickerSelected} {
		prefix := strings.SplitN(style.Render("x"), "x", 2)[0]
		content := pickerAccent.Render("label") + "   "
		painted := pickerPaint(style, content)
		if !strings.Contains(painted, "\x1b[0m"+prefix+"   ") {
			t.Fatalf("background not restored after nested style: %q", painted)
		}
		if ansi.Strip(painted) != "label   " {
			t.Fatal("painting changed content")
		}
	}
}

func TestSelectionHighlightsLabelOnly(t *testing.T) {
	previous := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(previous) })
	for _, selected := range []bool{false, true} {
		line := pickerDirectory("/tmp/sample-project", 50, selected)
		marker := pickerRail.Render("▍")
		if selected {
			marker = pickerMark.Render("▍")
		}
		if !strings.Contains(line, marker) {
			t.Fatal("missing selection rail")
		}
		if selected {
			label := pickerSelected.Bold(true).Render("/tmp/sample-project")
			surface := strings.SplitN(pickerSurface.Render("x"), "x", 2)[0]
			if !strings.Contains(line, label+surface+" ") {
				t.Fatalf("selection background extends past label: %q", line)
			}
		}
	}
}

func TestWorktreeColumnsStayAligned(t *testing.T) {
	for _, width := range []int{38, 78, 100} {
		for _, selected := range []bool{false, true} {
			for _, branch := range []string{"main", "feat/long-branch-name", strings.Repeat("界", 30)} {
				line := ansi.Strip(pickerEntry(branch, "/tmp/wt", width, selected))
				column := strings.Index(line, "/tmp/wt")
				if column < 0 || lipgloss.Width(line[:column]) != width/2+3 {
					t.Fatalf("path column moved: %q", line)
				}
				if lipgloss.Width(line) != width+2 {
					t.Fatalf("row overflow: %q", line)
				}
			}
			line := ansi.Strip(pickerEntry("main", "/very/long/"+strings.Repeat("parent/", 20)+"feature-login", width, selected))
			if !strings.Contains(line, "…") || !strings.HasSuffix(strings.TrimSpace(line), "feature-login") {
				t.Fatalf("long path lost its folder: %q", line)
			}
		}
	}
}

func TestPickerSearchPrompt(t *testing.T) {
	for _, label := range []string{"directory", "worktree", "base", "repository"} {
		for _, query := range []string{"", "login"} {
			line := ansi.Strip(pickerSearch(query, 50, label))
			if !strings.Contains(line, label+" ❯ "+query+"│") {
				t.Fatalf("unexpected prompt: %q", line)
			}
		}
	}
}

func TestPickerSearchKeepsCursorVisible(t *testing.T) {
	for _, width := range []int{12, 24, 60} {
		for _, query := range []string{"", "sample-project", strings.Repeat("界", 50), strings.Repeat("x", 100)} {
			line := pickerSearch(query, width)
			if lipgloss.Width(line) != width+2 {
				t.Fatalf("width %d, query %q: line width %d", width, query, lipgloss.Width(line))
			}
			if !strings.Contains(ansi.Strip(line), "│") {
				t.Fatalf("cursor hidden: %q", ansi.Strip(line))
			}
		}
	}
}

func TestDirectoryPickerScrollAndEmptyState(t *testing.T) {
	m := &dirModel{width: 40, height: 12, cfg: config.Default(), target: "session"}
	for i := 0; i < 30; i++ {
		m.rows = append(m.rows, row{kind: "dir", label: fmt.Sprintf("project-%02d", i), path: fmt.Sprintf("/workspace/project-%02d", i)})
	}
	m.applyFilter()
	m.sel = 29
	output := ansi.Strip(m.View())
	if !strings.Contains(output, "▍ /workspace/project-29") {
		t.Fatal("selected row is outside the viewport")
	}
	m.filter = "no-such-directory"
	m.applyFilter()
	output = ansi.Strip(m.View())
	if !strings.Contains(output, "No matching directories") || !strings.Contains(output, "Open as: session") {
		t.Fatal("empty state or target hint missing")
	}
}

func TestDirectoryPickerFitsSmallViewports(t *testing.T) {
	for width := 1; width <= 90; width++ {
		for height := 1; height <= 24; height++ {
			m := &dirModel{width: width, height: height, target: "pane_below"}
			lines := strings.Split(m.View(), "\n")
			if len(lines) != height {
				t.Fatalf("%dx%d: got %d lines", width, height, len(lines))
			}
			for _, line := range lines {
				if lipgloss.Width(line) > width {
					t.Fatalf("%dx%d: overflowing line %q", width, height, line)
				}
			}
		}
	}
}
