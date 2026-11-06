package picker

import (
	"fmt"
	"os"
	"strings"

	"github.com/charmbracelet/x/ansi"

	"github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/dispatch"
	"github.com/alienxp03/raptor/internal/rex"
	worktreepkg "github.com/alienxp03/raptor/internal/worktree"
)

var (
	styTitle    = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("12"))
	styDim      = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	stySel      = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("15"))
	stySession  = lipgloss.NewStyle().Foreground(lipgloss.Color("10")) // green
	styBranch   = lipgloss.NewStyle().Foreground(lipgloss.Color("13")) // magenta
	styGhost    = lipgloss.NewStyle().Foreground(lipgloss.Color("11")) // yellow
	styDirty    = lipgloss.NewStyle().Foreground(lipgloss.Color("9"))  // red
	styErr      = lipgloss.NewStyle().Foreground(lipgloss.Color("9"))
	styTarget   = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("14")) // cyan
	styBorder   = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	styPreviewB = lipgloss.NewStyle().Foreground(lipgloss.Color("4"))
)

// row is one list entry in the dir picker.
type row struct {
	kind    string // "dir"
	label   string // paths.Basename
	path    string // full directory path
	state   string
	working bool
}

type dirModel struct {
	cfg                 config.Config
	ctx                 rex.Ctx
	viewMode            int   // 0 = repos, 2 = agents (1 is reserved)
	rows                []row // full set
	view                []int // indices into rows after filtering (repos view)
	pinned              map[string]bool
	filter              string
	sel                 int
	target              string
	splitMode           bool
	launcher            bool
	actionMenu          bool
	actionSel           int
	actions             []launcherAction
	reposLoading        bool
	reposRequest        uint64
	agents              []rex.AgentEntry
	agentsView          []int
	agentsLoaded        bool
	agentsLoading       bool
	agentsRequest       uint64
	agentSnapshot       bool
	pendingAgents       []rex.AgentEntry
	agentGroups         map[agentIdentity]int
	activityFrame       int
	activityTickPending bool
	activityTickID      uint64
	activityStopping    bool
	viewStates          [3]dirViewState
	err                 string
	width               int
	height              int
	// result of the interaction, read after the program exits
	picked      *row            // non-nil when a directory was chosen
	jumpedAgent *rex.AgentEntry // separate result: jump to the exact agent pane
	next        string          // "wt" or "wt-create" with a repo path in nextRepo
	nextRepo    string
}

// Scroll position is derived from sel and the current viewport height.
type dirViewState struct {
	filter string
	sel    int
}

type reposLoadedMsg struct {
	request uint64
	rows    []row
}

type previewMsg struct {
	For  string
	text string
}

func loadDirRows(ctx rex.Ctx) []row {
	var rows []row
	for _, d := range catalog.Directories(false) {
		rows = append(rows, row{kind: "dir", label: d.Label, path: d.Path})
	}
	return rows
}

func RunDirs(ctx rex.Ctx, cfg config.Config) int {
	return runDirs(ctx, cfg, false, 0)
}

// RunAgents opens the shared directory picker directly in its Agents view.
func RunAgents(ctx rex.Ctx, cfg config.Config) int {
	return runDirs(ctx, cfg, false, 2)
}

// RunLauncher previews a path's actions before dispatching. Normal pickers stay unchanged.
func RunLauncher(ctx rex.Ctx, cfg config.Config) int {
	return runDirs(ctx, cfg, true, 0)
}

func newDirModel(ctx rex.Ctx, cfg config.Config, launcher bool, view int) *dirModel {
	if view != 2 {
		view = 0
	}
	m := &dirModel{cfg: cfg, ctx: ctx, rows: loadDirRows(ctx), target: cfg.Enter, launcher: launcher, viewMode: view}
	m.loadPins()
	m.applyCurrentFilter()
	return m
}

func runDirs(ctx rex.Ctx, cfg config.Config, launcher bool, view int) int {
	m := newDirModel(ctx, cfg, launcher, view)
	var dm *dirModel
	for {
		final, err := tea.NewProgram(m, tea.WithAltScreen()).Run()
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		dm = final.(*dirModel)
		if dm.jumpedAgent != nil {
			if err := rex.JumpAgent(*dm.jumpedAgent, ctx.Client); err != nil {
				fmt.Fprintln(os.Stderr, err)
				return 1
			}
			return 0
		}
		if dm.next != "wt" && dm.next != "wt-create" {
			break
		}
		flowCfg := cfg
		flowCfg.Enter = dm.target
		code := runWorktreePicker(ctx, flowCfg, dm.nextRepo, true, dm.next == "wt-create")
		if !dm.resumeWorktreeFlow(code) {
			return code
		}
		m = dm
	}
	if dm.picked == nil {
		return 0
	}
	r := dm.picked
	if err := dispatch.Dispatch(dm.target, r.path, ctx, cfg); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return 0
}

