package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/sahilm/fuzzy"
)

type wtModel struct {
	cfg           Config
	ctx           Ctx
	repo          string
	root          string
	rows          []worktree
	view          []int
	filter        string
	sel           int
	width, height int
	err           string
	form          bool
	field         int
	branch        string
	base          string
	branches      []string
	confirm       bool
	busy          bool
	action        string
	chosen        *worktree
}
type wtCreatedMsg struct {
	path string
	err  error
}
type wtRemovedMsg struct{ err error }

func runWorktrees(ctx Ctx, cfg Config, repo string) int {
	if repo == "" {
		repo = repoRoot(blockCwd(ctx.Block))
	}
	if repo == "" || !isGitRepo(repo) {
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
		return runDirs(ctx, cfg)
	}
	if model.chosen != nil {
		if err := dispatch("session", model.chosen.Path, ctx, cfg); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
	}
	return 0
}
func newWtModel(ctx Ctx, cfg Config, repo string) *wtModel {
	m := &wtModel{ctx: ctx, cfg: cfg, repo: repo, branches: localBranches(repo)}
	m.rows = listWorktrees(repo)
	primary := repo
	if len(m.rows) > 0 {
		primary = m.rows[0].Path
	}
	m.root = filepath.Join(cfg.WorktreeRoot, basename(primary))
	m.base, _ = gitOut(repo, "branch", "--show-current")
	if m.base == "" && len(m.branches) > 0 {
		m.base = m.branches[0]
	}
	m.applyFilter()
	return m
}
func (m *wtModel) Init() tea.Cmd       { return nil }
func (m *wtModel) destination() string { return filepath.Join(m.root, worktreeFolder(m.branch)) }
func (m *wtModel) applyFilter() {
	m.view = nil
	if m.filter == "" {
		for i := range m.rows {
			m.view = append(m.view, i)
		}
	} else {
		entries := make([]string, len(m.rows))
		for i, r := range m.rows {
			entries[i] = r.Branch + " " + homeRelative(r.Path)
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
			m.rows = listWorktrees(m.repo)
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
				return m, func() tea.Msg { return wtRemovedMsg{removeWorktree(repo, w)} }
			}
			return m, nil
		}
		if m.form {
			switch key {
			case "esc":
				m.form = false
				m.err = ""
			case "tab", "shift+tab":
				m.field = 1 - m.field
			case "up", "down", "ctrl+j", "ctrl+k":
				if m.field == 1 && len(m.branches) > 0 {
					index := 0
					for i, b := range m.branches {
						if b == m.base {
							index = i
							break
						}
					}
					delta := 1
					if key == "up" || key == "ctrl+k" {
						delta = -1
					}
					m.base = m.branches[(index+delta+len(m.branches))%len(m.branches)]
				}
			case "enter":
				repo, branch, base, path := m.repo, m.branch, m.base, m.destination()
				if err := validateWorktree(repo, branch, base, path); err != nil {
					m.err = err.Error()
					return m, nil
				}
				m.busy = true
				m.err = ""
				return m, func() tea.Msg { return wtCreatedMsg{path, createLocalWorktree(repo, branch, base, path)} }
			default:
				value := &m.branch
				if m.field == 1 {
					value = &m.base
				}
				if key == "backspace" {
					r := []rune(*value)
					if len(r) > 0 {
						*value = string(r[:len(r)-1])
					}
				} else if key == "ctrl+u" {
					*value = ""
				} else if msg.Type == tea.KeyRunes || msg.Type == tea.KeySpace {
					*value += string(msg.Runes)
				}
				m.err = ""
			}
			return m, nil
		}
		switch key {
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
			m.err = ""
		case "ctrl+d", "delete":
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
	width := maxInt(m.width-4, 1)
	var bg lipgloss.TerminalColor = lipgloss.NoColor{}
	text := lipgloss.NewStyle().Foreground(lipgloss.Color("#E6E6EA")).Background(bg)
	dim := lipgloss.NewStyle().Foreground(lipgloss.Color("#88888F")).Background(bg)
	line := func(s string) string {
		return lipgloss.NewStyle().Background(bg).Render("  " + padRight(ansi.Truncate(s, width, "…"), width) + "  ")
	}
	lines := []string{}
	footer := "ctrl+n New   ctrl+d Remove   ↵ Open"
	if m.form {
		name, base := m.branch, m.base
		if m.field == 0 {
			name += "│"
		} else {
			base += "│"
		}
		folder := m.destination()
		lines = append(lines, line(text.Bold(true).Render("New worktree")), line(""), line(dim.Render("Branch")), line(text.Render(name)), line(""), line(dim.Render("Base branch  ·  ↑↓ choose")), line(text.Render(base)), line(""), line(dim.Render("Full path")))
		for _, wrapped := range strings.Split(lipgloss.NewStyle().Width(width).Render(homeRelative(folder)), "\n") {
			lines = append(lines, line(text.Render(wrapped)))
		}
		footer = "tab Field   ↵ Create & open   esc Cancel"
	} else if m.confirm {
		r := m.selected()
		lines = append(lines, line(text.Bold(true).Render("Remove worktree?")), line(""))
		if r != nil {
			lines = append(lines, line(text.Render(r.Branch)), line(dim.Render(homeRelative(r.Path))))
		}
		lines = append(lines, line(""), line(dim.Render("Branch is kept. Git refuses uncommitted changes.")))
		footer = "↵ Remove   esc Cancel"
	} else {
		lines = append(lines, line(text.Render("⌕  "+m.filter+"│")), line(""))
		count := maxInt(m.height-4, 0)
		start := maxInt(m.sel-count+1, 0)
		branchWidth := 14
		for _, r := range m.rows {
			if w := lipgloss.Width(r.Branch); w > branchWidth {
				branchWidth = w
			}
		}
		if branchWidth > width/2 {
			branchWidth = width / 2
		}
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
			rowBg := bg
			if vi == m.sel {
				rowBg = lipgloss.Color("#343438")
			}
			branchStyle := text.Background(rowBg)
			pathStyle := dim.Background(rowBg)
			branch := ansi.Truncate(r.Branch, branchWidth, "…")
			pathWidth := maxInt(width-lipgloss.Width(branch)-2, 0)
			path := ansi.Truncate(homeRelative(r.Path), pathWidth, "…")
			gap := maxInt(width-lipgloss.Width(branch)-lipgloss.Width(path), 2)
			content := branchStyle.Render(branch) + pathStyle.Render(strings.Repeat(" ", gap)+path)
			content = padRight(ansi.Truncate(content, width, "…"), width)
			lines = append(lines, lipgloss.NewStyle().Background(bg).Render("  ")+lipgloss.NewStyle().Background(rowBg).Render(content)+lipgloss.NewStyle().Background(bg).Render("  "))
		}
	}
	if m.err != "" {
		footer = m.err
	}
	if m.busy {
		footer = "Working…"
	}
	// Keep form errors in view and the action row anchored to the bottom.
	if len(lines) > m.height-1 {
		lines = lines[:maxInt(m.height-1, 0)]
	}
	for len(lines) < m.height-1 {
		lines = append(lines, line(""))
	}
	lines = append(lines, line(dim.Render(footer)))
	return strings.Join(lines, "\n")
}
