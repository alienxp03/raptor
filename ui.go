package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/sahilm/fuzzy"
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
	kind      string // "session" | "dir"
	label     string // basename
	path      string // full path (for sessions: best-effort cwd)
	sessionID string // set for sessions
}

type dirModel struct {
	cfg    Config
	ctx    Ctx
	rows   []row // full set
	view   []int // indices into rows after filtering
	filter string
	sel    int
	target string
	err    string
	width  int
	height int
	// result of the interaction, read after the program exits
	picked   *row   // non-nil when a dir/session was chosen
	next     string // "wt" when bridging with a repo path in nextRepo
	nextRepo string
}

type previewMsg struct {
	For  string
	text string
}

func loadDirRows(ctx Ctx) []row {
	var rows []row
	for _, d := range zoxideList() {
		rows = append(rows, row{kind: "dir", label: basename(d), path: d})
	}
	return rows
}

func runDirs(ctx Ctx, cfg Config) int {
	m := &dirModel{cfg: cfg, ctx: ctx, rows: loadDirRows(ctx), target: cfg.Enter}
	m.applyFilter()
	p := tea.NewProgram(m, tea.WithAltScreen())
	final, err := p.Run()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	dm := final.(*dirModel)

	// bridge into the worktree flow
	if dm.next == "wt" {
		return runWorktrees(ctx, cfg, dm.nextRepo)
	}
	if dm.picked == nil {
		return 0
	}
	r := dm.picked
	if r.kind == "session" {
		if ctx.Session != "" && ctx.Session != r.sessionID {
			writeLast(ctx.Session)
		}
		if ctx.Client != "" {
			_ = rexDo(ctx.Client, "session.select", "session_id="+r.sessionID)
		}
		return 0
	}
	if err := dispatch(dm.target, r.path, ctx, cfg); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return 0
}

func (m *dirModel) Init() tea.Cmd { return tea.SetWindowTitle("zpick") }
func (m *dirModel) applyFilter() {
	m.view = m.view[:0]
	if m.filter == "" {
		for i := range m.rows {
			m.view = append(m.view, i)
		}
		return
	}
	type cand struct{ idx, score int }
	haystack := make([]string, len(m.rows))
	for i, r := range m.rows {
		haystack[i] = r.label + " " + homeRelative(r.path)
	}
	matches := fuzzy.Find(m.filter, haystack)
	for _, mt := range matches {
		m.view = append(m.view, mt.Index)
	}
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
		switch msg.String() {
		case "ctrl+c", "q":
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
		case "tab", "shift+tab":
			m.target = nextTarget(m.cfg, m.target, msg.String() == "tab")
			return m, nil
		case "enter":
			r := m.selected()
			if r != nil {
				m.picked = r
			}
			return m, tea.Quit
		case "w":
			r := m.selected()
			if r != nil && r.kind == "dir" && isGitRepo(r.path) {
				m.next = "wt"
				m.nextRepo = repoRoot(r.path)
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
	var b strings.Builder
	b.WriteString(m.searchBox() + "\n")

	maxRows := m.height - 6
	if maxRows < 1 {
		maxRows = 1
	}
	var lines []string
	start := 0
	if m.sel >= maxRows {
		start = m.sel - maxRows + 1
	}
	shown := 0
	for vi := start; vi < len(m.view) && shown < maxRows; vi, shown = vi+1, shown+1 {
		r := m.rows[m.view[vi]]
		prefix := "  "
		var text string
		if r.kind == "session" {
			text = stySession.Render("● ") + r.label
		} else {
			text = homeRelative(r.path)
		}
		if vi == m.sel {
			prefix = stySel.Render("> ")
			text = stySel.Render(text)
		}
		line := prefix + text
		if w := lipgloss.Width(line); w > m.width {
			line = truncateW(line, m.width)
		}
		lines = append(lines, line)
	}
	for len(lines) < maxRows {
		lines = append(lines, "")
	}
	b.WriteString(strings.Join(lines, "\n"))

	// footer pinned at the bottom, set off by a rule
	rule := styDim.Render(strings.Repeat("─", maxInt(m.width-2, 3)))
	b.WriteString("\n" + rule + "\n")
	hints := "  " + headerTargets(m.cfg, m.target)
	hints += styDim.Render("   tab⇄ · w worktrees · ⏎ open · esc")
	if m.err != "" {
		hints += "   " + styErr.Render(m.err)
	}
	b.WriteString(hints)
	return b.String()
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// searchBox renders the rounded input box with a block cursor.
func (m *dirModel) searchBox() string {
	inner := 20
	if w := m.width - 6; w > inner {
		inner = w
	}
	text := m.filter
	placeholder := "type to search…"
	var content string
	if text == "" {
		content = styDim.Render(placeholder)
	} else {
		content = text + stySel.Render("│")
	}
	if len([]rune(text)) > inner-2 {
		r := []rune(text)
		content = string(r[len(r)-inner+3:]) + stySel.Render("│")
	}
	box := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(lipgloss.Color("8")).
		Padding(0, 1).
		Width(inner)
	return box.Render("❯ " + content)
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
	// naive visible-char truncate preserving ansi-ish by runes
	r := []rune(s)
	out := ""
	for _, c := range r {
		if lipgloss.Width(out)+1 > w-1 {
			break
		}
		out += string(c)
	}
	return out + "…"
}