// Resume the same picker rather than creating another terminal layer.
func (m *dirModel) resumeWorktreeFlow(code int) bool {
	if code != returnToDirectories && code != returnToAgents {
		return false
	}
	m.next, m.nextRepo = "", ""
	m.actionMenu = false
	if code == returnToAgents {
		// Init restarts the pending fetch after the nested picker exits.
		_ = m.switchView(2)
	}
	return true
}

func (m *dirModel) Init() tea.Cmd {
	// A worktree flow can stop this program before its refresh returns.
	// Restart pending commands when the same picker resumes.
	m.activityStopping = false
	m.activityTickPending = false
	m.activityTickID++
	commands := []tea.Cmd{m.ctx.TitleCommand(), m.scheduleActivityTick()}
	if m.viewMode != 2 && !m.agentsLoading {
		commands = append(commands, activityCommand(m.ctx.Session))
	}
	if m.agentsLoading || (m.viewMode == 2 && !m.agentsLoaded) {
		commands = append(commands, m.loadAgents(true))
	}
	if m.reposLoading {
		m.reposLoading = false
		commands = append(commands, m.refreshRepos())
	}
	return tea.Batch(commands...)
}
func (m *dirModel) applyFilter() {
	items := make([]catalog.Directory, len(m.rows))
	for i, r := range m.rows {
		items[i] = catalog.Directory{Label: r.label, Path: r.path, Pinned: m.pinned[r.path]}
	}
	m.view = catalog.FilterDirectories(items, m.filter)
	if m.sel >= len(m.view) {
		m.sel = len(m.view) - 1
	}
	if m.sel < 0 {
		m.sel = 0
	}
}

// loadPins marks pinned directories so rows can show the pin glyph. The
// pinned-first order comes from the shared catalog helper at filter time.
func (m *dirModel) loadPins() {
	m.pinned = map[string]bool{}
	for _, item := range catalog.ApplyPins(m.dirItems()) {
		m.pinned[item.Path] = item.Pinned
	}
}

func (m *dirModel) dirItems() []catalog.Directory {
	items := make([]catalog.Directory, len(m.rows))
	for i, r := range m.rows {
		items[i] = catalog.Directory{Label: r.label, Path: r.path}
	}
	return items
}

// Commands capture values only. All model changes happen in Update.
func (m *dirModel) refreshRepos() tea.Cmd {
	if m.reposLoading {
		return nil
	}
	m.reposRequest++
	m.reposLoading = true
	request, ctx := m.reposRequest, m.ctx
	return func() tea.Msg {
		rows := loadDirRows(ctx)
		if agents, err := rex.AgentEntries(ctx.Session); err == nil {
			applyRowActivity(rows, agents)
		}
		return reposLoadedMsg{request: request, rows: rows}
	}
}

// Refresh the destination view without changing the active view's state.
// Keep the selected identity when entries change order.
func (m *dirModel) acceptRepos(msg reposLoadedMsg) {
	if msg.request != m.reposRequest || !m.reposLoading {
		return
	}
	m.reposLoading = false
	active := dirViewState{m.filter, m.sel}
	if m.viewMode != 0 {
		m.filter, m.sel = m.viewStates[0].filter, m.viewStates[0].sel
	}
	path := ""
	if r := m.selected(); r != nil {
		path = r.path
	}
	m.rows = msg.rows
	m.loadPins()
	m.applyFilter()
	for position, index := range m.view {
		if m.rows[index].path == path {
			m.sel = position
			break
		}
	}
	m.viewStates[0] = dirViewState{m.filter, m.sel}
	if m.viewMode != 0 {
		m.filter, m.sel = active.filter, active.sel
	}
}

func (m *dirModel) applyCurrentFilter() {
	if m.viewMode == 2 {
		m.applyAgentFilter()
	} else {
		m.applyFilter()
	}
}

func (m *dirModel) selected() *row {
	if len(m.view) == 0 {
		return nil
	}
	if m.sel >= len(m.view) {
		m.sel = len(m.view) - 1
	}
	if m.sel < 0 {
		return nil
	}
	return &m.rows[m.view[m.sel]]
}

