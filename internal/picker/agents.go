package picker

import (
	"fmt"
	"strings"
	"time"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/rex"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

type agentsLoadedMsg struct {
	request uint64
	entries []rex.AgentEntry
	err     error
}

func (m *dirModel) switchView(view int) tea.Cmd {
	if view != 0 && view != 2 {
		return nil
	}
	m.viewStates[m.viewMode] = dirViewState{m.filter, m.sel}
	m.viewMode = view
	m.filter, m.sel = m.viewStates[view].filter, m.viewStates[view].sel
	m.splitMode = false
	m.applyCurrentFilter()
	switch view {
	case 2:
		return m.loadAgents(false)
	default:
		return m.refreshRepos()
	}
}

// Capture values only: Rex calls never run inside Update.
func (m *dirModel) loadAgents(force bool) tea.Cmd {
	if m.agentsLoading && !force {
		return nil
	}
	m.agentsRequest++
	m.agentsLoading = true
	request, session := m.agentsRequest, m.ctx.Session
	return func() tea.Msg {
		entries, err := rex.AgentEntries(session)
		return agentsLoadedMsg{request: request, entries: entries, err: err}
	}
}

func sameAgent(a, b rex.AgentEntry) bool {
	return a.SessionID == b.SessionID && a.WindowID == b.WindowID && a.BlockID == b.BlockID && a.AgentID == b.AgentID
}

func (m *dirModel) acceptAgents(msg agentsLoadedMsg) {
	if msg.request != m.agentsRequest || !m.agentsLoading {
		return
	}
	initial := !m.agentSnapshot && len(m.agents) == 0
	m.agentsLoading = false
	m.agentsLoaded = true
	if msg.err != nil {
		m.err = msg.err.Error()
		return // A failed refresh keeps the cache.
	}
	active := dirViewState{m.filter, m.sel}
	if m.viewMode != 2 {
		m.filter, m.sel = m.viewStates[2].filter, m.viewStates[2].sel
	}
	var selected rex.AgentEntry
	hadSelection := false
	if entry := m.selectedAgent(); entry != nil {
		selected, hadSelection = *entry, true
	}
	m.agentSnapshot = true
	// Record current data, but keep shortcuts and group membership stable.
	m.pendingAgents = append([]rex.AgentEntry{}, msg.entries...)
	m.projectActivity(msg.entries)
	m.captureAgentGroups()
	if initial {
		m.agents = append([]rex.AgentEntry{}, msg.entries...)
	} else {
		m.agents = stableAgentRefresh(m.agents, msg.entries)
	}
	m.applyAgentFilter()
	if hadSelection {
		for position, index := range m.agentsView {
			if sameAgent(m.agents[index], selected) {
				m.sel = position
				break
			}
		}
	}
	m.viewStates[2] = dirViewState{m.filter, m.sel}
	if m.viewMode != 2 {
		m.filter, m.sel = active.filter, active.sel
	}
}

func stableAgentRefresh(previous, incoming []rex.AgentEntry) []rex.AgentEntry {
	key := func(e rex.AgentEntry) [4]string {
		return [4]string{e.SessionID, e.WindowID, e.BlockID, e.AgentID}
	}
	remaining := make(map[[4]string]rex.AgentEntry, len(incoming))
	for _, entry := range incoming {
		remaining[key(entry)] = entry
	}
	ordered := make([]rex.AgentEntry, 0, len(incoming))
	for _, entry := range previous {
		if updated, ok := remaining[key(entry)]; ok {
			ordered = append(ordered, updated)
			delete(remaining, key(entry))
		}
	}
	return ordered
}

func (m *dirModel) applyAgentFilter() {
	m.captureAgentGroups()
	m.agentsView = catalog.FilterAgents(m.agents, m.filter)
	if m.sel >= len(m.agentsView) {
		m.sel = len(m.agentsView) - 1
	}
	if m.sel < 0 {
		m.sel = 0
	}
}

func (m *dirModel) selectedAgent() *rex.AgentEntry {
	if m.sel < 0 || m.sel >= len(m.agentsView) {
		return nil
	}
	return &m.agents[m.agentsView[m.sel]]
}

func (m *dirModel) updateAgents(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c":
		return m, tea.Quit
	case "esc":
		return m, tea.Quit
	case "ctrl+u":
		m.filter = ""
	case "backspace":
		if r := []rune(m.filter); len(r) > 0 {
			m.filter = string(r[:len(r)-1])
		}
	case "up", "ctrl+k":
		if m.sel > 0 {
			m.sel--
		}
		return m, nil
	case "down", "ctrl+j":
		if m.sel < len(m.agentsView)-1 {
			m.sel++
		}
		return m, nil
	case "alt+1", "alt+2", "alt+3", "alt+4", "alt+5", "alt+6", "alt+7", "alt+8", "alt+9":
		number := int(msg.String()[len(msg.String())-1] - '0')
		if number > len(m.agentsView) {
			return m, nil
		}
		m.sel = number - 1
		return m.jumpSelectedAgent()
	case "enter":
		return m.jumpSelectedAgent()
	default:
		// All control actions, including close, rename, pin and create, are ignored.
		if msg.Type != tea.KeyRunes && msg.Type != tea.KeySpace {
			return m, nil
		}
		m.filter += string(msg.Runes)
	}
	// A changed query is a new intent: admit deferred records and regroup.
	if m.pendingAgents != nil {
		m.agents = append([]rex.AgentEntry{}, m.pendingAgents...)
	}
	rex.SortGroups(m.agents)
	m.agentGroups = nil
	m.applyAgentFilter()
	return m, nil
}

