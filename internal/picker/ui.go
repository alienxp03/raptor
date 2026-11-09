package picker

import (
	"context"
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
	cfg                     config.Config
	ctx                     rex.Ctx
	viewMode                int             // 0 = sessions launcher, 2 = agents (1 is unused)
	launcher                []launcherRow   // full unified row set
	launcherView            []launcherMatch // filtered rows with match positions
	sessions                []rex.HostGroup // cached per-host session groups
	hostOrder               []string        // hosts with directories loaded, in badge order
	hostDirs                map[string][]catalog.Directory
	launcherDirsPending     map[string]uint64
	launcherLoaded          bool
	launcherSessionsLoading bool
	launcherSessionsRequest uint64
	launcherDirsRequest     uint64
	pinned                  map[string]bool
	filter                  string
	sel                     int
	target                  string
	splitMode               bool
	launcherMode            bool // experimental path → action flow
	actionMenu              bool
	actionSel               int
	actions                 []launcherAction
	agents                  []rex.AgentEntry
	agentsView              []int
	agentsLoaded            bool
	agentsLoading           bool
	agentsRequest           uint64
	agentSnapshot           bool
	pendingAgents           []rex.AgentEntry
	agentGroups             map[agentIdentity]int
	previewRequest          uint64
	previewKey              string
	previewPending          bool
	previewText             string
	activityFrame           int
	sessionRecency          rex.SessionRecency // fixed for one picker presentation
	activityEntries         []rex.AgentEntry
	activityRemote          map[string][]rex.AgentEntry
	activityTickPending     bool
	activityTickID          uint64
	activityStopping        bool
	activityWatcher         *rex.EventWatcher
	activityLivePending     bool
	activityLiveDirty       bool
	activityLiveID          uint64
	viewStates              [3]dirViewState
	err                     string
	width                   int
	height                  int
	// result of the interaction, read after the program exits
	picked       *row              // non-nil when a directory was chosen for dispatch
	jumpedAgent  *rex.AgentEntry   // separate result: jump to the exact agent pane
	jumpSession  *rex.SessionEntry // separate result: switch to that session
	closeSession *rex.SessionEntry // separate result: close that session
	launchDir    *dirLaunch        // separate result: select-or-create at a directory
	next         string            // "wt" or "wt-create" with a repo path in nextRepo
	nextRepo     string
}

// Scroll position is derived from sel and the current viewport height.
type dirViewState struct {
	filter string
	sel    int
}

// dirLaunch creates a session at a directory on a host and switches to it.
type dirLaunch struct {
	Host string
	Path string
}

func RunDirs(ctx rex.Ctx, cfg config.Config) int {
	return runDirs(ctx, cfg, false, 0)
}

// RunAgents opens the picker directly in its Agents view.
func RunAgents(ctx rex.Ctx, cfg config.Config) int {
	return runDirs(ctx, cfg, false, 2)
}

// RunSessions opens the picker directly in its Sessions launcher.
func RunSessions(ctx rex.Ctx, cfg config.Config) int {
	return runDirs(ctx, cfg, false, 0)
}

// RunLauncher previews a path's actions before dispatching. Normal pickers stay unchanged.
func RunLauncher(ctx rex.Ctx, cfg config.Config) int {
	return runDirs(ctx, cfg, true, 0)
}

func newDirModel(ctx rex.Ctx, cfg config.Config, experimental bool, view int) *dirModel {
	if view != 2 {
		view = 0
	}
	// The launcher's default verb is session creation; cfg.Enter stays for
	// the worktree flows and the experimental launcher.
	defaultTarget := cfg.Enter
	if !experimental && view != 2 {
		defaultTarget = "session"
	}
	m := &dirModel{cfg: cfg, ctx: ctx, target: defaultTarget, launcherMode: experimental, viewMode: view, hostDirs: map[string][]catalog.Directory{}}
	m.loadPins()
	m.applyCurrentFilter()
	return m
}

