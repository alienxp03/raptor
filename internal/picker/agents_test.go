package picker

import (
	"errors"
	"testing"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/rex"
	tea "github.com/charmbracelet/bubbletea"
)

func pickerAgent(id string) rex.AgentEntry {
	return rex.AgentEntry{Path: "/repo", Kind: "agent", Label: "Agent " + id, App: "pi", State: "working", AgentID: id, SessionID: "s", SessionLabel: "Work", WindowID: "w", WindowLabel: "Tab", BlockID: "pane-" + id}
}

func TestPickerDoesNotCycleRemovedViews(t *testing.T) {
	for _, key := range []tea.KeyType{tea.KeyTab, tea.KeyShiftTab} {
		m := &dirModel{hostDirs: map[string][]catalog.Directory{}}
		for range 4 {
			m.Update(tea.KeyMsg{Type: key})
			if m.viewMode != 0 || m.agentsLoading {
				t.Fatal("removed view exposed")
			}
		}
	}
}

func TestLegacySwitchNormalizesToLauncher(t *testing.T) {
	m := &dirModel{hostDirs: map[string][]catalog.Directory{}}
	m.switchView(2)
	if m.viewMode != 0 || m.agentsLoading {
		t.Fatal("legacy Agents switch must normalize to sessions")
	}
}

func TestAgentSnapshotRejectsStaleReplies(t *testing.T) {
	a, b := pickerAgent("a"), pickerAgent("b")
	m := &dirModel{agents: []rex.AgentEntry{a, b}, agentsLoaded: true}
	m.loadAgents(false)
	stale := m.agentsRequest
	m.loadAgents(true)
	latest := m.agentsRequest
	m.acceptAgents(agentsLoadedMsg{request: stale})
	m.acceptAgents(agentsLoadedMsg{request: stale, err: errors.New("stale")})
	if !m.agentsLoading || len(m.agents) != 2 || m.err != "" {
		t.Fatal("stale agent snapshot accepted")
	}
	m.acceptAgents(agentsLoadedMsg{request: latest, entries: []rex.AgentEntry{b, a}})
	if m.agentsLoading || len(m.agents) != 2 {
		t.Fatal("latest snapshot rejected")
	}
	m.acceptAgents(agentsLoadedMsg{request: latest})
	if len(m.agents) != 2 {
		t.Fatal("completed request accepted twice")
	}
}