func (m *dirModel) jumpSelectedAgent() (tea.Model, tea.Cmd) {
	if entry := m.selectedAgent(); entry != nil {
		copy := *entry
		m.jumpedAgent = &copy
		return m, tea.Quit
	}
	return m, nil
}

func pickerAgentGlyph(app string) string {
	switch strings.ToLower(strings.TrimSpace(app)) {
	case "pi":
		return "π"
	case "codex":
		return "◎"
	case "claude":
		return "✳"
	default:
		return "◇"
	}
}

func pickerAgentContext(entry rex.AgentEntry, name string) string {
	session, window := entry.SessionLabel, entry.WindowLabel
	if session == "" {
		session = entry.SessionID
	}
	if window == "" {
		window = entry.WindowID
	}
	// A leading dot is meaningful in a name, but not for duplicate context.
	normalize := func(s string) string {
		return strings.ToLower(strings.TrimPrefix(strings.TrimSpace(s), "."))
	}
	parts := make([]string, 0, 2)
	for _, part := range []string{session, window} {
		part = strings.TrimSpace(part)
		if part == "" || normalize(part) == normalize(name) {
			continue
		}
		if len(parts) == 0 || normalize(part) != normalize(parts[len(parts)-1]) {
			parts = append(parts, part)
		}
	}
	return strings.Join(parts, "/")
}

func pickerAgentRow(entry rex.AgentEntry, position, width int, selected bool) string {
	return pickerAgentRowFrame(entry, position, width, selected, 0)
}

func pickerAgentRowFrame(entry rex.AgentEntry, position, width int, selected bool, frame int) string {
	style := pickerText
	if selected {
		style = pickerSelected.Bold(true)
	}
	prefix := ""
	if position >= 1 && position <= 9 {
		prefix = fmt.Sprintf("%d ", position)
	}
	prefix += pickerAgentGlyph(entry.App) + " "
	name := strings.TrimSpace(entry.Label)
	if name == "" {
		name = "Agent"
	}
	indicator := activityIndicator(entry.State, entry.State == "working", frame)
	available := maxInt(width-2, 0) // row rail and space
	context := ""
	if available > 0 {
		context = ansi.Truncate(pickerAgentContext(entry, name), maxInt(available/2, 1), "…")
		if age := agentAge(entry.UpdatedAt, time.Now()); age != "" && available-lipgloss.Width(context)-lipgloss.Width(prefix)-lipgloss.Width(indicator)-len(age) >= 8 {
			context += " " + age
		}
	}
	leftWidth := available
	if context != "" {
		leftWidth = maxInt(leftWidth-lipgloss.Width(context)-2, 0)
	}
	nameWidth := maxInt(leftWidth-lipgloss.Width(prefix)-lipgloss.Width(indicator), 0)
	left := style.Render(prefix+ansi.Truncate(name, nameWidth, "…")) + indicator
	left = ansi.Truncate(left, leftWidth, "…")
	content := left
	if context != "" {
		content += strings.Repeat(" ", maxInt(available-lipgloss.Width(left)-lipgloss.Width(context), 0)) + pickerMuted.Render(context)
	}
	return pickerRow(content, width, selected)
}

func (m *dirModel) viewAgents() string {
	width := m.width - 2
	blank := pickerLine("", width)
	lines := []string{pickerSearch(m.filter, width, "agents")}
	if m.height >= 8 {
		lines = append(lines, pickerPills(2, width))
	}
	lines = append(lines, blank)
	maxRows := maxInt(m.height-len(lines)-2, 0)
	display := m.agentDisplayRows(maxRows)
	for n := 0; n < maxRows; n++ {
		if n < len(display) {
			r := display[n]
			if r.spacer {
				lines = append(lines, blank)
			} else if r.header != "" {
				lines = append(lines, pickerLine(pickerMuted.Bold(true).Render(" "+r.header), width))
			} else {
				vi := r.position
				lines = append(lines, pickerAgentRowFrame(m.agents[m.agentsView[vi]], vi+1, width, vi == m.sel, m.activityFrame))
			}
		} else if n == 0 {
			message := " No matching agents"
			if !m.agentsLoaded {
				message = " Loading agents…"
			}
			lines = append(lines, pickerLine(pickerMuted.Render(message), width))
		} else {
			lines = append(lines, blank)
		}
	}
	lines = append(lines, pickerRule(width))
	footer := pickerFooter(pickerText.Render("enter")+pickerMuted.Render(" jump"), pickerMuted.Render("⇥ repos · esc dismiss"), "enter jump · esc dismiss", width)
	if m.err != "" {
		footer = pickerLine(styErr.Render(m.err), width)
	}
	return strings.Join(append(lines, footer), "\n")
}