func runDirs(ctx rex.Ctx, cfg config.Config, launcher bool, view int) int {
	m := newDirModel(ctx, cfg, launcher, view)
	var dm *dirModel
	for {
		// Opening from a pane is an explicit visit, not background activity.
		_ = rex.RecordSessionUse("", ctx.Session)
		m.sessionRecency = rex.LoadSessionRecency()
		m.applyLauncher()
		m.activityWatcher = rex.WatchEvents(context.Background())
		m.activityWatcher.Discover()
		final, err := tea.NewProgram(m, tea.WithAltScreen()).Run()
		m.activityWatcher.Close()
		m.activityWatcher = nil
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		dm = final.(*dirModel)
		if code, done := finishSessionsResult(ctx, dm); done {
			return code
		}
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
	m.activityLiveID++
	m.activityLivePending, m.activityLiveDirty = false, false
	commands := []tea.Cmd{m.ctx.TitleCommand(), m.scheduleActivityTick(), waitActivityEvent(m.activityWatcher)}
	// Launcher rows carry their own State/Working from the host listing; the
	// local-only agent snapshot is a concern of the Agents view.
	if m.viewMode == 0 {
		commands = append(commands, activityCommand(m.ctx.Session, m.activityLiveID))
	}
	if m.agentsLoading || (m.viewMode == 2 && !m.agentsLoaded) {
		commands = append(commands, m.loadAgents(true))
	}
	// A worktree flow can leave a load interrupted: restart it on resume.
	// Completed caches stay visible without churn.
	if m.viewMode == 0 && (m.launcherSessionsLoading || !m.launcherLoaded) {
		commands = append(commands, m.loadLauncherSessions(true))
	}
	// Local directories answer in milliseconds; start them beside the
	// sessions fetch so the launcher fills from both ends.
	if m.viewMode == 0 && m.hostDirs[rex.LocalHostLabel] == nil {
		commands = append(commands, m.loadLauncherDirs(rex.LocalHostLabel, false))
	}
	return tea.Batch(commands...)
}

// loadPins marks pinned local directories so rows can show the pin glyph.
// Pins are local-machine paths; remote directories never pin.
func (m *dirModel) loadPins() {
	m.pinned = map[string]bool{}
	for _, item := range catalog.ApplyPins(catalog.DirectoriesOn(rex.LocalHostLabel, false)) {
		m.pinned[item.Path] = item.Pinned
	}
}

func (m *dirModel) applyCurrentFilter() {
	if m.viewMode == 2 {
		m.applyAgentFilter()
	} else {
		m.applyLauncher()
	}
}

func (m *dirModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	stopping := false
	if key, ok := msg.(tea.KeyMsg); ok {
		stopping = key.String() == "ctrl+c" || (key.String() == "esc" && !m.splitMode && !m.actionMenu)
	}
	model, cmd := m.update(msg)
	if stopping || m.picked != nil || m.jumpedAgent != nil || m.jumpSession != nil || m.closeSession != nil || m.launchDir != nil || m.next != "" {
		m.activityStopping = true
	}
	switch msg.(type) {
	case activityTickMsg, activityLoadedMsg, agentsLoadedMsg, launcherSessionsMsg, activityLiveMsg:
		if tick := m.scheduleActivityTick(); tick != nil {
			return model, tea.Batch(cmd, tick)
		}
	}
	return model, cmd
}

func (m *dirModel) update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case activityEventMsg:
		if m.activityStopping {
			return m, nil
		}
		return m, tea.Batch(waitActivityEvent(m.activityWatcher), m.refreshLiveActivity())
	case activityLiveMsg:
		return m, m.acceptLiveActivity(msg)
	case activityTickMsg:
		if msg.id == m.activityTickID {
			m.activityTickPending = false
			m.activityFrame = (m.activityFrame + 1) % 4
		}
		return m, nil
	case activityLoadedMsg:
		if msg.err == nil && msg.generation == m.activityLiveID {
			m.projectActivity(msg.entries)
		}
		return m, nil
	case agentsLoadedMsg:
		m.acceptAgents(msg)
		return m, nil
	case launcherSessionsMsg:
		current := msg.request == m.launcherSessionsRequest && m.launcherSessionsLoading
		m.acceptLauncherSessions(msg)
		if current {
			return m, tea.Batch(m.loadAllLauncherDirs(false), m.schedulePreview())
		}
		return m, nil
	case launcherDirsMsg:
		m.acceptLauncherDirs(msg)
		return m, m.schedulePreview()
	case captureMsg:
		m.acceptCapture(msg)
		return m, nil
	case previewTickMsg:
		return m, m.acceptPreviewTick(msg)
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
		if msg.String() == "ctrl+s" {
			if m.viewMode == 0 {
				return m, nil
			}
			return m, m.switchView(0)
		}
		if !m.splitMode && (msg.String() == "tab" || msg.String() == "shift+tab") {
			// Two views: the Sessions launcher and Agents.
			next := 2
			if m.viewMode == 2 {
				next = 0
			}
			return m, m.switchView(next)
		}
		if m.viewMode == 2 {
			return m.updateAgents(msg)
		}
		model, cmd := m.updateLauncher(msg)
		return model, tea.Batch(cmd, m.schedulePreview())
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
	return m.viewLauncher()
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
