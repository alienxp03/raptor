package picker

import (
	"fmt"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/dispatch"
	"github.com/alienxp03/raptor/internal/paths"
	"github.com/alienxp03/raptor/internal/rex"
	worktreepkg "github.com/alienxp03/raptor/internal/worktree"
)

// launcherRow is one selectable row of the Sessions launcher: a live session
// on any host, or a frecency directory that would start one. One verb covers
// both — Enter switches to the session or creates it — mirroring sesh's
// select-or-create model.
type launcherRow struct {
	session  *rex.SessionEntry  // set for session rows
	dir      *catalog.Directory // set for directory rows
	host     string             // display host label (real hostname, all rows)
	identity string             // action host: "" for local, remote label otherwise
	local    bool               // true when the row belongs to this machine
	pinned   bool               // local directory pins only
}

// launcherMatch is one filtered row plus the runes the query matched, so the
// view can highlight them inside the name the way sesh does.
type launcherMatch struct {
	index   int
	matches []int
}

func (r launcherRow) sessionState() string {
	if r.session != nil {
		return r.session.State
	}
	return ""
}

func (r launcherRow) sessionWorking() bool {
	if r.session != nil {
		return r.session.Working
	}
	return false
}

type launcherSessionsMsg struct {
	request uint64
	groups  []rex.HostGroup
}

type launcherDirsMsg struct {
	request uint64
	host    string
	items   []catalog.Directory
}

// captureMsg carries one live preview render. Stale requests are dropped by
// their counter, so slow remote captures never overwrite a newer selection.
type captureMsg struct {
	request uint64
	text    string
}

// previewTickMsg fires after the selection has held for the debounce window;
// only the newest tick may start a fetch.
type previewTickMsg struct {
	request uint64
}

// loadLauncherSessions fetches every host's live sessions in the background.
// Commands capture values only; all model changes happen in Update.
func (m *dirModel) loadLauncherSessions(force bool) tea.Cmd {
	if m.launcherSessionsLoading && !force {
		return nil
	}
	m.launcherSessionsRequest++
	m.launcherSessionsLoading = true
	request, session := m.launcherSessionsRequest, m.ctx.Session
	return func() tea.Msg {
		return launcherSessionsMsg{request: request, groups: rex.SessionGroups(session, nil)}
	}
}

// loadLauncherDirs fetches one host's frecency directories. Local hosts answer
// in milliseconds; remote hosts go over SSH and arrive later — the view paints
// sessions first and appends directories per host as they land.
func (m *dirModel) loadLauncherDirs(host string, force bool) tea.Cmd {
	if !force {
		if _, pending := m.launcherDirsPending[host]; pending {
			return nil
		}
	}
	if m.launcherDirsPending == nil {
		m.launcherDirsPending = map[string]uint64{}
	}
	m.launcherDirsRequest++
	request := m.launcherDirsRequest
	// Track the request per host: replies land out of order and only the
	// newest reply for each host is accepted.
	m.launcherDirsPending[host] = request
	return func() tea.Msg {
		items := catalog.DirectoriesOn(host, false)
		if host != rex.LocalHostLabel && host != "" {
			if agents, err := rex.AgentEntriesOn(host, ""); err == nil {
				catalog.ApplyDirectoryActivityOn(host, items, agents)
			}
		}
		return launcherDirsMsg{request: request, host: host, items: items}
	}
}

func (m *dirModel) loadAllLauncherDirs(force bool) tea.Cmd {
	cmds := []tea.Cmd{m.loadLauncherDirs(rex.LocalHostLabel, force)}
	for _, group := range m.sessions {
		if group.Reachable && !group.Local {
			cmds = append(cmds, m.loadLauncherDirs(group.Label, force))
		}
	}
	return tea.Batch(cmds...)
}

