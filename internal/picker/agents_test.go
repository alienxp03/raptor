package picker

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/alienxp03/raptor/internal/rex"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

func pickerAgent(id string) rex.AgentEntry {
	return rex.AgentEntry{Path: "/repo", Kind: "agent", Label: "Agent " + id, App: "pi", State: "working", AgentID: id, SessionID: "s", SessionLabel: "Work", WindowID: "w", WindowLabel: "Tab", BlockID: "pane-" + id}
}

func TestPickerCyclesThreeViewsBothDirections(t *testing.T) {
	for _, tc := range []struct {
		key  tea.KeyType
		want []int
	}{
		{tea.KeyTab, []int{1, 2, 0, 1}},
		{tea.KeyShiftTab, []int{2, 1, 0, 2}},
	} {
		m := &dirModel{}
		for _, want := range tc.want {
			m.Update(tea.KeyMsg{Type: tc.key})
			if m.viewMode != want {
				t.Fatalf("key %v: got %d, want %d", tc.key, m.viewMode, want)
			}
		}
	}
}

func TestAgentFirstLoadIsAsyncAndKeepsPendingInput(t *testing.T) {
	log := pickerRexLog(t)
	m := &dirModel{width: 70, height: 10}
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyCtrlA})
	if cmd == nil || !m.agentsLoading || m.agentsLoaded {
		t.Fatal("expected async agent load")
	}
	if _, err := os.Stat(log); !os.IsNotExist(err) {
		t.Fatal("Update called Rex")
	}
	if !strings.Contains(ansi.Strip(m.View()), "Loading agents") {
		t.Fatal("missing loading state")
	}
	m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("find")})
	msg := cmd()
	if m.agentsLoaded {
		t.Fatal("command mutated model")
	}
	m.Update(msg)
	if !m.agentsLoaded || m.agentsLoading || m.filter != "find" {
		t.Fatal("load lost input")
	}
	if !strings.Contains(ansi.Strip(m.View()), "No matching agents") {
		t.Fatal("missing empty state")
	}
}

func TestAgentsRestoreSearchSelectionAndScroll(t *testing.T) {
	m := &dirModel{width: 80, height: 8, agentsLoaded: true, filter: "repo"}
	m.rows = []row{{label: "repo", path: "/repo"}}
	for i := 0; i < 12; i++ {
		m.agents = append(m.agents, pickerAgent(fmt.Sprint(i)))
	}
	m.applyFilter()
	repos := m.View()
	if m.switchView(2) == nil || len(m.agentsView) != 12 {
		t.Fatal("cache not immediately available")
	}
	m.filter, m.sel = "Agent", 9
	m.applyAgentFilter()
	agents := m.View()
	m.switchToRepos()
	if m.View() != repos {
		t.Fatal("repos state changed")
	}
	if m.switchView(2) != nil {
		t.Fatal("duplicate pending refresh")
	}
	if m.View() != agents || m.sel != 9 || m.filter != "Agent" {
		t.Fatal("agent viewport state changed")
	}
}

func TestAgentRefreshIsolationAndIdentity(t *testing.T) {
	a, b := pickerAgent("a"), pickerAgent("b")
	// Two records in the same pane must remain distinct.
	b.BlockID = a.BlockID
	m := &dirModel{agents: []rex.AgentEntry{a, b}, agentsLoaded: true}
	m.switchView(2)
	m.filter = "Agent"
	m.applyAgentFilter()
	for position, index := range m.agentsView {
		if m.agents[index].AgentID == "b" {
			m.sel = position
		}
	}
	stale := m.agentsRequest
	m.loadAgents(true)
	latest := m.agentsRequest
	m.Update(agentsLoadedMsg{request: stale, entries: nil})
	m.Update(agentsLoadedMsg{request: stale, err: errors.New("stale")})
	if !m.agentsLoading || len(m.agents) != 2 || m.err != "" {
		t.Fatal("accepted stale response")
	}
	m.switchToRepos()
	m.filter = "repo query"
	m.Update(agentsLoadedMsg{request: latest, entries: []rex.AgentEntry{b, a}})
	if m.viewMode != 0 || m.filter != "repo query" || m.sel != 0 {
		t.Fatal("agent reply changed active repository state")
	}
	m.switchView(2)
	if m.filter != "Agent" || m.selectedAgent() == nil || m.selectedAgent().AgentID != "b" {
		t.Fatal("lost selected agent identity")
	}
	m.Update(agentsLoadedMsg{request: latest, entries: nil})
	if len(m.agents) != 2 || !m.agentsLoading {
		t.Fatal("duplicate reply changed cache")
	}
	m.Update(agentsLoadedMsg{request: m.agentsRequest, err: errors.New("offline")})
	if m.agentsLoading || m.err != "offline" || m.selectedAgent().AgentID != "b" {
		t.Fatal("failed refresh lost cache")
	}
	m.Update(agentsLoadedMsg{request: m.agentsRequest, entries: nil})
	if len(m.agents) != 2 {
		t.Fatal("completed request accepted twice")
	}
}

