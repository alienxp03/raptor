package picker

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/sahilm/fuzzy"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/dispatch"
	"github.com/alienxp03/raptor/internal/paths"
	"github.com/alienxp03/raptor/internal/rex"
	worktreepkg "github.com/alienxp03/raptor/internal/worktree"
)

type worktree = worktreepkg.Worktree

type wtModel struct {
	cfg           config.Config
	ctx           rex.Ctx
	repo          string
	root          string
	rows          []worktree
	view          []int
	filter        string
	sel           int
	width, height int
	err           string
	form          bool
	field         int // branch, base chooser, create button
	errField      int // -1 for a general error
	baseSelecting bool
	baseQuery     string
	baseSel       int
	branch        string
	base          string
	branches      []string
	confirm       bool
	busy          bool
	splitMode     bool
	target        string
	action        string
	chosen        *worktree
}
type wtCreatedMsg struct {
	path string
	err  error
}
type wtRemovedMsg struct{ err error }

const returnToDirectories = -1

func RunWorktrees(ctx rex.Ctx, cfg config.Config, repo string) int {
	return runWorktreeFlow(ctx, cfg, repo, false)
}

func runWorktreeFlow(ctx rex.Ctx, cfg config.Config, repo string, fromDirectories bool) int {
	if repo == "" {
		repo = worktreepkg.RepoRoot(rex.BlockCwd(ctx.Block))
	}
	if repo == "" || !worktreepkg.IsGitRepo(repo) {
		repo = pickRepo(ctx, cfg)
		if repo == "" {
			return 0
		}
	}
	m := newWtModel(ctx, cfg, repo)
	final, err := tea.NewProgram(m, tea.WithAltScreen()).Run()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	model := final.(*wtModel)
	if model.action == "back" {
		if fromDirectories {
			return returnToDirectories
		}
		return RunDirs(ctx, cfg)
	}
	if model.chosen != nil {
		if err := dispatch.Dispatch(model.target, model.chosen.Path, ctx, cfg); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
	}
	return 0
}
func newWtModel(ctx rex.Ctx, cfg config.Config, repo string) *wtModel {
	m := &wtModel{ctx: ctx, cfg: cfg, repo: repo, branches: worktreepkg.LocalBranches(repo), errField: -1, target: cfg.Enter}
	m.rows = worktreepkg.List(repo)
	primary := repo
	if len(m.rows) > 0 {
		primary = m.rows[0].Path
	}
	m.root = filepath.Join(cfg.WorktreeRoot, worktreepkg.RepoFolder(paths.Basename(primary)))
	m.base, _ = worktreepkg.GitOut(repo, "branch", "--show-current")
	if m.base == "" && len(m.branches) > 0 {
		m.base = m.branches[0]
	}
	m.applyFilter()
	return m
}
func (m *wtModel) Init() tea.Cmd       { return m.ctx.TitleCommand() }
func (m *wtModel) destination() string { return filepath.Join(m.root, worktreepkg.Folder(m.branch)) }
func (m *wtModel) applyFilter() {
	m.view = nil
	if m.filter == "" {
		for i := range m.rows {
			m.view = append(m.view, i)
		}
	} else {
		entries := make([]string, len(m.rows))
		for i, r := range m.rows {
			entries[i] = r.Branch + " " + paths.HomeRelative(r.Path)
		}
		for _, match := range fuzzy.Find(m.filter, entries) {
			m.view = append(m.view, match.Index)
		}
	}
	if m.sel >= len(m.view) {
		m.sel = len(m.view) - 1
	}
	if m.sel < 0 {
		m.sel = 0
	}
}
func (m *wtModel) selected() *worktree {
	if m.sel < 0 || m.sel >= len(m.view) {
		return nil
	}
	return &m.rows[m.view[m.sel]]
}
func editQuery(value *string, msg tea.KeyMsg) bool {
	switch msg.String() {
	case "backspace":
		r := []rune(*value)
		if len(r) > 0 {
			*value = string(r[:len(r)-1])
		}
	case "ctrl+u":
		*value = ""
	default:
		if msg.Type != tea.KeyRunes && msg.Type != tea.KeySpace {
			return false
		}
		*value += string(msg.Runes)
	}
	return true
}

