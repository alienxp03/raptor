package picker

import (
	"os"

	"github.com/charmbracelet/lipgloss"

	"github.com/alienxp03/raptor/internal/theme"
)

// ApplyTheme remaps the built-in palettes to the active Rex theme. On any
// failure the built-in colors stay. Set RAPTOR_THEME=ansi to force the
// built-in palette (also used by tests for deterministic output).
func ApplyTheme() {
	if os.Getenv("RAPTOR_THEME") == "ansi" {
		return
	}
	t, err := theme.Resolve(theme.Options{})
	if err != nil {
		return
	}
	apply(t)
}

func apply(t *theme.Theme) {
	ansi := func(i int) lipgloss.Color {
		if i < len(t.ANSI) {
			return lipgloss.Color(t.ANSI[i])
		}
		return lipgloss.Color("")
	}
	// Terminal picker (ANSI-index styles in ui.go).
	styTitle = styTitle.Foreground(ansi(12))
	styDim = styDim.Foreground(ansi(8))
	stySel = stySel.Foreground(ansi(15))
	stySession = stySession.Foreground(ansi(10))
	styBranch = styBranch.Foreground(ansi(13))
	styGhost = styGhost.Foreground(ansi(11))
	styDirty = styDirty.Foreground(ansi(9))
	styErr = styErr.Foreground(ansi(9))
	styTarget = styTarget.Foreground(ansi(14))
	styBorder = styBorder.Foreground(ansi(8))
	styPreviewB = styPreviewB.Foreground(ansi(4))

	// Compact palette (palette.go), mirroring the native app's roles.
	pickerText = pickerText.Foreground(lipgloss.Color(t.Foreground))
	pickerMuted = pickerMuted.Foreground(ansi(8))
	pickerAccent = pickerAccent.Foreground(lipgloss.Color(t.Accent))
	pickerInput = pickerInput.Foreground(lipgloss.Color(t.Foreground)).Background(lipgloss.Color(t.Surface))
	pickerSelected = pickerSelected.Foreground(lipgloss.Color(t.SelectionForeground)).Background(lipgloss.Color(t.Selection))
	pickerSurface = pickerSurface.Background(lipgloss.Color(t.Background))
	pickerRail = pickerRail.Foreground(ansi(8))
	pickerMark = pickerMark.Foreground(ansi(9))
	pickerPrompt = pickerPrompt.Foreground(lipgloss.Color(t.Accent)).Bold(true)
	pickerCursor = pickerCursor.Foreground(lipgloss.Color(t.Cursor))
}

// ThemeJSON is the protocol payload for the native app.
func ThemeJSON() any {
	if os.Getenv("RAPTOR_THEME") == "ansi" {
		return map[string]any{"error": "disabled by RAPTOR_THEME=ansi"}
	}
	t, err := theme.Resolve(theme.Options{})
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	return t
}
