package picker

import (
	"fmt"
	"os"
	"strings"

	"github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/rex"
)

// sessionsRow is one selectable row of the Sessions view: a session inside a
// host group, or that group's "+ New session" action (entry -1).
type sessionsRow struct {
	group int
	entry int
}

type sessionsLoadedMsg struct {
	request uint64
	groups  []rex.HostGroup
	err     error
}

// sessionCreate is the in-model "+ New session" flow: pick a directory, then
// runDirs creates and selects the session after the program exits. Keeping
// the flow inside dirModel avoids stacking a second tea program.
type sessionCreate struct {
	Host    string
	Dir     string // empty until a directory row is confirmed
	dirs    []catalog.Directory
	view    []int
	filter  string
	sel     int
	loading bool
	request uint64
}

type createDirsLoadedMsg struct {
	request uint64
	host    string
	items   []catalog.Directory
}

// loadSessions fetches every host's groups in the background. Commands capture
// values only; all model changes happen in Update. Cached groups stay visible
// while a refresh is pending.
func (m *dirModel) loadSessions(force bool) tea.Cmd {
	if m.sessionsLoading && !force {
		return nil
	}
	m.sessionsRequest++
	m.sessionsLoading = true
	request, session := m.sessionsRequest, m.ctx.Session
	return func() tea.Msg {
		return sessionsLoadedMsg{request: request, groups: rex.SessionGroups(session, nil)}
	}
}

func (m *dirModel) applySessionFilter() {
	m.sessionsView = nil
	for gi, group := range m.sessions {
		if !group.Reachable {
			continue // Unreachable hosts render a header and error only.
		}
		matches := catalog.FilterSessions(group.Entries, m.filter)
		if len(matches) == 0 && m.filter != "" {
			continue // Filtered groups disappear, including their new row.
		}
		for _, ei := range matches {
			m.sessionsView = append(m.sessionsView, sessionsRow{group: gi, entry: ei})
		}
		m.sessionsView = append(m.sessionsView, sessionsRow{group: gi, entry: -1})
	}
	if m.sel >= len(m.sessionsView) {
		m.sel = len(m.sessionsView) - 1
	}
	if m.sel < 0 {
		m.sel = 0
	}
}

func (m *dirModel) selectedSession() *sessionsRow {
	if m.sel < 0 || m.sel >= len(m.sessionsView) {
		return nil
	}
	r := m.sessionsView[m.sel]
	return &r
}

func (m *dirModel) selectedSessionEntry() *rex.SessionEntry {
	r := m.selectedSession()
	if r == nil || r.entry < 0 {
		return nil
	}
	return &m.sessions[r.group].Entries[r.entry]
}

// acceptSessions refreshes the cache without disturbing the active view.
// Keep the selected session identity when entries change order.
func (m *dirModel) acceptSessions(msg sessionsLoadedMsg) {
	if msg.request != m.sessionsRequest || !m.sessionsLoading {
		return
	}
	m.sessionsLoading = false
	m.sessionsLoaded = true
	if msg.err != nil {
		m.err = msg.err.Error()
		return // A failed refresh keeps the cache.
	}
	active := dirViewState{m.filter, m.sel}
	if m.viewMode != 1 {
		m.filter, m.sel = m.viewStates[1].filter, m.viewStates[1].sel
	}
	type selection struct{ group, id string }
	var selected selection
	had := false
	if r := m.selectedSession(); r != nil && r.entry >= 0 {
		entry := m.sessions[r.group].Entries[r.entry]
		selected = selection{m.sessions[r.group].Label, entry.ID}
		had = true
	}
	m.sessions = msg.groups
	m.applySessionFilter()
	if had {
		for position, row := range m.sessionsView {
			if row.entry < 0 {
				continue
			}
			entry := m.sessions[row.group].Entries[row.entry]
			if m.sessions[row.group].Label == selected.group && entry.ID == selected.id {
				m.sel = position
				break
			}
		}
	}
	m.viewStates[1] = dirViewState{m.filter, m.sel}
	if m.viewMode != 1 {
		m.filter, m.sel = active.filter, active.sel
	}
}

func (m *dirModel) updateSessions(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c", "esc":
		return m, tea.Quit
	case "backspace":
		if m.filter != "" {
			r := []rune(m.filter)
			m.filter = string(r[:len(r)-1])
			m.applySessionFilter()
		}
		return m, nil
	case "ctrl+u":
		m.filter = ""
		m.applySessionFilter()
		return m, nil
	case "up", "ctrl+k":
		if m.sel > 0 {
			m.sel--
		}
		return m, nil
	case "down", "ctrl+j":
		if m.sel < len(m.sessionsView)-1 {
			m.sel++
		}
		return m, nil
	case "alt+1", "alt+2", "alt+3", "alt+4", "alt+5", "alt+6", "alt+7", "alt+8", "alt+9":
		number := int(msg.String()[len(msg.String())-1] - '0')
		if number >= 1 && number <= len(m.sessionsView) {
			m.sel = number - 1
			return m.activateSession()
		}
		return m, nil
	case "enter":
		return m.activateSession()
	case "ctrl+x":
		entry := m.selectedSessionEntry()
		if entry == nil {
			return m, nil
		}
		if entry.Host == rex.LocalHostLabel && entry.ID == m.ctx.Session {
			// The backend guards API clients; the TUI repeats the check.
			m.err = "cannot close this session"
			return m, nil
		}
		copied := *entry
		m.closeSession = &copied
		return m, tea.Quit
	default:
		if msg.Type == tea.KeyRunes || msg.Type == tea.KeySpace {
			m.filter += string(msg.Runes)
			m.applySessionFilter()
			return m, nil
		}
	}
	return m, nil
}

