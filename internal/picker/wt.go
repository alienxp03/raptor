package picker

import (
	"fmt"
	"os"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/dispatch"
	"github.com/alienxp03/raptor/internal/paths"
	"github.com/alienxp03/raptor/internal/pullrequest"
	"github.com/alienxp03/raptor/internal/rex"
	worktreepkg "github.com/alienxp03/raptor/internal/worktree"
)

type worktree = worktreepkg.Worktree

type wtModel struct {
	cfg             config.Config
	ctx             rex.Ctx
	repo            string
	root            string
	rows            []worktree
	view            []int
	filter          string
	sel             int
	width, height   int
	err             string
	form            bool
	closeOnCancel   bool // Direct form launch has no parent list.
	loading         bool // Repository metadata loads after the first form render.
	field           int  // branch, base chooser, open target, create button
	errField        int  // -1 for a general error
	baseSelecting   bool
	baseQuery       string
	baseSel         int
	branch          string
	branchEdited    bool // Includes clearing the input while metadata loads.
	branchPrefilled bool
	suggestedBranch string
	base            string
	branches        []string
	confirm         bool
	busy            bool
	splitMode       bool
	target          string
	action          string
	chosen          *worktree
}
type wtCreatedMsg struct {
	path string
	err  error
}
type wtRemovedMsg struct{ err error }
type wtLoadedMsg struct {
	repo string
	info catalog.Worktrees
	err  error
}

const (
	returnToDirectories = -1
	returnToAgents      = -2
)

func RunCreateWorktree(ctx rex.Ctx, cfg config.Config, repo string) int {
	return runWorktreePicker(ctx, cfg, repo, false, true)
}

func RunWorktrees(ctx rex.Ctx, cfg config.Config, repo string) int {
	return runWorktreeFlow(ctx, cfg, repo, false)
}

func runWorktreeFlow(ctx rex.Ctx, cfg config.Config, repo string, fromDirectories bool) int {
	return runWorktreePicker(ctx, cfg, repo, fromDirectories, false)
}

