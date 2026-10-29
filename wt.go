package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/sahilm/fuzzy"
)

// wtRow is one entry in the worktree picker.
type wtRow struct {
	kind    string // "worktree" | "issue" | "ghost"
	wt      worktree
	item    ghItem // for issue rows
	ghostNo string // for ghost rows
	label   string
}

type wtModel struct {
	cfg     Config
	ctx     Ctx
	repo    string
	repoURL string

	rows    []wtRow
	view    []int
	filter  string
	sel     int

	loading bool // gh fetch in flight
	err     string
	confirm int // -1 none, else index into view for removal confirm

	// results
	action string // "open" | "back" | "quit" | "browser"
	chosen *wtRow

	width, height int
}

type ghLoadedMsg struct{ items []ghItem }
type ghGhostMsg struct {
	no   string
	item ghItem
	ok   bool
}

func dbg(msg string) {
	if os.Getenv("ZPICK_DEBUG") == "" {
		return
	}
	f, err := os.OpenFile("/tmp/zpick-debug.log", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err == nil {
		fmt.Fprintln(f, msg)
		f.Close()
	}
}

func runWorktrees(ctx Ctx, cfg Config, repo string) int {
	dbg("wt enter")
	if repo == "" {
		// autodetect from the origin block's cwd
		if p := blockCwd(ctx.Block); p != "" {
			dbg("wt autodetect cwd=" + p)
			repo = repoRoot(p)
		}
	}
	dbg("wt after autodetect repo=" + repo)
	if repo == "" || !isGitRepo(repo) {
		dbg("wt picking repo")
		repo = pickRepo(ctx, cfg)
		dbg("wt picked repo=" + repo)
		if repo == "" {
			return 0
		}
	}
	for {
		dbg("wt new model repo=" + repo)
		m := newWtModel(ctx, cfg, repo)
		dbg("wt before run")
		p := tea.NewProgram(m, tea.WithAltScreen())
		final, err := p.Run()
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		wm := final.(*wtModel)
		switch wm.action {
		case "back": // esc → dir flow
			return runDirs(ctx, cfg)
		case "browser":
			repo = wm.repo
			continue
		case "open":
			return wtDispatch(wm, ctx, cfg)
		default:
			return 0
		}
	}
}

func newWtModel(ctx Ctx, cfg Config, repo string) *wtModel {
	m := &wtModel{cfg: cfg, ctx: ctx, repo: repo, confirm: -1, loading: true}
	if o, n, ok := ghRepoCoords(repo); ok {
		m.repoURL = o + "/" + n
	}
	for _, w := range listWorktrees(repo) {
		label := w.Branch
		if w.IsMain {
			label = "main"
		} else if w.Short != "" {
			label = w.Short
		}
		m.rows = append(m.rows, wtRow{kind: "worktree", wt: w, label: label})
	}
	m.applyFilter()
	return m
}

// pickRepo asks for a repo when none is in context: git dirs from zoxide.
func pickRepo(ctx Ctx, cfg Config) string {
	var rows []rrow
	seen := map[string]bool{}
	for _, d := range zoxideList() {
		if _, err := os.Stat(filepath.Join(d, ".git")); err != nil {
			continue
		}
		r := repoRoot(d)
		if r != "" && !seen[r] {
			seen[r] = true
			rows = append(rows, rrow{label: basename(r), path: r})
		}
	}
	if len(rows) == 0 {
		return ""
	}
	sel := 0
	filter := ""
	view := make([]int, len(rows))
	for i := range rows {
		view[i] = i
	}
	apply := func() {
		view = view[:0]
		if filter == "" {
			for i := range rows {
				view = append(view, i)
			}
		} else {
			hs := make([]string, len(rows))
			for i, r := range rows {
				hs[i] = r.label + " " + homeRelative(r.path)
			}
			for _, mt := range fuzzy.Find(filter, hs) {
				view = append(view, mt.Index)
			}
		}
		if sel >= len(view) {
			sel = len(view) - 1
		}
		if sel < 0 {
			sel = 0
		}
	}
	m := &repoPickModel{rows: rows, view: view, sel: &sel, filter: &filter, apply: apply}
	if _, err := tea.NewProgram(m, tea.WithAltScreen()).Run(); err != nil {
		return ""
	}
	if m.chosen == "" {
		return ""
	}
	return m.chosen
}

type rrow struct{ label, path string }

type repoPickModel struct {
	rows    []rrow
	view    []int
	sel     *int
	filter  *string
	apply   func()
	chosen  string
	width   int
	height  int
}

func (m *repoPickModel) Init() tea.Cmd { return nil }

func (m *repoPickModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "esc", "q":
			return m, tea.Quit
		case "up", "ctrl+k":
			if *m.sel > 0 {
				*m.sel--
			}
		case "down", "ctrl+j":
			if *m.sel < len(m.view)-1 {
				*m.sel++
			}
		case "backspace":
			if *m.filter != "" {
				r := []rune(*m.filter)
				*m.filter = string(r[:len(r)-1])
				m.apply()
			}
		case "ctrl+u":
			*m.filter = ""
			m.apply()
		case "enter":
			if len(m.view) > 0 {
				m.chosen = m.rows[m.view[*m.sel]].path
			}
			return m, tea.Quit
		default:
			if msg.Type == tea.KeyRunes || msg.Type == tea.KeySpace {
				*m.filter += string(msg.Runes)
				m.apply()
			}
		}
	}
	return m, nil
}