// applyLauncher recomposes the flat row list: live sessions first — the origin
// session pinned to the top — then each host's directories by frecency with
// pinned local directories floating first. Directories that already have a
// live session on the same host are skipped: selecting the session is the same
// action, and duplicate rows only add noise.
func (m *dirModel) applyLauncher() {
	selection := m.sel
	defer func() {
		if m.viewMode != 0 {
			m.sel = selection
		}
	}()
	selected := m.selectedLauncher()
	rows := m.composeLauncher()
	m.launcher = rows
	m.projectActivity(m.activityEntries)
	for i := range m.launcher {
		r := &m.launcher[i]
		if r.dir != nil && r.identity != "" {
			if agents, ok := m.activityRemote[r.identity]; ok {
				items := []catalog.Directory{*r.dir}
				catalog.ApplyDirectoryActivityOn(r.identity, items, agents)
				r.dir.State, r.dir.Working = items[0].State, items[0].Working
			}
		}
	}
	m.filterLauncher()
	if m.launcherSelectionManual && selected != nil {
		for position, match := range m.launcherView {
			fresh := m.launcher[match.index]
			if fresh.identity == selected.identity && launcherRowID(fresh) == launcherRowID(*selected) {
				m.sel = position
				return
			}
		}
	}
	m.selectPreferredLauncher()
}

func launcherRowID(r launcherRow) string {
	if r.session != nil {
		return r.session.ID
	}
	if r.dir != nil {
		return r.dir.Path
	}
	return ""
}

func (m *dirModel) selectPreferredLauncher() {
	m.launcherSelectionManual = false
	items := make([]catalog.LauncherItem, 0, len(m.launcherView))
	for _, match := range m.launcherView {
		r := m.launcher[match.index]
		item := catalog.LauncherItem{ID: launcherRowID(r), Kind: "dir"}
		if r.session != nil {
			item.Kind, item.Active = "session", r.session.Active
		}
		items = append(items, item)
	}
	id := catalog.PreferredLauncherID(items, m.filter)
	m.sel = 0
	for i, item := range items {
		if item.ID == id {
			m.sel = i
			break
		}
	}
}

func (m *dirModel) refilterLauncher() {
	m.launcherSelectionManual = false
	m.filterLauncher()
	m.selectPreferredLauncher()
}

// Filtering uses the materialized rows only. Typing must not recompose the
// catalog or resolve filesystem paths again.
func (m *dirModel) filterLauncher() {
	rows := m.launcher
	texts := launcherTexts(rows)
	if m.filter == "" {
		m.launcherView = make([]launcherMatch, len(rows))
		for i := range rows {
			m.launcherView[i] = launcherMatch{index: i}
		}
	} else {
		names := make([]string, len(rows))
		for i, row := range rows {
			if row.session != nil {
				names[i] = catalog.LauncherMatchName(row.session.Label, "")
			} else if row.dir != nil {
				names[i] = catalog.LauncherMatchName(row.dir.Label, row.dir.Path)
			}
		}
		ranked := catalog.RankLauncherMatches(m.filter, texts, names)
		m.launcherView = make([]launcherMatch, 0, len(ranked))
		for _, match := range ranked {
			m.launcherView = append(m.launcherView, launcherMatch{index: match.Index, matches: match.MatchedIndexes})
		}
	}
	if m.sel >= len(m.launcherView) {
		m.sel = len(m.launcherView) - 1
	}
	if m.sel < 0 {
		m.sel = 0
	}
}

func launcherTexts(rows []launcherRow) []string {
	texts := make([]string, len(rows))
	for i, r := range rows {
		texts[i] = launcherRowText(r)
	}
	return texts
}

func launcherRowText(r launcherRow) string {
	if r.session != nil {
		return r.session.Label + " " + r.host
	}
	if r.dir != nil {
		return r.dir.Label + " " + paths.HomeRelative(r.dir.Path) + " " + r.host
	}
	return ""
}

