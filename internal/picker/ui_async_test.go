package picker

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"
)

func pickerRexLog(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	log := filepath.Join(dir, "calls")
	t.Setenv("PICKER_REX_LOG", log)
	t.Setenv("PATH", dir)
	script := "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$PICKER_REX_LOG\"\nif [ \"$1\" = ls ]; then\n  printf '%s\\n' '{\"sessions\":[]}'\nelse\n  printf '%s\\n' '{}'\nfi\n"
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return log
}

func launcherFixtureModel(view int) *dirModel {
	m := &dirModel{width: 60, height: 8, agentsLoaded: true, launcherLoaded: true,
		hostDirs: map[string][]catalog.Directory{}}
	rows := make([]launcherRow, 0, 10)
	for i := 0; i < 10; i++ {
		rows = append(rows, launcherRow{dir: &catalog.Directory{Label: fmt.Sprintf("repo%d", i), Path: fmt.Sprintf("/repo%d", i)}, host: rex.LocalHostLabel})
		m.agents = append(m.agents, pickerAgent(fmt.Sprint(i)))
	}
	seedLauncher(m, rows)
	m.applyAgentFilter()
	m.filter, m.sel = "repo", 7
	m.applyLauncher()
	if view == 2 {
		m.viewMode = 2
		m.filter, m.sel = "Agent", 7
		m.applyAgentFilter()
	}
	return m
}

func TestPickerSwitchKeepsEachViewsFilterSelectionAndScroll(t *testing.T) {
	m := launcherFixtureModel(0)
	beforeLauncher := m.View()
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyTab})
	if cmd == nil || m.viewMode != 2 || m.filter != "" || m.sel != 0 || len(m.agentsView) != 10 {
		t.Fatal("cached agents must appear immediately with independent state")
	}
	m.filter, m.sel = "Agent", 7
	m.applyAgentFilter()
	beforeAgents := m.View()
	m.Update(tea.KeyMsg{Type: tea.KeyTab})
	if m.viewMode != 0 || m.filter != "repo" || m.sel != 7 || ansi.Strip(m.View()) != ansi.Strip(beforeLauncher) {
		t.Fatalf("launcher changed: view=%d filter=%q sel=%d\nBEFORE:\n%s\nAFTER:\n%s", m.viewMode, m.filter, m.sel, ansi.Strip(beforeLauncher), ansi.Strip(m.View()))
	}
	m.Update(tea.KeyMsg{Type: tea.KeyTab})
	if !m.agentsLoading {
		t.Fatal("switching back to agents must revalidate in the background")
	}
	if m.filter != "Agent" || m.sel != 7 || len(m.agentsView) != 10 || m.View() != beforeAgents {
		t.Fatal("agent filter, selection, or viewport changed")
	}
}

func TestLauncherRefreshKeepsSelectionAndInactiveState(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	dir := catalog.Directory{Label: "b", Path: "/b"}
	m := &dirModel{launcher: []launcherRow{{dir: &dir, host: rex.LocalHostLabel}}, launcherView: []launcherMatch{{index: 0}}, sel: 0,
		hostDirs: map[string][]catalog.Directory{}}
	m.loadLauncherSessions(false)
	request := m.launcherSessionsRequest
	m.switchView(2)
	m.filter = "agents query"
	m.Update(launcherSessionsMsg{request: request + 1, groups: nil})
	if !m.launcherSessionsLoading {
		t.Fatal("stale launcher refresh was accepted")
	}
	groups := []rex.HostGroup{{Label: rex.LocalHostLabel, Local: true, Reachable: true, Entries: []rex.SessionEntry{
		{Kind: "session", ID: "s", SessionID: "s", Label: "work", Host: rex.LocalHostLabel},
	}}}
	m.Update(launcherSessionsMsg{request: request, groups: groups})
	if m.filter != "agents query" || m.viewMode != 2 {
		t.Fatal("launcher refresh changed active agent state")
	}
	m.switchView(0)
	if m.filter != "" || m.sel != 0 || m.launcher[0].session == nil || m.launcher[0].session.Label != "work" {
		t.Fatal("launcher refresh lost the first row")
	}
}

func TestPickerResumeRestartsPendingLoads(t *testing.T) {
	m := &dirModel{}
	m.loadAgents(false)
	m.loadLauncherSessions(false)
	agents, sessions := m.agentsRequest, m.launcherSessionsRequest
	if m.Init() == nil || m.launcherSessionsRequest <= sessions {
		t.Fatal("resumed launcher must restart interrupted loads")
	}
	agentView := &dirModel{viewMode: 2}
	agentView.loadAgents(false)
	before := agentView.agentsRequest
	if agentView.Init() == nil || agentView.agentsRequest <= before {
		t.Fatal("resumed agents view must restart interrupted loads")
	}
	_ = agents
}