func (m *repoPickModel) View() string {
	var b strings.Builder
	b.WriteString(styTitle.Render("  pick a repo") + "\n")
	maxRows := m.height - 4
	shown := 0
	for vi := 0; vi < len(m.view) && shown < maxRows; vi, shown = vi+1, shown+1 {
		r := m.rows[m.view[vi]]
		prefix, label := "  ", r.label
		if vi == *m.sel {
			prefix, label = stySel.Render("> "), stySel.Render(r.label)
		}
		b.WriteString(prefix + label + "   " + styDim.Render(homeRelative(r.path)) + "\n")
	}
	b.WriteString("\n" + styTarget.Render("  /"+*m.filter) + "\n")
	b.WriteString(styDim.Render("  enter select · esc cancel"))
	return b.String()
}

func (m *wtModel) Init() tea.Cmd {
	repo := m.repo
	return func() tea.Msg { return ghLoadedMsg{items: ghIssues(repo)} }
}

func (m *wtModel) applyFilter() {
	// strip stale ghosts first so view indices stay valid
	rows := m.rows[:0]
	for _, r := range m.rows {
		if r.kind != "ghost" {
			rows = append(rows, r)
		}
	}
	m.rows = rows

	// numeric filter → add a ghost row for creating that issue's worktree
	filter := strings.TrimSpace(m.filter)
	ghostIdx := -1
	if allDigits(filter) {
		m.rows = append(m.rows, wtRow{kind: "ghost", ghostNo: filter, label: "#" + filter + "  new worktree…"})
		ghostIdx = len(m.rows) - 1
	}

	m.view = m.view[:0]
	if m.filter == "" {
		for i := range m.rows {
			m.view = append(m.view, i)
		}
	} else {
		hs := make([]string, len(m.rows))
		for i, r := range m.rows {
			hs[i] = r.label + " " + r.wt.Path
		}
		for _, mt := range fuzzy.Find(m.filter, hs) {
			m.view = append(m.view, mt.Index)
		}
	}
	// pin the ghost row to the top when present
	if ghostIdx >= 0 {
		var rest []int
		for _, i := range m.view {
			if i != ghostIdx {
				rest = append(rest, i)
			}
		}
		m.view = append([]int{ghostIdx}, rest...)
	}
	if m.sel >= len(m.view) {
		m.sel = len(m.view) - 1
	}
	if m.sel < 0 {
		m.sel = 0
	}
}

func allDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func (m *wtModel) selected() *wtRow {
	if len(m.view) == 0 || m.sel < 0 || m.sel >= len(m.view) {
		return nil
	}
	return &m.rows[m.view[m.sel]]
}