func (m *dirModel) composeLauncher() []launcherRow {
	rows := make([]launcherRow, 0, 16)
	// Live sessions: the origin session leads, then each host's sessions in
	// sidebar order (local first, remote hosts in the server's host order).
	origin := -1
	for _, group := range m.sessions {
		if !group.Reachable {
			continue
		}
		display := group.Label
		if group.Local {
			display = rex.LocalHostname()
		}
		for ei, entry := range group.Entries {
			if entry.Active {
				origin = len(rows)
			}
			rows = append(rows, launcherRow{session: &group.Entries[ei], host: display, identity: group.Label, local: group.Local})
		}
	}
	if len(m.sessionRecency) != 0 {
		rank := func(row launcherRow) int {
			host := row.identity
			if row.local {
				host = ""
			}
			return m.sessionRecency.Rank(host, row.session.SessionID)
		}
		sort.SliceStable(rows, func(i, j int) bool { return rank(rows[i]) < rank(rows[j]) })
		origin = -1
		for i, row := range rows {
			if row.session.Active {
				origin = i
				break
			}
		}
	}
	if origin > 0 {
		active := rows[origin]
		copy(rows[1:origin+1], rows[0:origin])
		rows[0] = active
	}
	// Directories per host, skipping names that already have a live session.
	taken := map[string]bool{}
	for _, group := range m.sessions {
		if group.Reachable {
			for _, entry := range group.Entries {
				taken[group.Label+"\x00"+entry.Label] = true
			}
		}
	}
	for _, host := range m.hostOrder {
		items, loaded := m.hostDirs[host]
		if !loaded {
			continue
		}
		local := host == rex.LocalHostLabel
		pinned := make([]catalog.Directory, 0, 2)
		rest := make([]catalog.Directory, 0, len(items))
		for _, item := range items {
			if taken[host+"\x00"+item.Label] {
				continue
			}
			if local && m.pinned[item.Path] {
				pinned = append(pinned, item)
			} else {
				rest = append(rest, item)
			}
		}
		display := host
		if local {
			display = rex.LocalHostname()
		}
		for _, item := range append(pinned, rest...) {
			dir := item
			rows = append(rows, launcherRow{dir: &dir, host: display, identity: host, local: local, pinned: local && m.pinned[item.Path]})
		}
	}
	return rows
}

func (m *dirModel) acceptLauncherSessions(msg launcherSessionsMsg) {
	if msg.request != m.launcherSessionsRequest || !m.launcherSessionsLoading {
		return
	}
	activeSelection := m.sel
	defer func() {
		if m.viewMode != 0 {
			m.sel = activeSelection
		}
	}()
	var selected *launcherRow
	if m.viewMode == 0 && m.launcherSelectionManual {
		selected = m.selectedLauncher()
	}
	m.launcherSessionsLoading = false
	m.launcherLoaded = true
	m.sessions = msg.groups
	seen := map[string]bool{rex.LocalHostLabel: true}
	m.hostOrder = []string{rex.LocalHostLabel}
	for _, group := range msg.groups {
		if !group.Local {
			m.hostOrder = append(m.hostOrder, group.Label)
			seen[group.Label] = true
		}
	}
	// Directories can land before the sessions response; keep their hosts.
	for host := range m.hostDirs {
		if !seen[host] {
			m.hostOrder = append(m.hostOrder, host)
			seen[host] = true
		}
	}
	m.applyLauncher()
	if selected != nil {
		for position, match := range m.launcherView {
			fresh := m.launcher[match.index]
			if fresh.identity != selected.identity {
				continue
			}
			if (fresh.session != nil && selected.session != nil && fresh.session.Kind == selected.session.Kind && fresh.session.ID == selected.session.ID) ||
				(fresh.dir != nil && selected.dir != nil && fresh.dir.Path == selected.dir.Path) {
				m.sel = position
				break
			}
		}
	}
}