func (m *wtModel) baseChoices() []string {
	if m.baseQuery == "" {
		return m.branches
	}
	var result []string
	for _, match := range fuzzy.Find(m.baseQuery, m.branches) {
		result = append(result, m.branches[match.Index])
	}
	return result
}

func (m *wtModel) openBaseChooser() {
	m.branches = worktreepkg.LocalBranches(m.repo)
	m.baseSelecting, m.baseQuery, m.baseSel = true, "", 0
	for i, branch := range m.branches {
		if branch == m.base {
			m.baseSel = i
			break
		}
	}
}

func (m *wtModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
	case wtCreatedMsg:
		m.busy = false
		if msg.err != nil {
			m.err = msg.err.Error()
			return m, nil
		}
		m.chosen = &worktree{Path: msg.path, Branch: m.branch}
		return m, tea.Quit
	case wtRemovedMsg:
		m.busy = false
		m.confirm = false
		if msg.err != nil {
			m.err = msg.err.Error()
		} else {
			m.rows = worktreepkg.List(m.repo)
			m.applyFilter()
		}
	case tea.KeyMsg:
		if m.busy {
			return m, nil
		}
		key := msg.String()
		if key == "ctrl+c" {
			return m, tea.Quit
		}
		if m.splitMode {
			switch key {
			case "esc", "ctrl+p":
				m.splitMode = false
			case "h", "left":
				m.target = "pane_left"
			case "j", "down":
				m.target = "pane_below"
			case "k", "up":
				m.target = "pane_above"
			case "l", "right":
				m.target = "pane"
			default:
				return m, nil
			}
			if key != "esc" && key != "ctrl+p" {
				if r := m.selected(); r != nil {
					w := *r
					m.chosen = &w
					return m, tea.Quit
				}
			}
			return m, nil
		}
		if m.confirm {
			switch key {
			case "esc", "n":
				m.confirm = false
				m.err = ""
			case "enter", "y":
				r := m.selected()
				if r == nil {
					return m, nil
				}
				w := *r
				repo := m.repo
				m.busy = true
				return m, func() tea.Msg { return wtRemovedMsg{worktreepkg.Remove(repo, w)} }
			}
			return m, nil
		}
		if m.baseSelecting {
			choices := m.baseChoices()
			switch key {
			case "esc":
				m.baseSelecting = false
			case "up", "ctrl+k":
				if m.baseSel > 0 {
					m.baseSel--
				}
			case "down", "ctrl+j":
				if m.baseSel < len(choices)-1 {
					m.baseSel++
				}
			case "enter":
				if len(choices) > 0 {
					m.base = choices[m.baseSel]
					m.baseSelecting = false
					m.field = 2
					m.err, m.errField = "", -1
				}
			default:
				if editQuery(&m.baseQuery, msg) {
					m.baseSel = 0
				}
			}
			return m, nil
		}
		if m.form {
			switch key {
			case "esc":
				m.form = false
				m.err, m.errField = "", -1
			case "tab":
				m.field = (m.field + 1) % 3
			case "shift+tab":
				m.field = (m.field + 2) % 3
			case "down", "ctrl+j":
				m.field = (m.field + 1) % 3
			case "up", "ctrl+k":
				m.field = (m.field + 2) % 3
			case "enter":
				if m.field == 0 {
					if err := worktreepkg.ValidateNewBranch(m.repo, m.branch); err != nil {
						m.err, m.errField = err.Error(), 0
						return m, nil
					}
					m.field = 1
					return m, nil
				}
				if m.field == 1 {
					m.openBaseChooser()
					return m, nil
				}
				repo, branch, base, path := m.repo, m.branch, m.base, m.destination()
				if err := worktreepkg.Validate(repo, branch, base, path); err != nil {
					m.err, m.errField = err.Error(), -1
					if worktreepkg.ValidateNewBranch(repo, branch) != nil {
						m.errField, m.field = 0, 0
					}
					return m, nil
				}
				m.busy = true
				m.err, m.errField = "", -1
				return m, func() tea.Msg { return wtCreatedMsg{path, worktreepkg.CreateLocal(repo, branch, base, path)} }
			default:
				if m.field == 0 {
					if editQuery(&m.branch, msg) {
						m.err, m.errField = "", -1
					}
				} else if m.field == 1 && (msg.Type == tea.KeyRunes || msg.Type == tea.KeySpace) {
					m.openBaseChooser()
					editQuery(&m.baseQuery, msg)
				}
			}
			return m, nil
		}
		switch key {
		case "tab", "shift+tab":
			m.target = dispatch.NextTarget(m.cfg, m.target, key == "tab")
		case "ctrl+p":
			if m.selected() == nil {
				return m, nil
			}
			if m.ctx.Block == "" {
				m.err = "no block context"
				return m, nil
			}
			m.splitMode = true
		case "esc":
			if m.filter != "" {
				m.filter = ""
				m.applyFilter()
			} else {
				m.action = "back"
				return m, tea.Quit
			}
		case "ctrl+n", "f2":
			m.form = true
			m.field = 0
			m.branch = ""
			m.err, m.errField = "", -1
		case "ctrl+x", "delete":
			if r := m.selected(); r != nil {
				if r.IsMain {
					m.err = "Cannot remove the primary worktree"
				} else {
					m.confirm = true
				}
			}
		case "up", "ctrl+k":
			if m.sel > 0 {
				m.sel--
			}
		case "down", "ctrl+j":
			if m.sel < len(m.view)-1 {
				m.sel++
			}
		case "enter":
			if r := m.selected(); r != nil {
				w := *r
				m.chosen = &w
				return m, tea.Quit
			}
		case "backspace":
			r := []rune(m.filter)
			if len(r) > 0 {
				m.filter = string(r[:len(r)-1])
				m.applyFilter()
			}
		case "ctrl+u":
			m.filter = ""
			m.applyFilter()
		default:
			if msg.Type == tea.KeyRunes || msg.Type == tea.KeySpace {
				m.filter += string(msg.Runes)
				m.applyFilter()
			}
		}
	}
	return m, nil
}

