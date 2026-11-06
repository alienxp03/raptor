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
	kind  string // "dir"
	label string // paths.Basename
	path  string // full directory path
}

type dirModel struct {
	cfg        config.Config
	ctx        rex.Ctx
	viewMode   int // 0 = repos, 1 = tabs & sessions
	rows       []row // full set
	view       []int // indices into rows after filtering (repos view)
	tabs       []rex.SessionEntry
	tabsView   []int // indices into tabs after filtering
	pinned     map[string]bool
	filter     string
	sel        int
	target     string
	splitMode  bool
	launcher   bool
	actionMenu bool
	actionSel  int
	actions    []launcherAction
	tabsLoaded bool
	renaming   bool
	renameBuf  string
	closeArm   string // entry id armed for a second ctrl+x
	err        string
	width      int
	height     int
	// result of the interaction, read after the program exits
	picked   *row   // non-nil when a directory was chosen
	jumped   *rex.SessionEntry // non-nil when a tab/session jump was chosen
	next     string // "wt" or "wt-create" with a repo path in nextRepo
	nextRepo string
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
	return runDirs(ctx, cfg, false)
}

// RunLauncher previews a path's actions before dispatching. Normal pickers stay unchanged.
func RunLauncher(ctx rex.Ctx, cfg config.Config) int {
	return runDirs(ctx, cfg, true)
}