func runWorktreePicker(ctx rex.Ctx, cfg config.Config, repo string, fromDirectories, create bool) int {
	var m *wtModel
	if create {
		m = newCreateModel(ctx, cfg, repo, !fromDirectories)
	} else {
		repo, _ = catalog.ResolveRepo(ctx, repo)
		if repo == "" {
			repo = pickRepo(ctx, cfg)
			if repo == "" {
				return 0
			}
		}
		m = newWtModel(ctx, cfg, repo)
	}
	for {
		final, err := tea.NewProgram(m, tea.WithAltScreen()).Run()
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		model := final.(*wtModel)
		if model.action == "choose-repo" {
			repo = pickRepo(ctx, cfg)
			if repo == "" {
				return 0
			}
			if create {
				m = model.continueCreate(repo)
			} else {
				m = newWtModel(ctx, cfg, repo)
			}
			continue
		}
		if model.action == "agents" {
			if fromDirectories {
				return returnToAgents
			}
			return RunAgents(ctx, cfg)
		}
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
}
func newWtModel(ctx rex.Ctx, cfg config.Config, repo string) *wtModel {
	info := catalog.ListWorktrees(repo, cfg)
	m := &wtModel{ctx: ctx, cfg: cfg, repo: repo, branches: info.Branches, rows: info.Items,
		root: info.Root, base: info.BaseBranch, suggestedBranch: info.SuggestedBranch, errField: -1, target: cfg.Enter}
	m.applyFilter()
	return m
}

// Use the same target order and context requirements as the native backend.
func (m *wtModel) formTargets() config.Config {
	cfg := m.cfg
	cfg.Targets = cfg.AvailableTargets(m.ctx.Block != "")
	return cfg
}

func newCreateModel(ctx rex.Ctx, cfg config.Config, repo string, closeOnCancel bool) *wtModel {
	return &wtModel{ctx: ctx, cfg: cfg, repo: repo, form: true, loading: true,
		closeOnCancel: closeOnCancel, errField: -1, target: cfg.Enter}
}

func (m *wtModel) continueCreate(repo string) *wtModel {
	next := newCreateModel(m.ctx, m.cfg, repo, m.closeOnCancel)
	if m.branchEdited {
		next.branch, next.branchEdited = m.branch, true
	}
	return next
}

func (m *wtModel) Init() tea.Cmd {
	if !m.loading {
		return m.ctx.TitleCommand()
	}
	ctx, cfg, repo := m.ctx, m.cfg, m.repo
	load := func() tea.Msg {
		root, err := catalog.ResolveRepo(ctx, repo)
		if err != nil || root == "" {
			return wtLoadedMsg{err: err}
		}
		return wtLoadedMsg{repo: root, info: catalog.ListWorktrees(root, cfg)}
	}
	return tea.Batch(m.ctx.TitleCommand(), load)
}
func (m *wtModel) destination() string {
	path, _ := worktreepkg.PreviewPath(m.repo, m.branch)
	return path
}
func (m *wtModel) baseLabel() string {
	if m.loading {
		return "Loading…"
	}
	return m.base + " ›"
}
func (m *wtModel) destinationLabel() string {
	if m.loading {
		return "Loading repository…"
	}
	if m.branch == "" {
		return "Worktrunk configured path"
	}
	path, err := worktreepkg.PreviewPath(m.repo, m.branch)
	if err != nil {
		return err.Error()
	}
	return paths.HomeRelative(path)
}
func (m *wtModel) applyFilter() {
	m.view = catalog.FilterWorktrees(m.rows, m.filter)
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
	return catalog.FilterBranches(m.branches, m.baseQuery)
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
	case wtLoadedMsg:
		m.loading = false
		if msg.err != nil {
			m.err = msg.err.Error()
			return m, nil
		}
		if msg.repo == "" {
			m.action = "choose-repo"
			return m, tea.Quit
		}
		m.repo, m.root = msg.repo, msg.info.Root
		m.rows, m.branches, m.base = msg.info.Items, msg.info.Branches, msg.info.BaseBranch
		m.suggestedBranch = msg.info.SuggestedBranch
		if m.form && !m.branchPrefilled {
			if !m.branchEdited {
				m.branch = m.suggestedBranch
			}
			m.branchPrefilled = true
			m.suggestedBranch = ""
		}
		m.applyFilter()
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
		if m.loading {
			if key == "esc" {
				if !m.closeOnCancel {
					m.action = "back"
				}
				return m, tea.Quit
			}
			// Branch input is safe before metadata arrives; Git actions are not.
			if m.field == 0 && editQuery(&m.branch, msg) {
				m.branchEdited = true
			}
			return m, nil
		}
		if m.splitMode {
			switch key {
			case "esc", "ctrl+p":
				m.splitMode = false
			case "j", "down":
				m.target = "pane_below"
			case "l", "right":
				m.target = "pane_right"
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
		if key == "ctrl+a" && !m.form {
			m.action = "agents"
			return m, tea.Quit
		}
		if m.form {
			switch key {
			case "ctrl+o":
				m.target = dispatch.NextTarget(m.formTargets(), m.target, true)
			case "esc":
				if m.closeOnCancel {
					return m, tea.Quit
				}
				m.form = false
				m.err, m.errField = "", -1
			case "tab", "down", "ctrl+j":
				m.field = (m.field + 1) % 4
			case "shift+tab", "up", "ctrl+k":
				m.field = (m.field + 3) % 4
			case "left", "right":
				if m.field == 2 {
					m.target = dispatch.NextTarget(m.formTargets(), m.target, key == "right")
				}
			case "enter":
				if m.field == 2 {
					m.field = 3
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
				return m, func() tea.Msg {
					setup, err := pullrequest.PreflightLocal(repo)
					if err != nil {
						return wtCreatedMsg{path, err}
					}
					if err := worktreepkg.CreateLocal(repo, branch, base, path); err != nil {
						return wtCreatedMsg{path, err}
					}
					if err := setup.Register(path, branch, base); err != nil {
						return wtCreatedMsg{path, fmt.Errorf("worktree preserved at %s; could not save setup: %w", path, err)}
					}
					return wtCreatedMsg{path, nil}
				}
			default:
				if m.field == 0 {
					if editQuery(&m.branch, msg) {
						m.branchEdited = true
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
		case "tab", "shift+tab", "ctrl+o":
			m.target = dispatch.NextTarget(m.formTargets(), m.target, key != "shift+tab")
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
			m.branch = m.suggestedBranch
			m.suggestedBranch = ""
			if m.branch == "" {
				m.branch, _ = worktreepkg.SuggestTaskName(m.repo, m.cfg)
			}
			m.branchEdited, m.branchPrefilled = false, true
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
	formButton := ""
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
		fieldLine := func(index int, label, value string) string {
			style := text
			if m.field == index {
				style = pickerAccent.Bold(true)
			}
			return line(dim.Render(padRight(label, 12)) + style.Render(value))
		}
		repoLabel := paths.HomeRelative(m.repo)
		if m.loading && m.repo == "" {
			repoLabel = "Loading…"
		}
		pathLine := func(label, value string) string {
			return line(dim.Render(padRight(label, 12) + pickerTail(value, maxInt(width-12, 0))))
		}
		lines = append(lines, line(text.Bold(true).Render("New worktree")), pathLine("Repo", repoLabel), line(""),
			fieldLine(0, "Branch", name),
			fieldLine(1, "Base", m.baseLabel()),
			fieldLine(2, "Open in", dispatch.TargetLabel(m.target)))
		if m.err != "" {
			lines = append(lines, line(styErr.Render(m.err)))
		}
		// Keep the fields and submit action visible; shorten only the preview.
		if len(lines)+1 <= m.height-4 {
			if len(lines)+2 <= m.height-4 {
				lines = append(lines, line(""))
			}
			lines = append(lines, pathLine("Destination", m.destinationLabel()))
		}
		formButton = pickerAccent.Render("Create")
		if m.loading {
			formButton = dim.Render("Create")
		} else if m.field == 3 {
			formButton = pickerAccent.Bold(true).Render("▸ Create")
		}
		footerRows++
		footer = "Tab next · ^o target · ↵ create/select · esc back"
		if width < 40 {
			footer = "tab · ^o · ↵ · esc"
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
		selectedRows := 1
		if selected := m.selected(); selected != nil {
			selectedRows = len(pickerWorktreeBranch(selected.Branch, width, true))
		}
		start := maxInt(m.sel-count+selectedRows, 0)
		for vi := start; len(lines) < m.height-footerRows; vi++ {
			if vi >= len(m.view) {
				if vi == start {
					lines = append(lines, line(dim.Render("No local worktrees")))
				} else {
					lines = append(lines, line(""))
				}
				continue
			}
			r := m.rows[m.view[vi]]
			for _, branchLine := range pickerWorktreeBranch(r.Branch, width, vi == m.sel) {
				if len(lines) < m.height-footerRows {
					lines = append(lines, branchLine)
				}
			}
		}
		left := pickerMuted.Render("Open: ") + pickerAccent.Bold(true).Render(dispatch.TargetLabel(m.target)) + pickerMuted.Render(" ^o")
		footer = pickerLine(left+pickerMuted.Render(" · ^p split · ^n new · ^x remove · ↵"), width)
		if width < 50 {
			footer = pickerLine(left+pickerMuted.Render(" · ↵"), width)
		}
		if m.splitMode {
			footer = pickerLine(pickerMuted.Render("Split: ")+pickerAccent.Bold(true).Render("j↓ l→ · esc cancel"), width)
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
	if formButton != "" {
		lines = append(lines, line(strings.Repeat(" ", maxInt(width-lipgloss.Width(formButton), 0))+formButton))
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
