package picker

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/alienxp03/raptor/internal/paths"
	"github.com/alienxp03/raptor/internal/rex"
)

// Fallback compact palette (sampled from Rex's Sonoran Dusk). ApplyTheme
// replaces these with the active Rex theme when it can be resolved.
var (
	pickerText     = lipgloss.NewStyle().Foreground(lipgloss.Color("#EDEAE6"))
	pickerSession  = lipgloss.NewStyle().Foreground(lipgloss.Color("#ADD0AD"))
	pickerFolder   = lipgloss.NewStyle().Foreground(lipgloss.Color("#C6C9C6"))
	pickerMuted    = lipgloss.NewStyle().Foreground(lipgloss.Color("#9A928A"))
	pickerAccent   = lipgloss.NewStyle().Foreground(lipgloss.Color("#B88242"))
	pickerInput    = lipgloss.NewStyle().Foreground(lipgloss.Color("#F5F5F5")).Background(lipgloss.Color("#3E3A39"))
	pickerSelected = lipgloss.NewStyle().Foreground(lipgloss.Color("#272422")).Background(lipgloss.Color("#B88242"))
	pickerSurface  = lipgloss.NewStyle().Background(lipgloss.Color("#272422"))
	pickerRail     = lipgloss.NewStyle().Foreground(lipgloss.Color("#4A443F"))
	pickerMark     = lipgloss.NewStyle().Foreground(lipgloss.Color("#C96F5A"))
	pickerPrompt   = lipgloss.NewStyle().Foreground(lipgloss.Color("#B88242")).Bold(true)
	pickerCursor   = lipgloss.NewStyle().Foreground(lipgloss.Color("#B88242"))
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
	return pickerRow(style.Render(pickerTail(paths.HomeRelative(path), maxInt(width-3, 0))), width, selected)
}

// pickerDirectoryRow adds the alt-number and pin columns to a directory row.
func pickerDirectoryRow(path string, pinned bool, position, width int, selected bool) string {
	return pickerDirectoryRowActivity(path, pinned, position, width, selected, "")
}

func pickerDirectoryRowActivity(path string, pinned bool, position, width int, selected bool, indicator string) string {
	style := pickerFolder
	if selected {
		style = pickerSelected.Bold(true)
	}
	prefix := ""
	if position >= 1 && position <= 9 && width >= 24 {
		label := fmt.Sprintf("%d ", position)
		if selected {
			prefix = style.Render(label)
		} else {
			prefix = pickerRail.Render(label)
		}
	}
	if pinned {
		if selected {
			prefix += style.Render("★ ")
		} else {
			prefix += pickerAccent.Render("★ ")
		}
	}
	return pickerRow(prefix+style.Render(pickerTail(paths.HomeRelative(path), maxInt(width-3-lipgloss.Width(prefix)-lipgloss.Width(indicator), 0)))+indicator, width, selected)
}

// pickerSessionRow indents tabs below their selectable parent session.
func pickerSessionRow(entry rex.SessionEntry, position, width int, selected bool) string {
	return pickerSessionRowActivity(entry, position, width, selected, activityIndicator(entry.State, entry.Working, 0))
}

func pickerSessionRowActivity(entry rex.SessionEntry, position, width int, selected bool, indicator string) string {
	style := pickerText
	if entry.Kind == "session" {
		style = pickerSession
	}
	if selected {
		style = pickerSelected.Bold(true)
	}
	prefix := ""
	if position >= 1 && position <= 9 && width >= 24 {
		label := fmt.Sprintf("%d ", position)
		if selected {
			prefix = style.Render(label)
		} else {
			prefix = pickerRail.Render(label)
		}
	}
	if entry.Kind != "session" {
		prefix += " "
	}
	if entry.Active {
		if selected {
			prefix += style.Render("● ")
		} else {
			prefix += pickerAccent.Render("● ")
		}
	}
	detail := ""
	if entry.Kind == "session" {
		detail = "Session"
		style = style.Bold(true)
	}
	nameWidth := maxInt(width-3-lipgloss.Width(prefix)-lipgloss.Width(indicator), 1)
	if width >= 36 && detail != "" {
		nameWidth = maxInt(nameWidth-lipgloss.Width(detail)-2, 1)
	}
	name := ansi.Truncate(entry.Label, nameWidth, "…")
	content := prefix + style.Render(name) + indicator
	if width >= 36 && detail != "" {
		gap := strings.Repeat(" ", maxInt(nameWidth-lipgloss.Width(name)+2, 2))
		pathWidth := maxInt(width-2-lipgloss.Width(prefix)-nameWidth-3, 0)
		detailStyle := pickerMuted
		if selected {
			detailStyle = style
		}
		content += detailStyle.Render(gap + pickerTail(detail, pathWidth))
	}
	return pickerRow(content, width, selected)
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

// Worktree rows show branch names only; the selected path has its own detail.
func pickerWorktreeBranch(branch string, width int, selected bool) []string {
	available := maxInt(width-3, 1)
	parts := []string{ansi.Truncate(branch, available, "…")}
	style := pickerText
	if selected {
		style = pickerSelected.Bold(true)
		parts = strings.Split(ansi.Hardwrap(branch, available, true), "\n")
		if len(parts) > 2 {
			parts = []string{parts[0], ansi.Truncate(strings.Join(parts[1:], ""), available, "…")}
		}
	}
	lines := make([]string, 0, len(parts))
	for _, part := range parts {
		lines = append(lines, pickerRow(style.Render(part), width, selected))
	}
	return lines
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
	return pickerLine(pickerRail.Render(strings.Repeat("─", width)), width)
}

func pickerRow(content string, width int, selected bool) string {
	rail := pickerRail
	if selected {
		rail = pickerMark
	}
	return pickerRowStyled(content, width, selected, rail)
}

// pickerRowStyled renders a row whose rail carries a custom color — the
// launcher's live-session state bar (idle green, working accent, blocked red).
func pickerRowStyled(content string, width int, selected bool, rail lipgloss.Style) string {
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
