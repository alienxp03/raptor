package picker

import (
	"testing"

	"github.com/charmbracelet/lipgloss"

	"github.com/alienxp03/raptor/internal/theme"
)

func TestApplyPickerThemeRoles(t *testing.T) {
	// apply mutates package styles; restore them for other picker tests.
	text, muted, accent := pickerText, pickerMuted, pickerAccent
	input, selected, surface := pickerInput, pickerSelected, pickerSurface
	rail, mark, prompt, cursor := pickerRail, pickerMark, pickerPrompt, pickerCursor
	title, dim, sel, session := styTitle, styDim, stySel, stySession
	branch, ghost, dirty, errStyle := styBranch, styGhost, styDirty, styErr
	target, border, preview := styTarget, styBorder, styPreviewB
	t.Cleanup(func() {
		pickerText, pickerMuted, pickerAccent = text, muted, accent
		pickerInput, pickerSelected, pickerSurface = input, selected, surface
		pickerRail, pickerMark, pickerPrompt, pickerCursor = rail, mark, prompt, cursor
		styTitle, styDim, stySel, stySession = title, dim, sel, session
		styBranch, styGhost, styDirty, styErr = branch, ghost, dirty, errStyle
		styTarget, styBorder, styPreviewB = target, border, preview
	})

	for _, tc := range []struct {
		name string
		ui   *theme.UIPalette
		want [5]string
	}{
		{"terminal fallback", nil, [5]string{"#111111", "#eeeeee", "#222222", "#dddddd", "#333333"}},
		{"UI roles", &theme.UIPalette{
			Background: "#444444", Foreground: "#bbbbbb", Selection: "#555555",
			SelectionForeground: "#aaaaaa", Surface: "#666666",
		}, [5]string{"#444444", "#bbbbbb", "#555555", "#aaaaaa", "#666666"}},
		{"partial UI fallback", &theme.UIPalette{Selection: "#777777"},
			[5]string{"#111111", "#eeeeee", "#777777", "#dddddd", "#333333"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			apply(&theme.Theme{
				Background: "#111111", Foreground: "#eeeeee", Selection: "#222222",
				SelectionForeground: "#dddddd", Surface: "#333333", UI: tc.ui,
			})
			got := [5]string{
				string(pickerSurface.GetBackground().(lipgloss.Color)),
				string(pickerText.GetForeground().(lipgloss.Color)),
				string(pickerSelected.GetBackground().(lipgloss.Color)),
				string(pickerSelected.GetForeground().(lipgloss.Color)),
				string(pickerInput.GetBackground().(lipgloss.Color)),
			}
			if got != tc.want {
				t.Fatalf("picker roles = %v, want %v", got, tc.want)
			}
			if got := string(pickerInput.GetForeground().(lipgloss.Color)); got != tc.want[1] {
				t.Fatalf("input foreground = %s, want %s", got, tc.want[1])
			}
		})
	}
}
