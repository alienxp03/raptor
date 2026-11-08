package picker

import (
	"os"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

func TestAgentsDirectStartup(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	log := pickerRexLog(t)
	m := newDirModel(rex.Ctx{}, config.Config{Enter: "tab"}, false, 2)
	if m.viewMode != 2 || m.launcher || m.target != "tab" {
		t.Fatal("direct Agents startup lost picker options")
	}
	m.Update(tea.WindowSizeMsg{Width: 70, Height: 10})
	if !strings.Contains(ansi.Strip(m.View()), "Loading agents") {
		t.Fatal("missing direct Agents loading state")
	}
	if m.Init() == nil || !m.agentsLoading || m.agentsRequest != 1 {
		t.Fatal("direct startup did not schedule async agent discovery")
	}
	if _, err := os.Stat(log); !os.IsNotExist(err) {
		t.Fatal("startup called Rex before command execution")
	}
	m.Update(agentsLoadedMsg{request: 1, entries: []rex.AgentEntry{pickerAgent("a")}})
	if m.agentsLoading || !m.agentsLoaded || m.selectedAgent() == nil {
		t.Fatal("direct startup did not accept agent results")
	}
	m.Update(tea.KeyMsg{Type: tea.KeyTab})
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyCtrlA})
	if cmd == nil || m.selectedAgent() == nil || !m.agentsLoading {
		t.Fatal("return to Agents must show cache while refreshing")
	}
}

func TestCtrlASelectsAgentsFromEveryView(t *testing.T) {
	log := pickerRexLog(t)
	for _, view := range []int{0, 1, 2} {
		m := &dirModel{
			viewMode: view, filter: "source", agentsLoaded: true,
			agents: []rex.AgentEntry{pickerAgent("a"), pickerAgent("b")},
		}
		m.viewStates[2] = dirViewState{filter: "Agent", sel: 1}
		if view == 2 {
			m.filter, m.sel = "Agent", 1
			m.applyAgentFilter()
		}
		_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyCtrlA})
		if m.viewMode != 2 || m.filter != "Agent" || m.sel != 1 || m.selectedAgent() == nil {
			t.Fatalf("view %d: lost Agents search or selection: mode=%d filter=%q sel=%d entry=%+v", view, m.viewMode, m.filter, m.sel, m.selectedAgent())
		}
		if view != 2 && (cmd == nil || !m.agentsLoading || m.viewStates[view].filter != "source") {
			t.Fatalf("view %d: missing async refresh or source state", view)
		}
		if view == 2 && cmd != nil {
			t.Fatal("Ctrl+A in Agents must be a no-op")
		}
		request := m.agentsRequest
		for i := 0; i < 3; i++ {
			_, cmd = m.Update(tea.KeyMsg{Type: tea.KeyCtrlA})
			if cmd != nil || m.agentsRequest != request || m.filter != "Agent" || m.sel != 1 {
				t.Fatal("repeated Ctrl+A changed state or duplicated discovery")
			}
		}
	}
	if _, err := os.Stat(log); !os.IsNotExist(err) {
		t.Fatal("Ctrl+A blocked Update with a Rex call")
	}
}

func TestCtrlAOpensAgentsFromWorktreeList(t *testing.T) {
	m := &wtModel{}
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyCtrlA})
	if m.action != "agents" || cmd == nil {
		t.Fatal("worktree list did not route to Agents")
	}
	if _, ok := cmd().(tea.QuitMsg); !ok {
		t.Fatal("worktree picker must finish before resuming Agents")
	}
	for _, modal := range []wtModel{{form: true}, {loading: true}, {confirm: true}, {baseSelecting: true}, {splitMode: true}, {busy: true}} {
		modal.Update(tea.KeyMsg{Type: tea.KeyCtrlA})
		if modal.action == "agents" {
			t.Fatal("Agents shortcut interrupted a worktree form or modal")
		}
	}
}

func TestWorktreeFlowResumesExistingAgentsView(t *testing.T) {
	m := &dirModel{viewMode: 0, filter: "repo", next: "wt", nextRepo: "/repo", actionMenu: true,
		agentsLoaded: true, agents: []rex.AgentEntry{pickerAgent("a")}}
	m.viewStates[2] = dirViewState{filter: "Agent", sel: 0}
	if !m.resumeWorktreeFlow(returnToAgents) || m.viewMode != 2 || m.filter != "Agent" || m.next != "" || m.nextRepo != "" || m.actionMenu {
		t.Fatal("worktree flow did not resume the existing Agents view")
	}
	if m.viewStates[0].filter != "repo" || !m.agentsLoading || m.selectedAgent() == nil {
		t.Fatal("resuming lost cached Agents or the Repos search")
	}
	request := m.agentsRequest
	if m.Init() == nil || m.agentsRequest <= request {
		t.Fatal("resumed picker did not restart its pending Agents fetch")
	}
	if m.resumeWorktreeFlow(0) {
		t.Fatal("completed worktree operation must not reopen the picker")
	}
}

func TestCtrlADoesNotInterruptModalInput(t *testing.T) {
	m := &dirModel{actionMenu: true}
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlA})
	if m.viewMode != 0 || m.agentsLoading || !m.actionMenu {
		t.Fatal("Ctrl+A interrupted modal input")
	}
}