// activateSession jumps to the selected session, or opens the create flow
// when the "+ New session" row of a reachable group is chosen.
func (m *dirModel) activateSession() (tea.Model, tea.Cmd) {
	r := m.selectedSession()
	if r == nil {
		return m, nil
	}
	if r.entry < 0 {
		m.createSession = &sessionCreate{Host: m.sessions[r.group].Label}
		return m, m.loadCreateDirs()
	}
	copied := m.sessions[r.group].Entries[r.entry]
	m.jumpSession = &copied
	return m, tea.Quit
}

// Capture values only: Rex and zoxide calls never run inside Update.
func (m *dirModel) loadCreateDirs() tea.Cmd {
	c := m.createSession
	if c == nil || c.loading {
		return nil
	}
	c.loading = true
	c.request++
	request, host := c.request, c.Host
	return func() tea.Msg {
		return createDirsLoadedMsg{request: request, host: host, items: catalog.DirectoriesOn(host, false)}
	}
}

func (m *dirModel) acceptCreateDirs(msg createDirsLoadedMsg) {
	c := m.createSession
	if c == nil || !c.loading || msg.request != c.request || msg.host != c.Host {
		return
	}
	c.loading = false
	c.dirs = msg.items
	c.applyFilter()
}

func (c *sessionCreate) applyFilter() {
	c.view = catalog.FilterDirectories(c.dirs, c.filter)
	if c.sel >= len(c.view) {
		c.sel = len(c.view) - 1
	}
	if c.sel < 0 {
		c.sel = 0
	}
}

func (m *dirModel) updateCreateSession(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	c := m.createSession
	switch msg.String() {
	case "ctrl+c":
		return m, tea.Quit
	case "esc":
		// Back to the sessions list inside the same program.
		m.createSession = nil
		m.err = ""
		return m, nil
	case "backspace":
		if c.filter != "" {
			r := []rune(c.filter)
			c.filter = string(r[:len(r)-1])
			c.applyFilter()
		}
		return m, nil
	case "ctrl+u":
		c.filter = ""
		c.applyFilter()
		return m, nil
	case "up", "ctrl+k":
		if c.sel > 0 {
			c.sel--
		}
		return m, nil
	case "down", "ctrl+j":
		if c.sel < len(c.view)-1 {
			c.sel++
		}
		return m, nil
	case "enter":
		if c.sel >= 0 && c.sel < len(c.view) {
			c.Dir = c.dirs[c.view[c.sel]].Path
			return m, tea.Quit
		}
		return m, nil
	default:
		if msg.Type == tea.KeyRunes || msg.Type == tea.KeySpace {
			c.filter += string(msg.Runes)
			c.applyFilter()
			return m, nil
		}
	}
	return m, nil
}

// sessionDisplay is one rendered line of the Sessions view: a host header, an
// unreachable note, or a selectable row indexed into sessionsView.
type sessionDisplay struct {
	header     bool
	label      string
	errMessage string
	view       int // index into sessionsView; -1 for non-selectable rows
}

func (m *dirModel) sessionDisplayRows() []sessionDisplay {
	display := make([]sessionDisplay, 0, len(m.sessions)*2)
	next := 0
	for gi, group := range m.sessions {
		present := next < len(m.sessionsView) && m.sessionsView[next].group == gi
		if !present && m.filter != "" {
			continue // Filtered-out groups disappear entirely.
		}
		display = append(display, sessionDisplay{header: true, label: group.Label, view: -1})
		if !group.Reachable {
			display = append(display, sessionDisplay{errMessage: group.Error, view: -1})
			continue
		}
		for next < len(m.sessionsView) && m.sessionsView[next].group == gi {
			display = append(display, sessionDisplay{view: next})
			next++
		}
	}
	return display
}