func TestLauncherViewOpensFromEveryView(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	log := pickerRexLog(t)
	m := newDirModel(rex.Ctx{}, config.Default(), false, 0)
	if m.viewMode != 0 || m.launcherSessionsLoading {
		t.Fatal("direct startup must select the Sessions launcher")
	}
	m.Update(tea.WindowSizeMsg{Width: 80, Height: 10})
	if cmd := m.Init(); cmd == nil {
		t.Fatal("direct startup did not schedule async loads")
	}
	if _, err := os.Stat(log); !os.IsNotExist(err) {
		t.Fatal("startup called Rex before command execution")
	}
	for _, view := range []int{2, 0} {
		if m.viewMode == view {
			continue
		}
		if cmd := m.switchView(view); cmd == nil || m.viewMode != view {
			t.Fatalf("switching away from the launcher to view %d failed", view)
		}
		if cmd := m.switchView(0); cmd != nil && m.viewMode != 0 {
			t.Fatal("launcher switch failed")
		}
	}
	for _, view := range []int{0, 2} {
		fresh := &dirModel{viewMode: view, width: 80, height: 10, agentsLoaded: view == 2, hostDirs: map[string][]catalog.Directory{}, launcherLoaded: true}
		fresh.applyCurrentFilter()
		_, cmd := fresh.Update(tea.KeyMsg{Type: tea.KeyCtrlS})
		if fresh.viewMode != 0 {
			t.Fatalf("ctrl+s must select the launcher from view %d", view)
		}
		if view == 0 && cmd != nil {
			t.Fatal("ctrl+s inside the launcher must not reload")
		}
		if view == 2 && cmd == nil {
			t.Fatal("ctrl+s from agents must switch to the launcher")
		}
	}
}

func TestSessionMutationKeysAreInactive(t *testing.T) {
	log := pickerRexLog(t)
	for _, view := range []int{0, 2} {
		dir := catalog.Directory{Label: "repo", Path: "/repo"}
		m := &dirModel{viewMode: view, width: 80, height: 10, agents: []rex.AgentEntry{pickerAgent("a")},
			launcher: []launcherRow{{dir: &dir, host: rex.LocalHostLabel}}, launcherView: []launcherMatch{{index: 0}},
			hostDirs: map[string][]catalog.Directory{}, launcherLoaded: true}
		m.applyCurrentFilter()
		before := m.View()
		for _, key := range []tea.KeyType{tea.KeyCtrlR} {
			_, cmd := m.Update(tea.KeyMsg{Type: key})
			if cmd != nil || m.viewMode != view || m.View() != before {
				t.Fatal("removed session action changed picker")
			}
		}
	}
	if _, err := os.Stat(log); !os.IsNotExist(err) {
		t.Fatal("removed session controls called Rex")
	}
}

func TestTwoViewPillsFitAndHighlightActiveView(t *testing.T) {
	previous := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(previous) })
	for _, active := range []int{0, 2} {
		for _, width := range []int{2, 12, 16, 18, 19, 22, 42, 60, 78, 100} {
			pills := pickerPills(active, width)
			plain := ansi.Strip(pills)
			if lipgloss.Width(pills) != width+2 {
				t.Fatalf("pill width %d, want %d", lipgloss.Width(pills), width+2)
			}
			for _, stale := range []string{"Switch view", "⇥", "^a", "Repos"} {
				if strings.Contains(plain, stale) {
					t.Fatalf("unexpected pill hint %q: %q", stale, plain)
				}
			}
			if width >= 19 {
				if strings.TrimSpace(plain) != "Sessions · Agents" {
					t.Fatalf("unexpected pills: %q", plain)
				}
				name := "Sessions"
				if active == 2 {
					name = "Agents"
				}
				if !strings.Contains(pills, pickerInput.Render(" "+name+" ")) {
					t.Fatalf("active view %d is not highlighted", active)
				}
			}
		}
	}
}

func TestPickerFooterDestinations(t *testing.T) {
	for _, tc := range []struct {
		view       int
		wantWide   []string
		wantNarrow []string
		gone       []string
	}{
		{0, []string{"Open as:", "^p", "split", "⇥", "agents"}, []string{"Open as:", "^p", "split", "⇥", "agents"}, nil},
		{2, []string{"⇥", "sessions"}, []string{"⇥", "sessions"}, []string{"^x", "close", "worktrees"}},
	} {
		for _, width := range []int{60, 120} {
			want := tc.wantWide
			if width < 80 {
				want = tc.wantNarrow
			}
			m := &dirModel{viewMode: tc.view, width: width, height: 10, target: "tab",
				hostDirs: map[string][]catalog.Directory{}, launcherLoaded: true}
			seedLauncher(m, []launcherRow{{dir: &catalog.Directory{Label: "demo", Path: "/demo"}, host: rex.LocalHostLabel}})
			m.applyCurrentFilter()
			lines := strings.Split(ansi.Strip(m.View()), "\n")
			footer := lines[len(lines)-1]
			for _, want := range want {
				if !strings.Contains(footer, want) {
					t.Fatalf("view %d footer %q missing %q", tc.view, footer, want)
				}
			}
			for _, gone := range tc.gone {
				if strings.Contains(footer, gone) {
					t.Fatalf("view %d footer %q must not advertise %q", tc.view, footer, gone)
				}
			}
		}
	}
}