func (m *dirModel) acceptLauncherDirs(msg launcherDirsMsg) {
	if m.launcherDirsPending[msg.host] != msg.request {
		return
	}
	delete(m.launcherDirsPending, msg.host)
	known := false
	for _, listed := range m.hostOrder {
		if listed == msg.host {
			known = true
			break
		}
	}
	if !known {
		m.hostOrder = append(m.hostOrder, msg.host)
	}
	m.hostDirs[msg.host] = msg.items
	m.applyLauncher()
}

func (m *dirModel) selectedLauncher() *launcherRow {
	if m.sel < 0 || m.sel >= len(m.launcherView) {
		return nil
	}
	r := m.launcher[m.launcherView[m.sel].index]
	return &r
}

func (m *dirModel) updateLauncher(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	if m.splitMode {
		switch msg.String() {
		case "ctrl+c":
			return m, tea.Quit
		case "esc", "ctrl+p":
			m.splitMode = false
			return m, nil
		}
		target := map[string]string{
			"j": "pane_below", "down": "pane_below",
			"l": "pane_right", "right": "pane_right",
		}[msg.String()]
		if target != "" {
			if r := m.selectedLauncher(); r != nil && r.dir != nil && r.local {
				m.target, m.picked = target, &row{kind: "dir", label: r.dir.Label, path: r.dir.Path}
				return m, tea.Quit
			}
		}
		return m, nil
	}
	switch msg.String() {
	case "ctrl+c", "esc":
		return m, tea.Quit
	case "backspace":
		if m.filter != "" {
			r := []rune(m.filter)
			m.filter = string(r[:len(r)-1])
			m.refilterLauncher()
		}
		return m, nil
	case "ctrl+u":
		m.filter = ""
		m.refilterLauncher()
		return m, nil
	case "up", "ctrl+k":
		m.launcherSelectionManual = true
		if m.sel > 0 {
			m.sel--
		}
		return m, nil
	case "down", "ctrl+j":
		m.launcherSelectionManual = true
		if m.sel < len(m.launcherView)-1 {
			m.sel++
		}
		return m, nil
	case "alt+1", "alt+2", "alt+3", "alt+4", "alt+5", "alt+6", "alt+7", "alt+8", "alt+9":
		number := int(msg.String()[len(msg.String())-1] - '0')
		if number >= 1 && number <= len(m.launcherView) {
			m.sel = number - 1
			return m.activateLauncher()
		}
		return m, nil
	case "ctrl+o":
		targets := m.cfg
		targets.Targets = targets.AvailableTargets(m.ctx.Block != "")
		m.target = dispatch.NextTarget(targets, m.target, true)
		return m, nil
	case "ctrl+x":
		r := m.selectedLauncher()
		if r == nil || r.session == nil {
			return m, nil
		}
		entry := *r.session
		if entry.Host == rex.LocalHostLabel && entry.ID == m.ctx.Session {
			// The backend guards API clients; the TUI repeats the check.
			m.err = "cannot close this session"
			return m, nil
		}
		m.closeSession = &entry
		return m, tea.Quit
	case "ctrl+g":
		r := m.selectedLauncher()
		if r == nil || r.dir == nil || !r.local {
			return m, nil
		}
		pinned, err := config.TogglePin(r.dir.Path)
		if err != nil {
			m.err = err.Error()
			return m, nil
		}
		m.loadPins()
		m.applyLauncher()
		if pinned {
			for position, match := range m.launcherView {
				if row := m.launcher[match.index]; row.dir != nil && row.dir.Path == r.dir.Path {
					m.sel = position
					break
				}
			}
		}
		return m, nil
	case "ctrl+p":
		r := m.selectedLauncher()
		if r == nil || r.dir == nil || !r.local {
			return m, nil
		}
		if m.ctx.Block == "" {
			m.err = "no block context"
			return m, nil
		}
		m.splitMode = true
		return m, nil
	case "ctrl+t":
		return m, nil
	case "ctrl+n", "f2":
		r := m.selectedLauncher()
		if r == nil || r.dir == nil {
			return m, nil
		}
		if worktreepkg.IsGitRepo(r.dir.Path) {
			m.next = "wt-create"
			m.nextRepo = worktreepkg.RepoRoot(r.dir.Path)
			return m, tea.Quit
		}
		m.err = "not a git repo"
		return m, nil
	case "enter":
		return m.activateLauncher()
	default:
		if msg.Type == tea.KeyRunes || msg.Type == tea.KeySpace {
			m.filter += string(msg.Runes)
			m.refilterLauncher()
			return m, nil
		}
	}
	return m, nil
}

