package picker

import (
	"testing"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
	tea "github.com/charmbracelet/bubbletea"
)

func TestLiveActivityIdleToWorkingCoalescesAndKeepsIntent(t *testing.T) {
	m := newDirModel(rex.Ctx{}, config.Default(), false, 2)
	a, b := pickerAgent("a"), pickerAgent("b")
	a.State, b.State = "idle", "idle"
	m.loadAgents(false)
	m.acceptAgents(agentsLoadedMsg{request: m.agentsRequest, entries: []rex.AgentEntry{a, b}})
	m.sel = 1
	m.filter = ""
	if m.scheduleActivityTick() != nil {
		t.Fatal("idle animation scheduled")
	}
	if m.refreshLiveActivity() == nil {
		t.Fatal("idle event did not start refresh")
	}
	id, ar, sr := m.activityLiveID, m.agentsRequest, m.launcherSessionsRequest
	for range 100 {
		if m.refreshLiveActivity() != nil {
			t.Fatal("parallel snapshot launched")
		}
	}
	if !m.activityLiveDirty {
		t.Fatal("in-flight invalidations lost")
	}
	b.State = "working"
	m.Update(activityLiveMsg{id: id, agentsRequest: ar, sessionsRequest: sr, agents: []rex.AgentEntry{b, a}})
	if m.agents[0].AgentID != a.AgentID || m.agents[1].AgentID != b.AgentID || m.sel != 1 {
		t.Fatalf("selection/order changed: %+v sel=%d", m.agents, m.sel)
	}
	if !m.activityTickPending {
		t.Fatal("idle -> working failed to start pulse")
	}
	if !m.activityLivePending || m.activityLiveDirty {
		t.Fatal("coalesced follow-up missing")
	}
	followID := m.activityLiveID
	m.Update(activityLiveMsg{id: id, agentsRequest: ar, sessionsRequest: sr})
	if m.activityLiveID != followID || !m.activityLivePending {
		t.Fatal("stale snapshot accepted")
	}
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlC})
	if !m.activityStopping {
		t.Fatal("quit did not stop activity")
	}
	m.Update(activityEventMsg{})
	if m.activityLiveID != followID {
		t.Fatal("quit started another refresh")
	}
}

func TestLiveActivityHostScopeAndLauncherSelection(t *testing.T) {
	m := newDirModel(rex.Ctx{}, config.Default(), false, 0)
	m.hostDirs = map[string][]catalog.Directory{
		rex.LocalHostLabel: {{Path: "/repo", Label: "Local"}},
		"remote":           {{Path: "/repo", Label: "Remote"}},
	}
	m.hostOrder = []string{rex.LocalHostLabel, "remote"}
	m.applyLauncher()
	m.sel = 1
	m.refreshLiveActivity()
	local := pickerAgent("local")
	local.Cwd = "/repo"
	local.State = "working"
	remote := pickerAgent("remote")
	remote.Cwd = "/repo"
	remote.State = "blocked"
	m.acceptLiveActivity(activityLiveMsg{
		id: m.activityLiveID, agentsRequest: m.agentsRequest, sessionsRequest: m.launcherSessionsRequest,
		agents: []rex.AgentEntry{local}, remoteAgents: map[string][]rex.AgentEntry{"remote": {remote}},
		groups: []rex.HostGroup{{Label: rex.LocalHostLabel, Local: true, Reachable: true}, {Label: "remote", Reachable: true}},
	})
	if selected := m.selectedLauncher(); selected == nil || selected.identity != "remote" {
		t.Fatalf("selection moved: %+v", selected)
	}
	for _, r := range m.launcher {
		if r.dir == nil {
			continue
		}
		if r.identity == "" && (!r.dir.Working || r.dir.State != "working") {
			t.Fatalf("local projection %+v", r.dir)
		}
		if r.identity == "remote" && (r.dir.Working || r.dir.State != "blocked") {
			t.Fatalf("remote used local agents %+v", r.dir)
		}
	}
}