func (m *dirModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	stopping := false
	if key, ok := msg.(tea.KeyMsg); ok {
		stopping = key.String() == "ctrl+c" || (key.String() == "esc" && !m.splitMode && !m.actionMenu)
	}
	model, cmd := m.update(msg)
	if stopping || m.picked != nil || m.jumpedAgent != nil || m.next != "" {
		m.activityStopping = true
	}
	switch msg.(type) {
	case activityTickMsg, activityLoadedMsg, agentsLoadedMsg, reposLoadedMsg:
		if tick := m.scheduleActivityTick(); tick != nil {
			return model, tea.Batch(cmd, tick)
		}
	}
	return model, cmd
}

func (m *dirModel) update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case activityTickMsg:
		if msg.id == m.activityTickID {
			m.activityTickPending = false
			m.activityFrame = (m.activityFrame + 1) % 4
		}
		return m, nil
	case activityLoadedMsg:
		if msg.err == nil {
			m.projectActivity(msg.entries)
		}
		return m, nil
	case agentsLoadedMsg:
		m.acceptAgents(msg)
		return m, nil
	case reposLoadedMsg:
		m.acceptRepos(msg)
		return m, nil
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		return m, nil
	case tea.KeyMsg:
		m.err = ""
		if m.actionMenu {
			return m.updateLauncherActions(msg)
		}
		if msg.String() == "ctrl+a" {
			if m.viewMode == 2 {
				return m, nil
			}
			return m, m.switchView(2)
		}
		if !m.splitMode && (msg.String() == "tab" || msg.String() == "shift+tab") {
			if m.viewMode == 2 {
				return m, m.switchView(0)
			}
			return m, m.switchView(2)
		}
		if m.viewMode == 2 {
			return m.updateAgents(msg)
		}
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
				if r := m.selected(); r != nil && r.kind == "dir" {
					m.target, m.picked = target, r
					return m, tea.Quit
				}
			}
			return m, nil
		}
		switch msg.String() {
		case "ctrl+c":
			return m, tea.Quit
		case "esc":
			return m, tea.Quit
		case "backspace":
			if m.filter != "" {
				r := []rune(m.filter)
				m.filter = string(r[:len(r)-1])
				m.applyFilter()
				return m, nil
			}
		case "ctrl+u":
			m.filter = ""
			m.applyFilter()
			return m, nil
		case "up", "ctrl+k":
			if m.sel > 0 {
				m.sel--
			}
			return m, nil
		case "down", "ctrl+j":
			if m.sel < len(m.view)-1 {
				m.sel++
			}
			return m, nil
		case "ctrl+p":
			r := m.selected()
			if r == nil || r.kind != "dir" {
				return m, nil
			}
			if m.ctx.Block == "" {
				m.err = "no block context"
				return m, nil
			}
			m.splitMode = true
			return m, nil
		case "ctrl+o":
			targets := m.cfg
			targets.Targets = targets.AvailableTargets(m.ctx.Block != "")
			m.target = dispatch.NextTarget(targets, m.target, true)
			return m, nil
		case "alt+1", "alt+2", "alt+3", "alt+4", "alt+5", "alt+6", "alt+7", "alt+8", "alt+9":
			number := int(msg.String()[len(msg.String())-1] - '0')
			if number >= 1 && number <= len(m.view) {
				m.sel = number - 1
				if r := m.selected(); r != nil {
					m.picked = r
					return m, tea.Quit
				}
			}
			return m, nil
		case "ctrl+g":
			r := m.selected()
			if r == nil || r.kind != "dir" {
				return m, nil
			}
			pinned, err := config.TogglePin(r.path)
			if err != nil {
				m.err = err.Error()
				return m, nil
			}
			m.loadPins()
			m.applyFilter()
			if pinned {
				// Jump the cursor to the freshly pinned row.
				for position, index := range m.view {
					if m.rows[index].path == r.path {
						m.sel = position
						break
					}
				}
			}
			return m, nil
		case "enter":
			r := m.selected()
			if m.launcher {
				if r != nil {
					m.openLauncherActions(r.path)
				}
				return m, nil
			}
			if r != nil {
				m.picked = r
			}
			return m, tea.Quit
		case "ctrl+t", "ctrl+n", "f2":
			r := m.selected()
			if r != nil && r.kind == "dir" && worktreepkg.IsGitRepo(r.path) {
				m.next = "wt"
				if msg.String() != "ctrl+t" {
					m.next = "wt-create"
				}
				m.nextRepo = worktreepkg.RepoRoot(r.path)
				return m, tea.Quit
			}
			if r != nil {
				m.err = "not a git repo"
			}
			return m, nil
		default:
			if msg.Type == tea.KeyRunes || msg.Type == tea.KeySpace {
				m.filter += string(msg.Runes)
				m.applyFilter()
				return m, nil
			}
		}
	}
	return m, nil
}