func TestOtherRepliesDoNotChangeAgentViewState(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	m := &dirModel{width: 80, height: 10, agents: []rex.AgentEntry{pickerAgent("a")}}
	m.refreshRepos()
	m.switchView(2)
	m.filter = "Agent"
	m.applyAgentFilter()
	before := m.View()
	m.Update(reposLoadedMsg{request: m.reposRequest, rows: []row{{label: "repo", path: "/repo"}}})
	if m.filter != "Agent" || m.viewMode != 2 || m.sel != 0 || before != m.View() {
		t.Fatal("inactive reply changed agents")
	}
}

func TestAgentRowsNavigationOnly(t *testing.T) {
	log := pickerRexLog(t)
	m := &dirModel{viewMode: 2, width: 90, height: 10, agentsLoaded: true, agents: []rex.AgentEntry{pickerAgent("a")}}
	m.applyAgentFilter()
	for _, key := range []tea.KeyType{tea.KeyCtrlX, tea.KeyCtrlX, tea.KeyCtrlR, tea.KeyCtrlG, tea.KeyCtrlN, tea.KeyCtrlT, tea.KeyCtrlP, tea.KeyCtrlO, tea.KeyF2} {
		_, cmd := m.Update(tea.KeyMsg{Type: key})
		if cmd != nil || m.picked != nil || m.next != "" || m.splitMode || m.actionMenu {
			t.Fatalf("agent action exposed: %v", key)
		}
	}
	if _, err := os.Stat(log); !os.IsNotExist(err) {
		t.Fatal("agent controls called Rex")
	}
	view := ansi.Strip(m.View())
	for _, forbidden := range []string{"close", "rename", "pin", "worktree"} {
		if strings.Contains(view, forbidden) {
			t.Fatalf("destructive hint: %s", view)
		}
	}
}

func TestAgentEnterAndNumberJumpExactRecord(t *testing.T) {
	for _, key := range []tea.KeyMsg{{Type: tea.KeyEnter}, {Type: tea.KeyRunes, Runes: []rune("2"), Alt: true}} {
		a, b := pickerAgent("a"), pickerAgent("b")
		m := &dirModel{viewMode: 2, agents: []rex.AgentEntry{a, b}, sel: 1}
		m.applyAgentFilter()
		if key.Alt {
			m.sel = 0
		}
		_, cmd := m.Update(key)
		if cmd == nil || m.jumpedAgent == nil || *m.jumpedAgent != b || m.picked != nil {
			t.Fatal("jump did not preserve exact agent entry")
		}
		m.agents[1].BlockID = "changed"
		if m.jumpedAgent.BlockID != b.BlockID {
			t.Fatal("jump result was not copied")
		}
	}
}

func TestAgentRenderingFitsViewport(t *testing.T) {
	entry := pickerAgent("a")
	entry.Label = strings.Repeat("界", 80)
	for _, width := range []int{1, 3, 4, 12, 24, 36, 60, 100} {
		for _, height := range []int{3, 5, 8, 12} {
			m := &dirModel{viewMode: 2, width: width, height: height, agentsLoaded: true, agents: []rex.AgentEntry{entry}}
			m.applyAgentFilter()
			lines := strings.Split(m.View(), "\n")
			if len(lines) != height {
				t.Fatalf("%dx%d: %d lines", width, height, len(lines))
			}
			for _, line := range lines {
				if lipgloss.Width(line) != width {
					t.Fatalf("%dx%d: line width %d", width, height, lipgloss.Width(line))
				}
			}
		}
	}
	row := ansi.Strip(pickerAgentRow(pickerAgent("a"), 1, 100, false))
	for _, text := range []string{"1 π Agent a", "•"} {
		if !strings.Contains(row, text) {
			t.Fatalf("missing %s in %s", text, row)
		}
	}
	pills := ansi.Strip(pickerPills(2, 60))
	for _, name := range []string{"Repos", "Sessions", "Agents"} {
		if !strings.Contains(pills, name) {
			t.Fatalf("missing %s pill: %q", name, pills)
		}
	}
}