// activateLauncher is the single verb: switch to a live session, or select-or-
// create one at the chosen directory. Local directories can also honor an
// overridden open target (tab, pane, here) chosen with ctrl+o.
func (m *dirModel) activateLauncher() (tea.Model, tea.Cmd) {
	r := m.selectedLauncher()
	if r == nil {
		return m, nil
	}
	if m.launcherMode {
		// The experimental launcher keeps its path → action preview flow.
		if r.dir != nil {
			m.openLauncherActions(r.dir.Path)
		}
		return m, nil
	}
	if r.session != nil {
		entry := *r.session
		m.jumpSession = &entry
		return m, tea.Quit
	}
	if !r.local || m.target == "session" {
		m.launchDir = &dirLaunch{Host: r.identity, Path: r.dir.Path}
		return m, tea.Quit
	}
	m.picked = &row{kind: "dir", label: r.dir.Label, path: r.dir.Path}
	return m, tea.Quit
}

// previewDebounce is how long a selection must hold before its capture starts;
// holding a movement key would otherwise shell out to rex for every row passed.
const previewDebounce = 60 * time.Millisecond

func (m *dirModel) schedulePreview() tea.Cmd {
	if m.width < previewMinWidth {
		m.previewRequest++
		m.previewKey = ""
		return nil
	}
	r := m.selectedLauncher()
	if r == nil || r.session == nil {
		if m.previewKey != "" || m.previewText != "" {
			m.previewRequest++
			m.previewKey = ""
			m.previewText = ""
		}
		return nil
	}
	key := fmt.Sprintf("%d\x00%s\x00%s", m.width, r.host, r.session.ID)
	if key == m.previewKey || m.previewPending {
		return nil // Same row, same geometry: the capture is already fresh.
	}
	m.previewKey = key
	m.previewRequest++
	m.previewPending = true
	request := m.previewRequest
	return tea.Tick(previewDebounce, func(time.Time) tea.Msg {
		return previewTickMsg{request: request}
	})
}

func (m *dirModel) fetchPreview(request uint64) tea.Cmd {
	r := m.selectedLauncher()
	if r == nil || r.session == nil {
		return nil
	}
	entry := *r.session
	return func() tea.Msg {
		out, err := rex.RunOnBounded(entry.Host, 2, "capture", "-s", entry.ID, "--trim")
		if err != nil {
			return captureMsg{request: request, text: ""}
		}
		return captureMsg{request: request, text: out}
	}
}

func (m *dirModel) acceptPreviewTick(msg previewTickMsg) tea.Cmd {
	if msg.request != m.previewRequest {
		return nil
	}
	return m.fetchPreview(msg.request)
}

func (m *dirModel) acceptCapture(msg captureMsg) {
	if msg.request != m.previewRequest {
		return
	}
	m.previewPending = false
	m.previewText = msg.text
}

// previewMinWidth is the narrowest full width that shows the live preview
// column; narrower palettes (iPhones) render rows only.
const previewMinWidth = 100

// sessionRow is one rendered line: a selectable row index (-1 for filler) or
// the rule/footer markers.
type sessionRow struct{ view int }

// Launcher geometry, sesh's split rules: the list caps at 60 columns beside
// the preview, never drops below 40, and the preview takes the rest.
const (
	maxListWidth  = 60
	minListWidth  = 40
	previewShare  = 60 // percent of the width the preview is guaranteed
	previewGutter = 1  // the divider column
)