func (m *dirModel) viewSessions() string {
	width := m.width - 2
	blank := pickerLine("", width)
	lines := []string{pickerSearch(m.filter, width, "session")}
	if m.height >= 8 {
		// Compact palettes keep every line for results.
		lines = append(lines, pickerPills(1, width))
	}
	lines = append(lines, blank)
	maxRows := maxInt(m.height-len(lines)-2, 0)
	display := m.sessionDisplayRows()
	selected := -1
	for i, d := range display {
		if d.view == m.sel && m.sel >= 0 {
			selected = i
			break
		}
	}
	start := 0
	if selected >= 0 {
		start = maxInt(selected-maxRows+1, 0)
	}
	for n := 0; n < maxRows; n++ {
		i := start + n
		if i >= len(display) {
			if n == 0 {
				message := " No matching sessions"
				if !m.sessionsLoaded {
					message = " Loading sessions…"
				}
				lines = append(lines, pickerLine(pickerMuted.Render(message), width))
			} else {
				lines = append(lines, blank)
			}
			continue
		}
		d := display[i]
		switch {
		case d.header:
			lines = append(lines, pickerLine(pickerMuted.Render(" ▸ "+d.label), width))
		case d.errMessage != "":
			lines = append(lines, pickerLine(pickerMuted.Render(" unreachable"), width))
		case m.sessionsView[d.view].entry < 0:
			lines = append(lines, pickerNewSessionRow(d.view+1, width, d.view == m.sel))
		default:
			entry := m.sessions[m.sessionsView[d.view].group].Entries[m.sessionsView[d.view].entry]
			indicator := activityIndicator(entry.State, entry.Working, m.activityFrame)
			lines = append(lines, pickerGroupSessionRow(entry, d.view+1, width, d.view == m.sel, indicator))
		}
	}
	lines = append(lines, pickerRule(width))
	left := pickerText.Render("↵") + pickerMuted.Render(" switch")
	right := pickerText.Render("^x") + pickerMuted.Render(" close") + "  " + pickerText.Render("⇥") + pickerMuted.Render(" agents")
	footer := pickerFooter(left, right, left, width)
	if m.err != "" {
		footer = pickerLine(styErr.Render(m.err), width)
	}
	return strings.Join(append(lines, footer), "\n")
}

func (m *dirModel) viewCreateSession() string {
	width := m.width - 2
	c := m.createSession
	lines := []string{pickerSearch(c.filter, width, "directory")}
	if m.height >= 8 {
		lines = append(lines, pickerPills(1, width))
	}
	lines = append(lines, pickerLine(pickerMuted.Render("New session on "+c.Host), width))
	maxRows := maxInt(m.height-len(lines)-2, 0)
	start := maxInt(c.sel-maxRows+1, 0)
	for n := 0; n < maxRows; n++ {
		i := start + n
		if i >= len(c.view) {
			if n == 0 {
				message := " No matching directories"
				if c.loading {
					message = " Loading directories…"
				}
				lines = append(lines, pickerLine(pickerMuted.Render(message), width))
			} else {
				lines = append(lines, pickerLine("", width))
			}
			continue
		}
		item := c.dirs[c.view[i]]
		lines = append(lines, pickerDirectory(item.Path, width, i == c.sel))
	}
	lines = append(lines, pickerRule(width))
	footer := pickerFooter(pickerText.Render("↵")+pickerMuted.Render(" create"), pickerMuted.Render("esc back"), "↵ create · esc back", width)
	if m.err != "" {
		footer = pickerLine(styErr.Render(m.err), width)
	}
	return strings.Join(append(lines, footer), "\n")
}

// pickerGroupSessionRow renders one session row of a host group. Numbered
// positions cover selectable rows only; the activity glyph sits right-aligned.
func pickerGroupSessionRow(entry rex.SessionEntry, position, width int, selected bool, indicator string) string {
	style := pickerText
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
	if entry.Active {
		if selected {
			prefix += style.Render("● ")
		} else {
			prefix += pickerAccent.Render("● ")
		}
	}
	name := ansi.Truncate(entry.Label, maxInt(width-3-lipgloss.Width(prefix)-lipgloss.Width(indicator), 1), "…")
	return pickerRow(prefix+style.Bold(true).Render(name)+indicator, width, selected)
}

// pickerNewSessionRow renders a group's "+ New session" action row.
func pickerNewSessionRow(position, width int, selected bool) string {
	style := pickerText
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
	content := prefix + pickerAccent.Render("+ ") + pickerMuted.Render("New session")
	return pickerRow(content, width, selected)
}

// finishSessionsResult performs the session action chosen in the picker after
// the program exits: jump, close, or create+select. done reports whether the
// interaction ended with a session result.
func finishSessionsResult(ctx rex.Ctx, dm *dirModel) (code int, done bool) {
	if entry := dm.jumpSession; entry != nil {
		if err := rex.JumpOnHost(entry.Host, *entry, ctx.Client); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1, true
		}
		return 0, true
	}
	if entry := dm.closeSession; entry != nil {
		if err := rex.CloseSession(entry.Host, entry.ID); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1, true
		}
		return 0, true
	}
	if c := dm.createSession; c != nil && c.Dir != "" {
		sessionID, _, err := rex.CreateSessionOn(c.Host, c.Dir)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1, true
		}
		if err := rex.SelectOnHost(c.Host, sessionID, ctx.Client); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1, true
		}
		return 0, true
	}
	return 0, false
}
