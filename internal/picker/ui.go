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
	current bool   // origin pane repository or directory
}

type dirModel struct {
	cfg        config.Config
	ctx        rex.Ctx
	rows       []row // full set
	view       []int // indices into rows after filtering
	filter     string
	sel        int
	target     string
	splitMode  bool
	launcher   bool
	actionMenu bool
	actionSel  int
	actions    []launcherAction
	err        string
	width      int
	height     int
	// result of the interaction, read after the program exits
	picked   *row   // non-nil when a directory was chosen
	next     string // "wt" or "wt-create" with a repo path in nextRepo
	nextRepo string
}

type previewMsg struct {
	For  string
	text string
}

func loadDirRows(ctx rex.Ctx) []row {
	var rows []row
	for _, d := range catalog.ContextDirectories(ctx, false) {
		rows = append(rows, row{kind: "dir", label: d.Label, path: d.Path, current: d.Current})
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
	m.applyFilter()
	var dm *dirModel
	for {
		final, err := tea.NewProgram(m, tea.WithAltScreen()).Run()
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		dm = final.(*dirModel)
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
		items[i] = catalog.Directory{Label: r.label, Path: r.path, Current: r.current}
	}
	m.view = catalog.FilterDirectories(items, m.filter)
	if m.sel >= len(m.view) {
		m.sel = len(m.view) - 1
	}
	if m.sel < 0 {
		m.sel = 0
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
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		return m, nil
	case tea.KeyMsg:
		m.err = ""
		if m.actionMenu {
			return m.updateLauncherActions(msg)
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
				"h": "pane_left", "left": "pane_left",
				"j": "pane_below", "down": "pane_below",
				"k": "pane_above", "up": "pane_above",
				"l": "pane", "right": "pane",
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
		case "tab", "shift+tab", "ctrl+o":
			targets := m.cfg
			targets.Targets = targets.AvailableTargets(m.ctx.Block != "")
			m.target = dispatch.NextTarget(targets, m.target, msg.String() != "shift+tab")
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
	width := m.width - 2
	blank := pickerLine("", width)
	lines := []string{pickerSearch(m.filter, width, "dir"), blank}
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
		if r.current {
			lines = append(lines, pickerEntry(r.label, r.path, width, vi == m.sel))
		} else {
			lines = append(lines, pickerDirectory(r.path, width, vi == m.sel))
		}
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
	right := splitHint + "  " + pickerText.Render("^n") + pickerMuted.Render(" new worktree") + "  " + pickerText.Render("^t") + pickerMuted.Render(" worktrees")
	if width-lipgloss.Width(left)-lipgloss.Width(right) < 2 {
		right = splitHint
	}
	footer := pickerFooter(left, right, left, width)
	if m.launcher {
		footer = pickerLine(pickerMuted.Render("enter Actions · esc Back/close"), width)
	}
	if m.splitMode {
		directions := pickerAccent.Bold(true).Render("h← j↓ k↑ l→")
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
		if target == "pane" {
			label = "PANE →"
		} else if target == "pane_below" {
			label = "PANE ↓"
		} else if target == "here" {
			label = "HERE"
		}
		if target == active {
			parts = append(parts, lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("14")).Render("["+label+"]"))
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
