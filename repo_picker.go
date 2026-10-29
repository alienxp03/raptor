package main

import (
	"github.com/charmbracelet/bubbletea"
	"github.com/sahilm/fuzzy"
	"os"
	"path/filepath"
	"strings"
)

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
	apply := func() []int {
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
		return view
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
	rows   []rrow
	view   []int
	sel    *int
	filter *string
	apply  func() []int
	chosen string
	width  int
	height int
}

func (m *repoPickModel) Init() tea.Cmd { return nil }

func (m *repoPickModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "esc":
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
				m.view = m.apply()
			}
		case "ctrl+u":
			*m.filter = ""
			m.view = m.apply()
		case "enter":
			if len(m.view) > 0 {
				m.chosen = m.rows[m.view[*m.sel]].path
			}
			return m, tea.Quit
		default:
			if msg.Type == tea.KeyRunes || msg.Type == tea.KeySpace {
				*m.filter += string(msg.Runes)
				m.view = m.apply()
			}
		}
	}
	return m, nil
}

func (m *repoPickModel) View() string {
	if m.width < 1 || m.height < 1 {
		return ""
	}
	width := maxInt(m.width-2, 1)
	lines := []string{pickerSearch(*m.filter, width, "repository"), pickerLine(pickerMuted.Render("Choose repository"), width)}
	count := maxInt(m.height-4, 0)
	start := maxInt(*m.sel-count+1, 0)
	for n := 0; n < count; n++ {
		i := start + n
		if i >= len(m.view) {
			content := ""
			if n == 0 {
				content = pickerMuted.Render("No matching repositories")
			}
			lines = append(lines, pickerLine(content, width))
			continue
		}
		r := m.rows[m.view[i]]
		lines = append(lines, pickerDirectory(r.path, width, i == *m.sel))
	}
	lines = append(lines, pickerRule(width), pickerLine(pickerMuted.Render("↵ Choose repository   esc Back"), width))
	return strings.Join(lines, "\n")
}
