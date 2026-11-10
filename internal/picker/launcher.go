package picker

import (
	"strings"

	"github.com/alienxp03/raptor/internal/dispatch"
	worktreepkg "github.com/alienxp03/raptor/internal/worktree"
	tea "github.com/charmbracelet/bubbletea"
)

type launcherAction struct {
	label  string
	target string
	next   string
}

func (m *dirModel) openLauncherActions(path string) {
	m.actions = nil
	m.actionSel = 0
	for _, target := range m.cfg.AvailableTargets(m.ctx.Block != "") {
		label := dispatch.TargetLabel(target)
		switch target {
		case "session":
			label = "Open session"
		case "tab":
			label = "Open tab"
		case "here":
			label = "cd here"
		case "pane_right":
			label = "Split right"
		case "pane_below":
			label = "Split below"
		}
		if target == m.target {
			m.actionSel = len(m.actions)
		}
		m.actions = append(m.actions, launcherAction{label: label, target: target})
	}
	if worktreepkg.IsGitRepo(path) {
		m.actions = append(m.actions,
			launcherAction{label: "New worktree", next: "wt-create"})
	}
	m.actionMenu = true
}

func (m *dirModel) updateLauncherActions(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c":
		return m, tea.Quit
	case "esc", "backspace":
		m.actionMenu = false
	case "up", "ctrl+k":
		if m.actionSel > 0 {
			m.actionSel--
		}
	case "down", "ctrl+j":
		if m.actionSel < len(m.actions)-1 {
			m.actionSel++
		}
	case "enter":
		if len(m.actions) == 0 {
			return m, nil
		}
		chosen := m.selectedLauncher()
		if chosen == nil || chosen.dir == nil {
			return m, nil
		}
		action := m.actions[m.actionSel]
		if action.next != "" {
			m.next, m.nextRepo = action.next, worktreepkg.RepoRoot(chosen.dir.Path)
		} else {
			m.target, m.picked = action.target, &row{kind: "dir", label: chosen.dir.Label, path: chosen.dir.Path}
		}
		return m, tea.Quit
	}
	return m, nil
}

func (m *dirModel) viewLauncherActions() string {
	width := m.width - 2
	path := ""
	if row := m.selectedLauncher(); row != nil && row.dir != nil {
		path = row.dir.Path
	}
	lines := []string{pickerLine(pickerAccent.Bold(true).Render("Actions"), width), pickerDirectory(path, width, false)}
	count := maxInt(m.height-4, 0)
	start := maxInt(m.actionSel-count+1, 0)
	for n := 0; n < count; n++ {
		i := start + n
		if i < len(m.actions) {
			lines = append(lines, pickerRow(pickerText.Render(m.actions[i].label), width, i == m.actionSel))
		} else {
			lines = append(lines, pickerLine("", width))
		}
	}
	lines = append(lines, pickerRule(width), pickerLine(pickerMuted.Render("enter Run · esc Paths"), width))
	return strings.Join(lines, "\n")
}