func runDirs(ctx rex.Ctx, cfg config.Config, launcher bool) int {
	m := &dirModel{cfg: cfg, ctx: ctx, rows: loadDirRows(ctx), target: cfg.Enter, launcher: launcher}
	m.loadPins()
	m.applyFilter()
	var dm *dirModel
	for {
		final, err := tea.NewProgram(m, tea.WithAltScreen()).Run()
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		dm = final.(*dirModel)
		if dm.jumped != nil {
			if err := rex.Jump(*dm.jumped, ctx.Client); err != nil {
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
		if code != returnToDirectories {
			return code
		}
		// Resume the same picker rather than constructing a fresh one.
		dm.next, dm.nextRepo = "", ""
		dm.actionMenu = false
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

func (m *dirModel) Init() tea.Cmd { return m.ctx.TitleCommand() }
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

func (m *dirModel) loadTabs() {
	entries, err := rex.SessionEntries(m.ctx.Session)
	if err != nil {
		m.err = err.Error()
		entries = nil
	}
	m.tabs = entries
	m.tabsLoaded = true
	m.applyTabFilter()
}

func (m *dirModel) applyTabFilter() {
	m.tabsView = catalog.FilterSessions(m.tabs, m.filter)
	if m.sel >= len(m.tabsView) {
		m.sel = len(m.tabsView) - 1
	}
	if m.sel < 0 {
		m.sel = 0
	}
}

func (m *dirModel) applyCurrentFilter() {
	if m.viewMode == 1 {
		m.applyTabFilter()
	} else {
		m.applyFilter()
	}
}

func (m *dirModel) selectedEntry() *rex.SessionEntry {
	if m.viewMode != 1 || len(m.tabsView) == 0 {
		return nil
	}
	if m.sel >= len(m.tabsView) || m.sel < 0 {
		return nil
	}
	return &m.tabs[m.tabsView[m.sel]]
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
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		return m, nil
	case tea.KeyMsg:
		m.err = ""
		if m.renaming {
			return m.updateRename(msg)
		}
		if m.actionMenu {
			return m.updateLauncherActions(msg)
		}
		if m.viewMode == 1 {
			return m.updateTabs(msg)
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
			if m.filter != "" {
				m.filter = ""
				m.applyFilter()
				return m, nil
			}
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
		case "tab", "shift+tab":
			m.switchToTabs()
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

func (m *dirModel) switchToTabs() {
	m.viewMode = 1
	m.sel = 0
	m.splitMode = false
	m.closeArm = ""
	if !m.tabsLoaded {
		m.loadTabs()
	} else {
		m.applyTabFilter()
	}
}

func (m *dirModel) switchToRepos() {
	m.viewMode = 0
	m.sel = 0
	m.closeArm = ""
	m.applyFilter()
}

func (m *dirModel) updateTabs(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c":
		return m, tea.Quit
	case "esc":
		if m.filter != "" {
			m.filter = ""
			m.applyTabFilter()
			return m, nil
		}
		m.switchToRepos()
		return m, nil
	case "backspace":
		if m.filter != "" {
			r := []rune(m.filter)
			m.filter = string(r[:len(r)-1])
			m.applyTabFilter()
		}
		return m, nil
	case "ctrl+u":
		m.filter = ""
		m.applyTabFilter()
		return m, nil
	case "up", "ctrl+k":
		if m.sel > 0 {
			m.sel--
		}
		return m, nil
	case "down", "ctrl+j":
		if m.sel < len(m.tabsView)-1 {
			m.sel++
		}
		return m, nil
	case "tab", "shift+tab":
		m.switchToRepos()
		return m, nil
	case "enter":
		if entry := m.selectedEntry(); entry != nil {
			jumped := *entry
			m.jumped = &jumped
			return m, tea.Quit
		}
		return m, nil
	case "ctrl+r":
		if entry := m.selectedEntry(); entry != nil {
			m.renaming = true
			m.renameBuf = entry.Label
		}
		return m, nil
	case "ctrl+x":
		entry := m.selectedEntry()
		if entry == nil {
			return m, nil
		}
		if entry.Kind == "session" && entry.SessionID == m.ctx.Session {
			m.err = "cannot close this session"
			return m, nil
		}
		if m.closeArm != entry.ID {
			m.closeArm = entry.ID
			return m, nil
		}
		m.closeArm = ""
		var err error
		if entry.Kind == "session" {
			err = rex.CloseSession(entry.SessionID)
		} else {
			err = rex.CloseWindow(entry.SessionID, entry.ID)
		}
		if err != nil {
			m.err = err.Error()
		}
		m.loadTabs()
		return m, nil
	case "alt+1", "alt+2", "alt+3", "alt+4", "alt+5", "alt+6", "alt+7", "alt+8", "alt+9":
		number := int(msg.String()[len(msg.String())-1] - '0')
		if number >= 1 && number <= len(m.tabsView) {
			m.sel = number - 1
			if entry := m.selectedEntry(); entry != nil {
				jumped := *entry
				m.jumped = &jumped
				return m, tea.Quit
			}
		}
		return m, nil
	default:
		if msg.Type == tea.KeyRunes || msg.Type == tea.KeySpace {
			m.filter += string(msg.Runes)
			m.applyTabFilter()
			return m, nil
		}
	}
	return m, nil
}

func (m *dirModel) updateRename(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc":
		m.renaming = false
		return m, nil
	case "enter":
		entry := m.selectedEntry()
		if entry == nil {
			m.renaming = false
			return m, nil
		}
		var err error
		if entry.Kind == "session" {
			err = rex.SetSessionLabel(entry.SessionID, m.renameBuf)
		} else {
			err = rex.SetWindowLabel(entry.SessionID, entry.ID, m.renameBuf)
		}
		m.renaming = false
		if err != nil {
			m.err = err.Error()
		}
		m.loadTabs()
		return m, nil
	case "backspace":
		if r := []rune(m.renameBuf); len(r) > 0 {
			m.renameBuf = string(r[:len(r)-1])
		}
		return m, nil
	default:
		if msg.Type == tea.KeyRunes || msg.Type == tea.KeySpace {
			m.renameBuf += string(msg.Runes)
		}
	}
	return m, nil
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
	if m.renaming {
		return m.viewRename()
	}
	if m.viewMode == 1 {
		return m.viewTabs()
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
		lines = append(lines, pickerDirectoryRow(r.path, m.pinned[r.path], vi+1, width, vi == m.sel))
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
	right := splitHint + "  " + pickerText.Render("^n") + pickerMuted.Render(" new worktree") + "  " + pickerText.Render("^g") + pickerMuted.Render(" pin") + "  " + pickerText.Render("⇥") + pickerMuted.Render(" tabs")
	if width-lipgloss.Width(left)-lipgloss.Width(right) < 2 {
		right = splitHint + "  " + pickerText.Render("⇥") + pickerMuted.Render(" tabs")
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

func (m *dirModel) viewTabs() string {
	width := m.width - 2
	blank := pickerLine("", width)
	lines := []string{pickerSearch(m.filter, width, "tabs")}
	if m.height >= 8 {
		lines = append(lines, pickerPills(1, width))
	}
	lines = append(lines, blank)
	footerRows := 2
	maxRows := maxInt(m.height-len(lines)-footerRows, 0)
	start := maxInt(m.sel-maxRows+1, 0)
	for n := 0; n < maxRows; n++ {
		vi := start + n
		if vi >= len(m.tabsView) {
			message := ""
			if n == 0 {
				if !m.tabsLoaded {
					message = " Loading tabs…"
				} else {
					message = " No matching tabs"
				}
				lines = append(lines, pickerLine(pickerMuted.Render(message), width))
			} else {
				lines = append(lines, blank)
			}
			continue
		}
		entry := m.tabs[m.tabsView[vi]]
		lines = append(lines, pickerSessionRow(entry, vi+1, width, vi == m.sel))
	}
	lines = append(lines, pickerRule(width))
	left := pickerText.Render("^x") + pickerMuted.Render(" close") + "  " + pickerText.Render("^r") + pickerMuted.Render(" rename")
	if m.closeArm != "" {
		left = pickerMark.Render("press ^x again to close")
	}
	right := pickerText.Render("⇥") + pickerMuted.Render(" repos · ") + pickerText.Render("esc") + pickerMuted.Render(" back")
	footer := pickerFooter(left, right, left, width)
	if m.err != "" {
		footer = pickerLine(styErr.Render(m.err), width)
	}
	lines = append(lines, footer)
	return strings.Join(lines, "\n")
}

func (m *dirModel) viewRename() string {
	width := m.width - 2
	entry := m.selectedEntry()
	scope := "tab"
	if entry != nil && entry.Kind == "session" {
		scope = "session"
	}
	lines := []string{
		pickerSearch(m.renameBuf, width, "rename "+scope),
		pickerRule(width),
		pickerLine(pickerMuted.Render("enter Rename · esc Cancel"), width),
	}
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
