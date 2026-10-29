package main

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

func TestCompactPalette(t *testing.T) {
	for _, size := range [][2]int{{80, 20}, {40, 12}, {24, 8}} {
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
		if !strings.Contains(lines[0], "│") {
			t.Fatal("missing empty cursor")
		}
		if strings.Count(plain, "romhandbook") != 1 {
			t.Fatal("duplicate directory label")
		}
		if strings.Contains(plain, "╭") {
			t.Fatal("unexpected box border")
		}
		m.filter = "rom"
		if !strings.Contains(ansi.Strip(m.View()), "rom│") {
			t.Fatal("missing typed cursor")
		}
	}
}