// pointerGutter is the two-cell column before every row: the highlight marker
// on the selected row, blank elsewhere. Names stay in one column.
const pointerGutter = 2

func padding(n int) string {
	if n <= 0 {
		return ""
	}
	return strings.Repeat(" ", n)
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// previewCols is how many columns the preview pane occupies, divider included.
func previewCols(width int) int {
	if width < previewMinWidth {
		return 0
	}
	cols := width * previewShare / 100
	if rest := width - maxListWidth; rest > cols {
		cols = rest
	}
	if limit := width - minListWidth; cols > limit {
		cols = limit
	}
	if cols <= previewGutter {
		return 0
	}
	return cols
}

func listWidth(width int) int {
	w := width - previewCols(width)
	if previewCols(width) > 0 && w > maxListWidth {
		w = maxListWidth
	}
	if w < 1 {
		w = 1
	}
	return w
}

// viewLauncher renders the sesh-style launcher: a bare filter line, a pointer
// list with green match highlighting, a faint group rule, and — on wide
// terminals — a divider plus live preview column. No boxes, no footer rule.
func (m *dirModel) viewLauncher() string {
	cols := previewCols(m.width)
	width := listWidth(m.width)
	if cols == 0 {
		// pickerLine chrome (leading space + trailing pad) adds two columns.
		width = m.width - 2
	}
	// The faint rule between live sessions and directories only means
	// something while the compose order is showing; a query reorders rows and
	// the boundary stops being a place.
	ruleAt := -1
	if m.filter == "" {
		for i, match := range m.launcherView {
			if i > 0 && m.launcher[match.index].dir != nil {
				ruleAt = i
				break
			}
		}
	}

	visible := m.height - 3 // filter line, blank line, faint footer line
	if visible < 1 {
		visible = 5
	}

	var b strings.Builder
	// Filter line: prompt, typed query or faint placeholder, cursor.
	b.WriteString(padding(pointerGutter))
	b.WriteString(pickerAccent.Render("❯ "))
	b.WriteString(m.launcherFilterView(width - pointerGutter - 2))
	b.WriteString("\n")
	if m.err != "" {
		b.WriteString(ansi.Truncate(padding(pointerGutter)+styErr.Render(m.err), m.width, "") + "\n")
	} else if !m.launcherLoaded {
		b.WriteString(ansi.Truncate(lipgloss.NewStyle().Faint(true).Render(padding(pointerGutter)+"Loading sessions..."), m.width, "") + "\n")
	} else {
		b.WriteString("\n")
	}

	start := 0
	if m.sel >= 0 && len(m.launcherView) > 0 {
		start = minInt(maxInt(m.sel-visible+1, 0), maxInt(len(m.launcherView)-1, 0))
	}
	end := minInt(start+visible, len(m.launcherView))

	pointer := pickerAccent.Bold(true).Render("❯" + padding(pointerGutter-1))
	blank := padding(pointerGutter)
	matchStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("2")).Bold(true)

	drawn := 0
	for i := start; i < end && drawn < visible; i++ {
		if i == ruleAt {
			b.WriteString(padding(pointerGutter) + pickerRail.Render(strings.Repeat("─", maxInt(width-pointerGutter, 1))) + "\n")
			drawn++
			if drawn == visible {
				break
			}
		}
		match := m.launcherView[i]
		b.WriteString(launcherRowLine(m.launcher[match.index], match, width, i == m.sel, pointer, blank, matchStyle))
		b.WriteString("\n")
		drawn++
	}
	if drawn == 0 && drawn < visible && m.launcherLoaded && m.err == "" {
		b.WriteString(lipgloss.NewStyle().Faint(true).Render(padding(pointerGutter)+"No matching sessions or directories") + "\n")
		drawn++
	}
	for ; drawn < visible; drawn++ {
		b.WriteString("\n")
	}

	list := b.String()

	if cols == 0 {
		return strings.TrimSuffix(list, "\n") + "\n" + m.launcherFooter(width)
	}
	preview := m.viewPreview(cols, visible)
	joined := joinPreview(list, preview, cols)
	return joined + "\n" + m.launcherFooter(m.width)
}