func (m *wtModel) View() string {
	if m.width < 1 || m.height < 1 {
		return ""
	}
	if m.width < 4 || m.height < 5 {
		return pickerTiny(m.width, m.height)
	}
	width := m.width - 2
	var pathLines []string
	if !m.baseSelecting && !m.form && !m.confirm && m.height >= 10 {
		if r := m.selected(); r != nil {
			// Use the full width below the list for the selected path. Very long
			// paths keep their ending and use at most three rows.
			path := pickerTail(paths.HomeRelative(r.Path), width*3)
			pathLines = strings.Split(ansi.Hardwrap(path, width, true), "\n")
			if len(pathLines) > 3 {
				pathLines = pathLines[len(pathLines)-3:]
				pathLines[0] = pickerTail("…"+pathLines[0], width)
			}
		}
	}
	footerRows := 2 + len(pathLines)
	text, dim := pickerText, pickerMuted
	line := func(s string) string { return pickerLine(s, width) }
	lines := []string{}
	footer := "^n New   ^x Remove   ↵ Open"
	if m.baseSelecting {
		lines = append(lines, pickerSearch(m.baseQuery, width, "base"), line(dim.Render("Local base branch")))
		choices := m.baseChoices()
		count := maxInt(m.height-4, 0)
		start := maxInt(m.baseSel-count+1, 0)
		for n := 0; n < count; n++ {
			i := start + n
			if i >= len(choices) {
				if n == 0 {
					lines = append(lines, line(dim.Render("No matching branches")))
				} else {
					lines = append(lines, line(""))
				}
				continue
			}
			style := text
			if i == m.baseSel {
				style = pickerSelected.Bold(true)
			}
			lines = append(lines, pickerRow(style.Render(choices[i]), width, i == m.baseSel))
		}
		footer = "↑↓ Choose   ↵ Select base   esc Back"
	} else if m.form {
		name := m.branch
		if m.field == 0 {
			name += "│"
		}
		fieldStyle := func(index int) lipgloss.Style {
			if m.field == index {
				return pickerInput
			}
			return text
		}
		lines = append(lines, line(text.Bold(true).Render("New worktree")), line(""), line(dim.Render("Branch name")), line(fieldStyle(0).Render(padRight(name, width))))
		if m.err != "" && m.errField == 0 {
			lines = append(lines, line(styErr.Render(m.err)))
		}
		lines = append(lines, line(""), line(dim.Render("Base branch")), line(fieldStyle(1).Render(padRight(m.base+"  ›", width))), line(""), line(dim.Render("Destination")))
		for _, wrapped := range strings.Split(lipgloss.NewStyle().Width(width).Render(paths.HomeRelative(m.destination())), "\n") {
			lines = append(lines, line(text.Render(wrapped)))
		}
		if m.err != "" && m.errField != 0 {
			lines = append(lines, line(styErr.Render(m.err)))
		}
		// Reserve space for the explicit submit action on short mobile panes.
		if len(lines) > m.height-4 {
			lines = lines[:maxInt(m.height-4, 0)]
		}
		button := " Create & open as " + dispatch.TargetLabel(m.target) + " "
		if m.field == 2 {
			button = pickerSelected.Bold(true).Render(button)
		} else {
			button = text.Render(button)
		}
		lines = append(lines, line(""), line(button))
		footer = "tab Next field   esc Cancel"
		if m.field == 0 {
			footer = "↵ Next   tab Next field   esc Cancel"
		}
		if m.field == 1 {
			footer = "↵ Choose base   tab Next field   esc Cancel"
		}
		if m.field == 2 {
			footer = "↵ Create & open as " + dispatch.TargetLabel(m.target) + "   ⇧tab Back   esc Cancel"
		}
	} else if m.confirm {
		r := m.selected()
		lines = append(lines, line(styErr.Bold(true).Render("Remove worktree?")), line(""))
		if r != nil {
			lines = append(lines, line(text.Render(r.Branch)), line(dim.Render(paths.HomeRelative(r.Path))))
		}
		lines = append(lines, line(""), line(dim.Render("Branch is kept. Git refuses uncommitted changes.")))
		footer = "↵ Remove   esc Cancel"
	} else {
		lines = append(lines, pickerSearch(m.filter, width, "worktree"), line(""))
		count := maxInt(m.height-2-footerRows, 0)
		start := maxInt(m.sel-count+1, 0)
		for n := 0; n < count; n++ {
			vi := start + n
			if vi >= len(m.view) {
				if n == 0 {
					lines = append(lines, line(dim.Render("No local worktrees")))
				} else {
					lines = append(lines, line(""))
				}
				continue
			}
			r := m.rows[m.view[vi]]
			lines = append(lines, pickerEntry(r.Branch, paths.HomeRelative(r.Path), width, vi == m.sel))
		}
		left := pickerMuted.Render("Open: ") + pickerAccent.Bold(true).Render(dispatch.TargetLabel(m.target))
		footer = pickerLine(left+pickerMuted.Render(" · ^p split · ^n new · ^x remove · ↵"), width)
		if width < 50 {
			footer = pickerLine(left+pickerMuted.Render(" · ↵"), width)
		}
		if m.splitMode {
			footer = pickerLine(pickerMuted.Render("Split: ")+pickerAccent.Bold(true).Render("h← j↓ k↑ l→ · esc cancel"), width)
		}
	}
	if m.err != "" && !m.form {
		footer = m.err
	}
	if m.busy {
		footer = "Working…"
	}
	// Keep the action row separate from results and form content.
	if len(lines) > m.height-footerRows {
		lines = lines[:maxInt(m.height-footerRows, 0)]
	}
	for len(lines) < m.height-footerRows {
		lines = append(lines, line(""))
	}
	lines = append(lines, pickerRule(width))
	for _, path := range pathLines {
		lines = append(lines, line(dim.Render(path)))
	}
	footer = dim.Render(footer)
	if m.confirm && m.err == "" && !m.busy {
		footer = styErr.Bold(true).Render("↵ Remove") + dim.Render("   esc Cancel")
	}
	lines = append(lines, line(footer))
	return strings.Join(lines, "\n")
}
