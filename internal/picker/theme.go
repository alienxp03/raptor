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

	// Prefer Rex's UI roles for picker chrome, not terminal text/selection.
	// Custom themes and older catalogs may only provide terminal roles.
	background, foreground := t.Background, t.Foreground
	selection, selectionForeground, surface := t.Selection, t.SelectionForeground, t.Surface
	if ui := t.UI; ui != nil {
		fallback := func(value, terminal string) string {
			if value != "" {
				return value
			}
			return terminal
		}
		background = fallback(ui.Background, background)
		foreground = fallback(ui.Foreground, foreground)
		selection = fallback(ui.Selection, selection)
		selectionForeground = fallback(ui.SelectionForeground, selectionForeground)
		surface = fallback(ui.Surface, surface)
	}

	// Compact palette (palette.go). Terminals cannot reproduce native glass;
	// paint the resolved UI colors as opaque surfaces instead.
	pickerText = pickerText.Foreground(lipgloss.Color(foreground))
	pickerMuted = pickerMuted.Foreground(ansi(8))
	pickerAccent = pickerAccent.Foreground(lipgloss.Color(t.Accent))
	pickerInput = pickerInput.Foreground(lipgloss.Color(foreground)).Background(lipgloss.Color(surface))
	pickerSelected = pickerSelected.Foreground(lipgloss.Color(selectionForeground)).Background(lipgloss.Color(selection))
	pickerSurface = pickerSurface.Background(lipgloss.Color(background))
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