func (m *wtModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
	case ghLoadedMsg:
		m.loading = false
		for _, it := range msg.items {
			kind := "issue"
			label := fmt.Sprintf("#%d  %s", it.Number, it.Title)
			if it.IsPR {
				label = "⎇ " + label
			}
			m.rows = append(m.rows, wtRow{kind: kind, item: it, label: label})
		}
		// sort: existing worktrees first, then number desc
		sort.SliceStable(m.rows, func(i, j int) bool {
			rank := func(r wtRow) int {
				switch r.kind {
				case "worktree":
					return 0
				case "issue", "ghost":
					return 1
				}
				return 2
			}
			return rank(m.rows[i]) < rank(m.rows[j])
		})
		m.applyFilter()
		return m, nil
	case ghGhostMsg:
		if msg.ok {
			m.err = ""
			// remember the title on the ghost row
			for i := range m.rows {
				if m.rows[i].kind == "ghost" && m.rows[i].ghostNo == msg.no {
					m.rows[i].item = msg.item
					m.rows[i].label = fmt.Sprintf("#%s  %s", msg.no, msg.item.Title)
				}
			}
		}
		return m, nil
	case tea.KeyMsg:
		if m.confirm >= 0 {
			switch msg.String() {
			case "y", "Y", "enter":
				r := &m.rows[m.view[m.confirm]]
				m.confirm = -1
				force := r.wt.Dirty
				if err := removeWorktree(m.repo, r.wt, force); err != nil {
					m.err = err.Error()
					return m, nil
				}
				// close its session if open
				if sid, ok := sessionByLabel(wtSessionName(m, r)); ok {
					rexRunQuiet("kill", sid)
				}
				// rebuild rows
				m2 := newWtModel(m.ctx, m.cfg, m.repo)
				m2.loading = m.loading
				m2.rows = stripIssues(m2.rows)
				m2.applyFilter()
				return m2, m.Init()
			case "n", "N", "esc":
				m.confirm = -1
				return m, nil
			}
			return m, nil
		}
		m.err = ""
		switch msg.String() {
		case "ctrl+c", "q":
			m.action = "quit"
			return m, tea.Quit
		case "esc":
			if m.filter != "" {
				m.filter = ""
				m.applyFilter()
				return m, nil
			}
			m.action = "back"
			return m, tea.Quit
		case "backspace":
			if m.filter != "" {
				r := []rune(m.filter)
				m.filter = string(r[:len(r)-1])
				m.applyFilter()
			}
		case "ctrl+u":
			m.filter = ""
			m.applyFilter()
		case "up", "ctrl+k":
			if m.sel > 0 {
				m.sel--
			}
		case "down", "ctrl+j":
			if m.sel < len(m.view)-1 {
				m.sel++
			}
		case "o":
			if r := m.selected(); r != nil && (r.kind == "issue") {
				ghOpenBrowser(m.repo, r.item.Number, r.item.IsPR)
			}
		case "x":
			if r := m.selected(); r != nil && r.kind == "worktree" && !r.wt.IsMain {
				m.confirm = m.sel
			} else if r != nil {
				m.err = "cannot remove"
			}
		case "enter":
			if r := m.selected(); r != nil {
				m.chosen = r
				m.action = "open"
				return m, tea.Quit
			}
		default:
			if msg.Type == tea.KeyRunes || msg.Type == tea.KeySpace {
				m.filter += string(msg.Runes)
				m.applyFilter()
				// numeric filter → fetch ghost title in background
				if allDigits(strings.TrimSpace(m.filter)) {
					no := strings.TrimSpace(m.filter)
					repo := m.repo
					return m, func() tea.Msg {
						it, ok := ghTitle(repo, atoiSafe(no))
						return ghGhostMsg{no: no, item: it, ok: ok}
					}
				}
			}
		}
	}
	return m, nil
}

func stripIssues(rows []wtRow) []wtRow {
	var out []wtRow
	for _, r := range rows {
		if r.kind == "worktree" {
			out = append(out, r)
		}
	}
	return out
}

func atoiSafe(s string) int {
	n := 0
	for _, r := range s {
		if r < '0' || r > '9' {
			return 0
		}
		n = n*10 + int(r-'0')
	}
	return n
}

// wtSessionName computes the session label for a row.
func wtSessionName(m *wtModel, r *wtRow) string {
	if r.wt.Short != "" {
		return r.wt.Short
	}
	if r.item.Number > 0 {
		return fmt.Sprintf("%s#%d", basename(m.repo), r.item.Number)
	}
	return basename(r.wt.Path)
}