// launcherFilterView renders the typed query or the faint placeholder, with
// the cursor at the end of whatever is showing.
func (m *dirModel) launcherFilterView(width int) string {
	if width <= 0 {
		return ""
	}
	cursor := styTarget.Render("│")
	if m.filter == "" {
		placeholder := lipgloss.NewStyle().Faint(true).Render("Filter sessions and directories...")
		return ansi.Truncate(placeholder, width-1, "") + cursor
	}
	content := pickerText.Render(m.filter) + cursor
	if lipgloss.Width(content) > width {
		content = ansi.TruncateLeft(content, lipgloss.Width(content)-width+1, "")
	}
	return content
}

func (m *dirModel) launcherFooter(width int) string {
	r := m.selectedLauncher()
	left := pickerText.Render("↵") + pickerMuted.Render(" switch")
	if r != nil && r.dir != nil {
		target := pickerAccent.Bold(true).Render(dispatch.TargetLabel(m.target))
		left = pickerMuted.Render("Open as: ") + target
		if lipgloss.Width(left)+3 <= width {
			left += pickerMuted.Render(" ^o")
		}
		if lipgloss.Width(left) > width {
			left = target
		}
	}
	splitHint := pickerText.Render("^p") + pickerMuted.Render(" split")
	right := pickerText.Render("^x") + pickerMuted.Render(" close") + "  " + pickerText.Render("^n") + pickerMuted.Render(" new worktree") + "  " + splitHint
	if width-lipgloss.Width(left)-lipgloss.Width(right) < 2 {
		right = splitHint
	}
	if width-lipgloss.Width(left)-lipgloss.Width(right) < 2 {
		right = ""
	}
	if m.launcherMode {
		return pickerMuted.Render(ansi.Truncate(ansi.Strip("enter Actions · esc Back/close"), width, ""))
	}
	if m.splitMode {
		directions := pickerAccent.Bold(true).Render("j↓ l→")
		return pickerMuted.Render(ansi.Truncate(ansi.Strip("Split: "+directions+" · esc cancel"), width, ""))
	}
	gap := width - lipgloss.Width(left) - lipgloss.Width(right)
	if gap < 0 {
		gap = 0
	}
	line := ansi.Strip(left) + padding(gap) + ansi.Strip(right)
	if lipgloss.Width(line) > width {
		line = ansi.Truncate(line, width, "")
	}
	return pickerMuted.Render(line)
}

// viewPreview renders the right column for the selected row: a live capture
// for sessions, the path and create context for directories. The first line
// is the divider column so both halves span the same height.
func (m *dirModel) viewPreview(cols int, rows int) []string {
	div := pickerRail.Render("│")
	lines := []string{div}
	inner := cols - previewGutter - 1
	if rows > 0 {
		rows--
	}
	if inner < 1 {
		inner = 1
	}
	r := m.selectedLauncher()
	if r != nil && r.dir != nil {
		body := []string{
			pickerMuted.Render("session: ") + pickerText.Render(r.dir.Label),
			pickerMuted.Render("host:    ") + pickerText.Render(r.host),
			pickerMuted.Render("↵ open · ^o target · ^n new worktree"),
		}
		for _, line := range body {
			if len(lines)-1 >= rows {
				break
			}
			lines = append(lines, div+padding(previewGutter)+pickerTail(line, inner))
		}
	} else if r != nil {
		header := "● " + r.session.Label
		if !r.local {
			header += " @" + r.host
		}
		lines = append(lines, div+padding(previewGutter)+pickerAccent.Render(pickerTail(header, inner)))
		text := m.previewText
		if m.previewPending {
			text = "" // Keep the last capture until the new one lands.
		}
		for _, line := range previewLines(text, inner, rows-1) {
			lines = append(lines, div+padding(previewGutter)+pickerMuted.Render(line))
		}
	}
	for len(lines) < rows+1 {
		lines = append(lines, div)
	}
	return lines
}