func TestAgentSearchAndEscape(t *testing.T) {
	m := &dirModel{viewMode: 2, agentsLoaded: true, agents: []rex.AgentEntry{pickerAgent("a")}}
	m.applyAgentFilter()
	m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("not-found")})
	if len(m.agentsView) != 0 {
		t.Fatal("agent search did not filter")
	}
	if _, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter}); cmd != nil || m.jumpedAgent != nil {
		t.Fatal("empty search jumped")
	}
	m.Update(tea.KeyMsg{Type: tea.KeyBackspace})
	if m.filter != "not-foun" {
		t.Fatal("backspace did not edit search")
	}
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEsc})
	if cmd == nil || m.filter != "not-foun" || m.viewMode != 2 {
		t.Fatal("escape must dismiss without changing search or view")
	}
	if _, ok := cmd().(tea.QuitMsg); !ok {
		t.Fatal("escape must quit the picker")
	}
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlU})
	m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("working")})
	if len(m.agentsView) != 1 {
		t.Fatal("state search did not match")
	}
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlU})
	if m.filter != "" {
		t.Fatal("ctrl+u did not clear search")
	}
	_, cmd = m.Update(tea.KeyMsg{Type: tea.KeyEsc})
	if cmd == nil || m.viewMode != 2 {
		t.Fatal("empty escape must dismiss without returning to repos")
	}
}

func TestLauncherEscapeDismissesEveryView(t *testing.T) {
	for _, view := range []int{0, 1, 2} {
		for _, query := range []string{"", "filtered"} {
			m := &dirModel{viewMode: view, filter: query}
			_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEsc})
			if cmd == nil || m.viewMode != view || m.filter != query {
				t.Fatalf("escape changed view/search: view=%d query=%q", view, query)
			}
			if _, ok := cmd().(tea.QuitMsg); !ok {
				t.Fatalf("escape did not dismiss view=%d query=%q", view, query)
			}
		}
	}
}

func TestAgentActiveRefreshKeepsExactIdentity(t *testing.T) {
	a, b := pickerAgent("a"), pickerAgent("b")
	m := &dirModel{viewMode: 2, agents: []rex.AgentEntry{a, b}, sel: 1}
	m.applyAgentFilter()
	m.loadAgents(false)
	m.Update(agentsLoadedMsg{request: m.agentsRequest, entries: []rex.AgentEntry{b, a}})
	if m.sel != 1 || m.selectedAgent() == nil || *m.selectedAgent() != b {
		t.Fatal("active refresh lost agent identity or shortcut")
	}
}

func TestAgentContextAlwaysVisibleAndDeduplicated(t *testing.T) {
	for _, tc := range []struct{ name, session, window, want string }{
		{".dotfiles", "personal", "dotfiles", "personal"},
		{"dotfiles", "personal", ".dotfiles", "personal"},
		{".dotfiles", "personal", ".dotfiles", "personal"},
		{"agent", "personal", "dotfiles", "personal/dotfiles"},
		{"agent", "personal", "personal", "personal"},
		{"PERSONAL", "personal", "tab", "tab"},
		{"agent", "", "", "s/w"},
	} {
		t.Run(tc.name+"/"+tc.window, func(t *testing.T) {
			e := pickerAgent("a")
			e.Label, e.SessionLabel, e.WindowLabel = tc.name, tc.session, tc.window
			if got := pickerAgentContext(e, e.Label); got != tc.want {
				t.Fatalf("context %q, want %q", got, tc.want)
			}
			selected := ansi.Strip(pickerAgentRow(e, 1, 80, true))
			if !strings.HasSuffix(strings.TrimSpace(selected), tc.want) {
				t.Fatalf("selected context not at right: %q", selected)
			}
			unselected := ansi.Strip(pickerAgentRow(e, 1, 80, false))
			if !strings.HasSuffix(strings.TrimSpace(unselected), tc.want) {
				t.Fatalf("unselected context not at right: %q", unselected)
			}
		})
	}
}

