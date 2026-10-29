package main

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// A quiet terminal palette. Use the same surface in every picker and form.
var (
	pickerText     = lipgloss.NewStyle().Foreground(lipgloss.Color("#B9C5D1"))
	pickerMuted    = lipgloss.NewStyle().Foreground(lipgloss.Color("#82909D"))
	pickerAccent   = lipgloss.NewStyle().Foreground(lipgloss.Color("#A4C5B0"))
	pickerInput    = lipgloss.NewStyle().Foreground(lipgloss.Color("#B9C5D1")).Background(lipgloss.Color("#252E37"))
	pickerSelected = lipgloss.NewStyle().Foreground(lipgloss.Color("#C3CDD7")).Background(lipgloss.Color("#343E48"))
	pickerSurface  = lipgloss.NewStyle().Background(lipgloss.Color("#1B2229"))
	pickerRail     = lipgloss.NewStyle().Foreground(lipgloss.Color("#414B56"))
	pickerMark     = lipgloss.NewStyle().Foreground(lipgloss.Color("#C78091"))
	pickerPrompt   = lipgloss.NewStyle().Foreground(lipgloss.Color("#8DA7BC")).Bold(true)
	pickerCursor   = lipgloss.NewStyle().Foreground(lipgloss.Color("#4DA6FF"))
)

func pickerTiny(width, height int) string {
	lines := make([]string, height)
	for i := range lines {
		content := ""
		if i == 0 {
			content = ansi.Truncate("Search…", width, "")
		}
		lines[i] = pickerSurface.Render(padRight(content, width))
	}
	return strings.Join(lines, "\n")
}

// Lip Gloss does not restore outer colours after an inner ANSI reset.
// Reapply them so nested text styles cannot leave gaps in the surface.
func pickerPaint(style lipgloss.Style, content string) string {
	probe := style.Render("x")
	prefix := strings.SplitN(probe, "x", 2)[0]
	if prefix == "" {
		return content
	}
	return prefix + strings.ReplaceAll(content, "\x1b[0m", "\x1b[0m"+prefix) + "\x1b[0m"
}

func pickerLine(content string, width int) string {
	return pickerPaint(pickerSurface, " "+padRight(ansi.Truncate(content, width, "…"), width)+" ")
}

func pickerSearch(query string, width int, labels ...string) string {
	label := "search"
	if len(labels) > 0 {
		label = labels[0]
	}
	prompt := ansi.Truncate(label, maxInt(width-4, 0), "…") + " ❯ "
	if width < 4 {
		prompt = ""
	}
	// Keep the editing end visible, including the cursor, for long queries.
	available := maxInt(width-lipgloss.Width(prompt)-1, 0)
	content := pickerPrompt.Render(prompt) + pickerText.Render(pickerTail(query, available)) + pickerCursor.Render("│")
	return pickerLine(content, width)
}

func pickerDirectory(path string, width int, selected bool) string {
	style := pickerText
	if selected {
		style = pickerSelected.Bold(true)
	}
	return pickerRow(style.Render(pickerTail(homeRelative(path), maxInt(width-3, 0))), width, selected)
}

func pickerEntry(label, detail string, width int, selected bool) string {
	nameStyle, detailStyle := pickerText, pickerMuted
	if selected {
		nameStyle = pickerSelected.Bold(true)
	}
	nameWidth := maxInt(width-3, 0)
	if width >= 36 {
		nameWidth = maxInt(width/2-2, 1)
	}
	name := ansi.Truncate(label, nameWidth, "…")
	content := nameStyle.Render(name)
	if width >= 36 {
		gap := strings.Repeat(" ", maxInt(nameWidth-lipgloss.Width(name)+2, 2))
		pathWidth := maxInt(width-2-nameWidth-3, 0)
		content += detailStyle.Render(gap + pickerTail(detail, pathWidth))
	}
	return pickerRow(content, width, selected)
}

func pickerTail(value string, width int) string {
	if width <= 0 {
		return ""
	}
	length := lipgloss.Width(value)
	if length <= width {
		return value
	}
	for cut := length - width + 1; cut <= length; cut++ {
		result := ansi.TruncateLeft(value, cut, "…")
		if lipgloss.Width(result) <= width {
			return result
		}
	}
	return "…"
}

func pickerRule(width int) string {
	return pickerLine(lipgloss.NewStyle().Foreground(lipgloss.Color("#363E39")).Render(strings.Repeat("─", width)), width)
}

func pickerRow(content string, width int, selected bool) string {
	rail := pickerRail
	if selected {
		rail = pickerMark
	}
	// Highlight the label only. Leave the column gap, detail, and padding quiet.
	return pickerLine(rail.Render("▍")+" "+content, width)
}

// Always keep the primary action visible, even on a narrow phone viewport.
func pickerFooter(left, right, compact string, width int) string {
	gap := width - lipgloss.Width(left) - lipgloss.Width(right)
	if gap >= 2 {
		return pickerLine(left+strings.Repeat(" ", gap)+right, width)
	}
	return pickerLine(pickerMuted.Render(compact), width)
}