func (m *dirModel) switchToRepos() tea.Cmd {
	return m.switchView(0)
}

func (m *dirModel) View() string {
	if m.width < 1 || m.height < 1 {
		return ""
	}
	if m.width < 4 || m.height < 5 {
		return pickerTiny(m.width, m.height)
	}
	if m.actionMenu {
		return m.viewLauncherActions()
	}
	if m.viewMode == 2 {
		return m.viewAgents()
	}
	width := m.width - 2
	blank := pickerLine("", width)
	lines := []string{pickerSearch(m.filter, width, "dir")}
	if m.height >= 8 {
		// Compact palettes keep every line for results.
		lines = append(lines, pickerPills(0, width))
	}
	lines = append(lines, blank)
	footerRows := 2
	maxRows := maxInt(m.height-len(lines)-footerRows, 0)
	start := maxInt(m.sel-maxRows+1, 0)
	for n := 0; n < maxRows; n++ {
		vi := start + n
		if vi >= len(m.view) {
			if n == 0 {
				lines = append(lines, pickerLine(pickerMuted.Render(" No matching directories"), width))
			} else {
				lines = append(lines, blank)
			}
			continue
		}
		r := m.rows[m.view[vi]]
		lines = append(lines, pickerDirectoryRowActivity(r.path, m.pinned[r.path], vi+1, width, vi == m.sel, activityIndicator(r.state, r.working, m.activityFrame)))
	}
	lines = append(lines, pickerRule(width))
	target := pickerAccent.Bold(true).Render(dispatch.TargetLabel(m.target))
	left := pickerMuted.Render("Open as: ") + target
	if lipgloss.Width(left)+3 <= width {
		left += pickerMuted.Render(" ^o")
	}
	if lipgloss.Width(left) > width {
		left = target
	}
	splitHint := pickerText.Render("^p") + pickerMuted.Render(" split")
	right := splitHint + "  " + pickerText.Render("^n") + pickerMuted.Render(" new worktree") + "  " + pickerText.Render("^g") + pickerMuted.Render(" pin") + "  " + pickerText.Render("⇥") + pickerMuted.Render(" agents")
	if width-lipgloss.Width(left)-lipgloss.Width(right) < 2 {
		right = splitHint + "  " + pickerText.Render("⇥") + pickerMuted.Render(" agents")
	}
	footer := pickerFooter(left, right, left, width)
	if m.launcher {
		footer = pickerLine(pickerMuted.Render("enter Actions · esc Back/close"), width)
	}
	if m.splitMode {
		directions := pickerAccent.Bold(true).Render("j↓ l→")
		footer = pickerFooter(pickerMuted.Render("Split: ")+directions, pickerMuted.Render("esc cancel"), directions+pickerMuted.Render(" · esc"), width)
	}
	if m.err != "" {
		footer = pickerLine(styErr.Render(m.err), width)
	}
	lines = append(lines, footer)
	return strings.Join(lines, "\n")
}

func renderTargets(cfg config.Config, active string) string {
	parts := []string{"  " + styDim.Render("OPEN AS")}
	for _, target := range cfg.Targets {
		label := strings.ToUpper(dispatch.TargetLabel(target))
		if target == "pane_right" {
			label = "PANE →"
		} else if target == "pane_below" {
			label = "PANE ↓"
		} else if target == "here" {
			label = "HERE"
		}
		if target == active {
			parts = append(parts, styTarget.Render("["+label+"]"))
		} else {
			parts = append(parts, styDim.Render(" "+label+" "))
		}
	}
	return strings.Join(parts, " ")
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// searchBox renders the palette's search row, inside the outer frame.
func (m *dirModel) searchBox(width int) string {
	content := "⌕  " + m.filter + styTarget.Render("│")
	if lipgloss.Width(content) > width {
		content = truncateW(content, width)
	}
	return padRight(content, width)
}

func padRight(s string, w int) string {
	if n := lipgloss.Width(s); n < w {
		return s + strings.Repeat(" ", w-n)
	}
	return s
}

func truncateW(s string, w int) string {
	if lipgloss.Width(s) <= w {
		return s
	}
	return ansi.Truncate(s, maxInt(w, 0), "…")
}
