package rex

import (
	"strings"
	"unicode"

	tea "github.com/charmbracelet/bubbletea"
)

func (ctx Ctx) TitleCommand() tea.Cmd {
	// Titles come from another terminal. Do not pass control characters into OSC.
	title := strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, ctx.Title)
	if title == "" {
		return nil
	}
	return tea.SetWindowTitle(title)
}
