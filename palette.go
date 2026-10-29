package main

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// Rex's native picker: inset graphite search, blue selection, quiet action row.
// Leave the outer surface to the terminal theme to avoid mobile background seams.
var (
	pickerText     = lipgloss.NewStyle().Foreground(lipgloss.Color("#EEEEEF"))
	pickerMuted    = lipgloss.NewStyle().Foreground(lipgloss.Color("#929397"))
	pickerInput    = lipgloss.NewStyle().Foreground(lipgloss.Color("#EEEEEF")).Background(lipgloss.Color("#353637"))
	pickerSelected = lipgloss.NewStyle().Foreground(lipgloss.Color("#FFFFFF")).Background(lipgloss.Color("#195FC6"))
)

func pickerLine(content string, width int) string {
	return " " + padRight(ansi.Truncate(content, width, "…"), width) + " "
}
func pickerSearch(query string, width int) string {
	content := ansi.Truncate(" ⌕  "+query+"│", width, "…")
	return " " + pickerInput.Render(padRight(content, width)) + " "
}
func pickerRule(width int) string {
	return pickerLine(lipgloss.NewStyle().Foreground(lipgloss.Color("#343539")).Render(strings.Repeat("─", width)), width)
}
func pickerRow(content string, width int, selected bool) string {
	content = padRight(ansi.Truncate(content, width, "…"), width)
	if selected {
		return " " + pickerSelected.Render(content) + " "
	}
	return pickerLine(content, width)
}