// wtDispatch runs after the wt picker exits with a chosen row.
func wtDispatch(m *wtModel, ctx Ctx, cfg Config) int {
	r := m.chosen
	if r == nil {
		return 0
	}
	switch r.kind {
	case "worktree":
		if err := dispatch("session", r.wt.Path, ctx, cfg); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		// rename the session to repo#num for label-reuse
		if r.wt.Short != "" {
			if sid, ok := sessionByLabel(basename(r.wt.Path)); ok {
				if _, err := rexRun("session", "rename", sid, r.wt.Short); err != nil {
					dbg("rename wt: " + err.Error())
				} else {
					dbg("rename wt ok: " + sid + " -> " + r.wt.Short)
				}
			} else {
				dbg("rename wt: session not found: " + basename(r.wt.Path))
			}
		}
		return 0
	case "issue":
		title := r.item.Title
		wtDir, _, err := createWorktree(m.repo, fmt.Sprint(r.item.Number), title, cfg)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		if err := dispatch("session", wtDir, ctx, cfg); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		name := fmt.Sprintf("%s#%d", basename(m.repo), r.item.Number)
		if sid, ok := sessionByLabel(basename(wtDir)); ok {
			rexRunQuiet("session", "rename", sid, name)
		}
		return 0
	case "ghost":
		no := r.ghostNo
		title := r.item.Title
		if title == "" {
			// fetch synchronously once more
			if it, ok := ghTitle(m.repo, atoiSafe(no)); ok {
				title = it.Title
			} else {
				title = no
			}
		}
		wtDir, _, err := createWorktree(m.repo, no, title, cfg)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		if err := dispatch("session", wtDir, ctx, cfg); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		name := basename(m.repo) + "#" + no
		if sid, ok := sessionByLabel(basename(wtDir)); ok {
			rexRunQuiet("session", "rename", sid, name)
		}
		return 0
	}
	return 0
}

func (m *wtModel) View() string {
	var b strings.Builder
	title := "  " + basename(m.repo) + styDim.Render(" — worktrees")
	if m.repoURL != "" {
		title += styDim.Render("   "+m.repoURL)
	}
	b.WriteString(styTitle.Render(title) + "\n")

	maxRows := m.height - 4
	if maxRows < 1 {
		maxRows = 1
	}
	start := 0
	if m.sel >= maxRows {
		start = m.sel - maxRows + 1
	}
	shown := 0
	for vi := start; vi < len(m.view) && shown < maxRows; vi, shown = vi+1, shown+1 {
		r := m.rows[m.view[vi]]
		prefix, label := "  ", r.label
		if vi == m.sel {
			prefix, label = stySel.Render("> "), stySel.Render(r.label)
		}
		meta := ""
		switch r.kind {
		case "worktree":
			if r.wt.IsMain {
				meta = styDim.Render("  main")
			} else {
				if r.wt.Dirty {
					meta = styDirty.Render("  dirty ⚠")
				} else {
					meta = styDim.Render("  clean")
				}
				meta += styDim.Render("  " + homeRelative(r.wt.Path))
			}
		case "issue":
			if r.item.IsPR {
				meta = styDim.Render("  PR · enter creates")
			} else {
				meta = styDim.Render("  issue · enter creates")
			}
		case "ghost":
			meta = styDim.Render("  fetch + create")
			label = styGhost.Render(label)
		}
		line := prefix + label + meta
		if w := lipgloss.Width(line); w > m.width {
			line = truncateW(line, m.width)
		}
		b.WriteString(line + "\n")
	}

	if m.loading {
		b.WriteString(styDim.Render("  … loading issues") + "\n")
	}
	foot := "\n" + styTarget.Render("  /"+m.filter) + "\n"
	if m.confirm >= 0 {
		r := &m.rows[m.view[m.confirm]]
		what := "remove worktree " + r.wt.Branch + " and its branch?"
		if r.wt.Dirty {
			what += styDirty.Render(" (dirty — will force)")
		}
		foot = "\n" + styErr.Render("  "+what)+"\n"+styDim.Render("  y confirm · n cancel") + "\n"
	} else {
		hints := "  enter open/create · x remove · o browser · esc dirs"
		if m.err != "" {
			hints += "   " + styErr.Render(m.err)
		}
		foot += hints
	}
	b.WriteString(foot)
	return b.String()
}

var _ = filepath.Join
