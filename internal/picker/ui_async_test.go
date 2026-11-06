package picker

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

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

func TestPickerSwitchKeepsEachViewsFilterSelectionAndScroll(t *testing.T) {
	for _, key := range []tea.KeyType{tea.KeyTab, tea.KeyShiftTab} {
		m := &dirModel{width: 60, height: 8, filter: "repo", sel: 7, agentsLoaded: true}
		for i := 0; i < 10; i++ {
			m.rows = append(m.rows, row{label: fmt.Sprintf("repo%d", i), path: fmt.Sprintf("/repo%d", i)})
			m.agents = append(m.agents, pickerAgent(fmt.Sprint(i)))
		}
		m.applyFilter()
		beforeRepos := m.View()
		_, cmd := m.Update(tea.KeyMsg{Type: key})
		if cmd == nil || m.viewMode != 2 || m.filter != "" || m.sel != 0 || len(m.agentsView) != 10 {
			t.Fatal("cached agents must appear immediately with independent state")
		}
		m.filter, m.sel = "Agent", 8
		m.applyAgentFilter()
		beforeAgents := m.View()
		m.Update(tea.KeyMsg{Type: key})
		if m.viewMode != 0 || m.filter != "repo" || m.sel != 7 || m.View() != beforeRepos {
			t.Fatal("repository filter, selection, or viewport changed")
		}
		_, cmd = m.Update(tea.KeyMsg{Type: key})
		if cmd != nil {
			t.Fatal("switch must not duplicate a pending refresh")
		}
		if m.viewMode != 2 || m.filter != "Agent" || m.sel != 8 || m.View() != beforeAgents {
			t.Fatal("agent filter, selection, or viewport changed")
		}
	}
}

func TestRepositoryRefreshKeepsSelectionAndInactiveState(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	m := &dirModel{rows: []row{{label: "a", path: "/a"}, {label: "b", path: "/b"}}, sel: 1}
	m.applyFilter()
	m.refreshRepos()
	request := m.reposRequest
	m.switchView(2)
	m.filter = "agents query"
	m.Update(reposLoadedMsg{request: request + 1, rows: nil})
	if !m.reposLoading || len(m.rows) != 2 {
		t.Fatal("stale repository refresh was accepted")
	}
	m.Update(reposLoadedMsg{request: request, rows: []row{{label: "b", path: "/b"}, {label: "a", path: "/a"}}})
	if m.filter != "agents query" || m.viewMode != 2 {
		t.Fatal("repository refresh changed active agent state")
	}
	m.switchToRepos()
	if m.filter != "" || m.sel != 0 || m.selected().path != "/b" {
		t.Fatal("repository refresh lost the selected path")
	}
}

func TestPickerResumeRestartsPendingLoads(t *testing.T) {
	m := &dirModel{}
	m.loadAgents(false)
	m.refreshRepos()
	agents, repos := m.agentsRequest, m.reposRequest
	if m.Init() == nil || m.agentsRequest <= agents || m.reposRequest <= repos {
		t.Fatal("resumed picker must restart interrupted loads")
	}
}

func TestRemovedSessionViewCannotBeOpened(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	pickerRexLog(t)
	m := newDirModel(rex.Ctx{}, config.Default(), false, 1)
	if m.viewMode != 0 {
		t.Fatal("legacy startup must use Repos")
	}
	m.Update(tea.WindowSizeMsg{Width: 80, Height: 10})
	for _, view := range []int{0, 2} {
		m.switchView(view)
		before := m.View()
		if cmd := m.switchView(1); cmd != nil || m.viewMode != view || m.View() != before {
			t.Fatal("removed view accepted by switchView")
		}
	}
}

func TestSessionMutationKeysAreInactive(t *testing.T) {
	log := pickerRexLog(t)
	for _, view := range []int{0, 2} {
		m := &dirModel{viewMode: view, width: 80, height: 10, rows: []row{{label: "repo", path: "/repo"}}, agents: []rex.AgentEntry{pickerAgent("a")}}
		m.applyCurrentFilter()
		before := m.View()
		for _, key := range []tea.KeyType{tea.KeyCtrlR, tea.KeyCtrlX, tea.KeyCtrlX} {
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
		for _, width := range []int{2, 12, 24, 42, 44, 60, 78, 100} {
			pills := pickerPills(active, width)
			plain := ansi.Strip(pills)
			if lipgloss.Width(pills) != width+2 {
				t.Fatalf("pill width %d, want %d", lipgloss.Width(pills), width+2)
			}
			for _, removed := range []string{"Sessions", "Switch view", "⇥", "^a"} {
				if strings.Contains(plain, removed) {
					t.Fatalf("unexpected pill hint %q: %q", removed, plain)
				}
			}
			if width >= 24 {
				if strings.TrimSpace(plain) != "Repos · Agents" {
					t.Fatalf("unexpected pills: %q", plain)
				}
				name := "Repos"
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

func TestTwoViewFooterDestinations(t *testing.T) {
	for _, view := range []int{0, 2} {
		for _, width := range []int{60, 120} {
			m := &dirModel{viewMode: view, width: width, height: 10, target: "tab"}
			lines := strings.Split(ansi.Strip(m.View()), "\n")
			footer := lines[len(lines)-1]
			want := "⇥ agents"
			if view == 2 {
				want = "⇥ repos"
			}
			if !strings.Contains(footer, want) || strings.Contains(strings.ToLower(m.View()), "sessions") {
				t.Fatalf("view %d: incorrect footer %q", view, footer)
			}
		}
	}
}