// previewLines keeps the tail of a capture: the screen, not the scrollback.
func previewLines(text string, width, count int) []string {
	if strings.TrimSpace(text) == "" {
		return nil
	}
	wrapped := strings.Split(ansi.Hardwrap(strings.TrimRight(text, "\n"), width, true), "\n")
	if len(wrapped) > count {
		wrapped = wrapped[len(wrapped)-count:]
	}
	return wrapped
}

// joinPreview pads the list to its width and appends the preview column.
func joinPreview(list string, preview []string, cols int) string {
	lines := strings.Split(list, "\n")
	for i := range lines {
		line := ansi.Truncate(lines[i], cols-previewGutter, "")
		lines[i] = line + padding(cols-previewGutter-lipgloss.Width(line)) + " "
		if i < len(preview) {
			lines[i] += preview[i]
		}
	}
	for i := len(lines); i < len(preview); i++ {
		lines = append(lines, padding(cols-previewGutter)+" "+preview[i])
	}
	return strings.Join(lines, "\n")
}

// launcherRowLine renders one flat launcher row: pointer gutter, green match
// highlighting inside the displayed text, faint trailing metadata. Sessions
// lead with the active dot; directories show their home-relative path with
// the pin star; remote rows carry a faint @host badge.
func launcherRowLine(r launcherRow, match launcherMatch, width int, selected bool, pointer, blank string, matchStyle lipgloss.Style) string {
	prefix := blank
	if selected {
		prefix = pointer
	}
	// Remote rows carry the only tag: the eye flags what's elsewhere.
	badge := ""
	if !r.local {
		badge = pickerMuted.Render(" · " + r.host)
	}
	indicator := activityIndicator(r.sessionState(), r.sessionWorking(), 0)

	var highlight func(text string, offset int) string
	highlight = func(text string, offset int) string {
		runes := []rune(text)
		inPath := false
		var out strings.Builder
		for i, char := range runes {
			if i == 0 && r.dir != nil {
				// Directory display paths carry the label twice (as the tail);
				// matches in the label region also light the path's copy.
				inPath = len(runes) > len(r.dir.Label)
			}
			_ = inPath
			hit := false
			for _, idx := range match.matches {
				if idx == offset+i || (r.dir != nil && idx < len(r.dir.Label) && offset+i == len(runes)-len(r.dir.Label)+idx) {
					hit = true
					break
				}
			}
			if hit {
				out.WriteString(matchStyle.Render(string(char)))
			} else {
				out.WriteString(string(char))
			}
		}
		return out.String()
	}

	var content string
	if r.session != nil {
		dot := ""
		if r.session.Active {
			dot = pickerAccent.Render("● ")
		}
		name := r.session.Label
		content = prefix + dot + highlight(name, 0) + indicator + badge
	} else {
		display := paths.HomeRelative(r.dir.Path)
		star := ""
		if r.pinned {
			star = pickerAccent.Render("★ ")
		}
		content = prefix + star + highlight(display, len(r.dir.Label)+1) + indicator + badge
	}
	if lipgloss.Width(content) > width {
		content = ansi.Truncate(content, width, "")
	}
	return pickerRow(content, width, selected)
}

// finishSessionsResult performs the launcher action chosen in the picker after
// the program exits: jump, close, or select-or-create at a directory. done
// reports whether the interaction ended with a session result.
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
	if launch := dm.launchDir; launch != nil {
		sessionID, _, err := rex.CreateSessionOn(launch.Host, launch.Path)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1, true
		}
		if err := rex.SelectOnHost(launch.Host, sessionID, ctx.Client); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1, true
		}
		return 0, true
	}
	return 0, false
}