func TestAgentCompactGlyphsAndStatus(t *testing.T) {
	glyphs := map[string]string{"pi": "π", "codex": "◎", "claude": "✳", "unknown": "◇"}
	for app, glyph := range glyphs {
		for _, state := range []string{"idle", "working", "blocked", "done", ""} {
			e := pickerAgent("a")
			e.App, e.State = app, state
			row := ansi.Strip(pickerAgentRow(e, 2, 80, false))
			if !strings.Contains(row, "2 "+glyph+" Agent a") {
				t.Fatalf("missing shortcut/glyph/name: %q", row)
			}
			for _, forbidden := range []string{app, "idle", "working", "blocked", "done", "●"} {
				if strings.Contains(row, forbidden) {
					t.Fatalf("unexpected %q: %q", forbidden, row)
				}
			}
			if strings.Contains(row, "•") != (state == "working") || strings.Contains(row, "!") != (state == "blocked") {
				t.Fatalf("wrong state indicator: %q", row)
			}
			e.Active = true
			if active := ansi.Strip(pickerAgentRow(e, 2, 80, false)); active != row {
				t.Fatalf("active pane changed status: %q", active)
			}
		}
	}
}

func TestAgentCompactRowsAllWidths(t *testing.T) {
	e := pickerAgent("a")
	e.Label = strings.Repeat("界e\u0301🦅", 30)
	e.SessionLabel, e.WindowLabel = strings.Repeat("個人", 30), "設定🦅"
	for width := 0; width <= 160; width++ {
		for _, selected := range []bool{false, true} {
			for _, state := range []string{"idle", "working", "blocked"} {
				e.State = state
				row := pickerAgentRow(e, 1, width, selected)
				if !utf8.ValidString(row) || lipgloss.Width(row) != width+2 || strings.Contains(row, "\n") {
					t.Fatalf("width %d selected %v state %s: width %d, %q", width, selected, state, lipgloss.Width(row), row)
				}
			}
		}
	}
}

func TestAgentRefreshPreservesOrderAndUpdatesRecords(t *testing.T) {
	a, b, c, d := pickerAgent("a"), pickerAgent("b"), pickerAgent("c"), pickerAgent("d")
	// Multiple identities in one pane must retain their separate shortcuts.
	b.BlockID = a.BlockID
	m := &dirModel{viewMode: 2, agents: []rex.AgentEntry{a, b, c}, sel: 1}
	m.applyAgentFilter()
	b.State, b.Label = "blocked", "Updated agent"
	m.loadAgents(false)
	m.Update(agentsLoadedMsg{request: m.agentsRequest, entries: []rex.AgentEntry{d, c, b, a}})
	if len(m.agents) != 3 {
		t.Fatal("new record entered the open snapshot")
	}
	for i, want := range []rex.AgentEntry{a, b, c} {
		if m.agents[i] != want || m.agentsView[i] != i {
			t.Fatalf("refresh changed shortcut %d: %+v", i+1, m.agents)
		}
	}
	if m.sel != 1 || *m.selectedAgent() != b {
		t.Fatal("refresh lost selection or new state")
	}
	m.loadAgents(false)
	m.Update(agentsLoadedMsg{request: m.agentsRequest, entries: []rex.AgentEntry{d, c, b}})
	if len(m.agents) != 2 || m.agents[0] != b || m.agents[1] != c || *m.selectedAgent() != b {
		t.Fatal("removal lost relative order or identity")
	}
	fresh := &dirModel{viewMode: 2}
	fresh.loadAgents(false)
	fresh.Update(agentsLoadedMsg{request: fresh.agentsRequest, entries: []rex.AgentEntry{d, c, b}})
	if fresh.agents[0] != d || fresh.agents[1] != c || fresh.agents[2] != b {
		t.Fatal("fresh picker did not use backend order")
	}
}

func TestAgentQueryPreservesIncomingOrder(t *testing.T) {
	a, b := pickerAgent("a"), pickerAgent("b")
	a.Label, b.Label = "fzzzozzzobar", "foo"
	m := &dirModel{viewMode: 2, agents: []rex.AgentEntry{a, b}, filter: "foo"}
	m.applyAgentFilter()
	if len(m.agentsView) != 2 || m.agentsView[0] != 0 {
		t.Fatalf("query changed incoming order: %v", m.agentsView)
	}
	m.loadAgents(false)
	m.Update(agentsLoadedMsg{request: m.agentsRequest, entries: []rex.AgentEntry{b, a}})
	if m.agents[0] != a || m.agentsView[0] != 0 || m.selectedAgent().AgentID != "a" {
		t.Fatal("refresh changed query snapshot order")
	}
}

func TestAgentResumeRestartsPendingLoad(t *testing.T) {
	m := &dirModel{}
	m.loadAgents(false)
	request := m.agentsRequest
	if m.Init() == nil || m.agentsRequest <= request {
		t.Fatal("resume did not restart pending agent load")
	}
}
