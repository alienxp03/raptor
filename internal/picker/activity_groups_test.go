package picker

import (
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/rex"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

func TestAgentGroupSpacingFitsWithoutChangingOrdinals(t *testing.T) {
	a, b, c := pickerAgent("a"), pickerAgent("b"), pickerAgent("c")
	a.State, b.State, c.State = "blocked", "working", "idle"
	m := &dirModel{viewMode: 2, agents: []rex.AgentEntry{a, b, c}}
	m.applyAgentFilter()
	rows := m.agentDisplayRows(8)
	if len(rows) != 8 || !rows[2].spacer || !rows[5].spacer {
		t.Fatalf("missing group gaps: %+v", rows)
	}
	for i, line := range []int{1, 4, 7} {
		if rows[line].position != i || rows[line].spacer {
			t.Fatalf("spacing changed agent ordinal: %+v", rows)
		}
	}
	for _, row := range m.agentDisplayRows(6) {
		if row.spacer {
			t.Fatal("tight viewport should keep agent rows instead of gaps")
		}
	}
}

func TestAgentGroupHeadersAndOrdinals(t *testing.T) {
	a, b, c := pickerAgent("a"), pickerAgent("b"), pickerAgent("c")
	a.State, b.State, c.State = "blocked", "working", "idle"
	m := &dirModel{viewMode: 2, width: 80, height: 12, agents: []rex.AgentEntry{a, b, c}}
	m.applyAgentFilter()
	rows := m.agentDisplayRows(6)
	for i, label := range []string{"Blocked", "Working", "Idle"} {
		if rows[i*2].header != label || rows[i*2+1].position != i {
			t.Fatalf("rows: %+v", rows)
		}
	}
	view := ansi.Strip(m.View())
	for _, want := range []string{" Blocked", " Working", " Idle", "1 π Agent a", "2 π Agent b", "3 π Agent c"} {
		if !strings.Contains(view, want) {
			t.Fatalf("missing %q: %s", want, view)
		}
	}
	m.Update(tea.KeyMsg{Type: tea.KeyDown})
	if m.sel != 1 || m.selectedAgent().AgentID != "b" {
		t.Fatal("header was selected")
	}
	m.agents = []rex.AgentEntry{b}
	m.agentGroups = nil
	m.applyAgentFilter()
	view = ansi.Strip(m.View())
	if strings.Contains(view, "Blocked") || strings.Contains(view, "Idle") {
		t.Fatal("empty group rendered")
	}
}

func TestAgentGroupedScrollKeepsSelectionAndBoundaryHeader(t *testing.T) {
	m := &dirModel{viewMode: 2, width: 42, height: 8}
	for i := 0; i < 12; i++ {
		e := pickerAgent(string(rune('a' + i)))
		if i < 4 {
			e.State = "blocked"
		} else if i > 7 {
			e.State = "idle"
		}
		m.agents = append(m.agents, e)
	}
	m.applyAgentFilter()
	for height := 1; height <= 8; height++ {
		for sel := range m.agents {
			m.sel = sel
			rows := m.agentDisplayRows(height)
			if len(rows) > height {
				t.Fatal("headers exceeded viewport")
			}
			found := false
			for _, r := range rows {
				if r.header == "" && r.position == sel {
					found = true
				}
			}
			if !found {
				t.Fatalf("selection hidden: height=%d sel=%d rows=%+v", height, sel, rows)
			}
			if height >= 2 && rows[0].header == "" {
				t.Fatalf("missing boundary header: %+v", rows)
			}
		}
	}
	for _, width := range []int{12, 24, 40, 80} {
		m.width = width
		for _, line := range strings.Split(m.View(), "\n") {
			if lipgloss.Width(line) > width {
				t.Fatalf("width %d: %q", width, line)
			}
		}
	}
}

func TestAgentSnapshotMembershipAndSearchIntent(t *testing.T) {
	a, b := pickerAgent("a"), pickerAgent("b")
	a.State = "blocked"
	m := &dirModel{viewMode: 2}
	m.loadAgents(false)
	m.Update(agentsLoadedMsg{request: m.agentsRequest, entries: []rex.AgentEntry{a, b}})
	a.State = "idle"
	c := pickerAgent("c")
	m.loadAgents(false)
	m.Update(agentsLoadedMsg{request: m.agentsRequest, entries: []rex.AgentEntry{c, b, a}})
	if len(m.agents) != 2 || m.agents[0].State != "idle" || m.agentDisplayRows(8)[0].header != "Blocked" {
		t.Fatal("snapshot group changed or new record admitted")
	}
	m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("Agent")})
	if len(m.agents) != 3 || m.agentDisplayRows(8)[0].header != "Working" || m.agents[2].AgentID != "a" {
		t.Fatal("new search did not regroup current snapshot")
	}
}

func TestEmptyAgentSnapshotDefersNewAndFailedLoadCanRetry(t *testing.T) {
	m := &dirModel{}
	m.loadAgents(false)
	m.Update(agentsLoadedMsg{request: m.agentsRequest, err: errors.New("offline")})
	m.loadAgents(false)
	m.Update(agentsLoadedMsg{request: m.agentsRequest, entries: []rex.AgentEntry{pickerAgent("a")}})
	if len(m.agents) != 1 {
		t.Fatal("failed first load prevented retry")
	}
	m = &dirModel{}
	m.loadAgents(false)
	m.Update(agentsLoadedMsg{request: m.agentsRequest})
	m.loadAgents(false)
	m.Update(agentsLoadedMsg{request: m.agentsRequest, entries: []rex.AgentEntry{pickerAgent("a")}})
	if len(m.agents) != 0 {
		t.Fatal("empty snapshot admitted new record")
	}
}

func TestAgentAgeAndContext(t *testing.T) {
	now := time.Now()
	for _, tc := range []struct {
		age  time.Duration
		want string
	}{{0, "now"}, {2 * time.Minute, "2m"}, {time.Hour, "1h"}, {48 * time.Hour, "2d"}} {
		updated := now.Add(-tc.age)
		if got := agentAge(&updated, now); got != tc.want {
			t.Fatalf("age %v: %s", tc.age, got)
		}
	}
	if agentAge(nil, now) != "" || agentAge(&time.Time{}, now) != "" {
		t.Fatal("unknown time rendered")
	}
	e := pickerAgent("a")
	updated := now.Add(-2 * time.Minute)
	e.UpdatedAt = &updated
	for _, width := range []int{24, 35, 80} {
		text := ansi.Strip(pickerAgentRow(e, 1, width, false))
		if !strings.Contains(text, "Work/Tab") {
			t.Fatalf("context hidden at %d: %q", width, text)
		}
		if width == 80 && !strings.Contains(text, "2m") {
			t.Fatal("age omitted with space available")
		}
	}
}

func TestActivityProjectionAllTabs(t *testing.T) {
	e := pickerAgent("a")
	e.Cwd = "/repo/sub"
	blocked := e
	blocked.AgentID = "b"
	blocked.State = "blocked"
	m := &dirModel{launcher: []launcherRow{
		{dir: &catalog.Directory{Label: "repo", Path: "/repo"}, host: rex.LocalHostLabel},
		{dir: &catalog.Directory{Label: "other", Path: "/other"}, host: rex.LocalHostLabel},
		{dir: &catalog.Directory{Label: "sub", Path: "/repo/sub"}, host: rex.LocalHostLabel},
	}}
	// Keep coverage of shared session metadata without a Sessions picker view.
	tabs := []rex.SessionEntry{{Kind: "session", ID: "s", SessionID: "s"}, {Kind: "window", ID: "w", SessionID: "s"}, {Kind: "window", ID: "else", SessionID: "s"}}
	m.projectActivity([]rex.AgentEntry{e, blocked})
	rex.ApplySessionActivity(tabs, []rex.AgentEntry{e, blocked})
	if m.launcher[0].dir.State != "" || m.launcher[0].dir.Working || m.launcher[1].dir.Working || m.launcher[2].dir.State != "blocked" || !m.launcher[2].dir.Working {
		t.Fatalf("launcher dirs: %+v", m.launcher)
	}
	for _, i := range []int{0, 1} {
		if tabs[i].State != "blocked" || !tabs[i].Working {
			t.Fatalf("sessions: %+v", tabs)
		}
	}
	if tabs[2].Working {
		t.Fatal("unrelated tab marked working")
	}
	for _, indicator := range []string{activityIndicator(m.launcher[2].dir.State, m.launcher[2].dir.Working, 0), activityIndicator(tabs[0].State, tabs[0].Working, 0)} {
		plain := ansi.Strip(indicator)
		if !strings.HasPrefix(plain, " ! ") || !strings.ContainsAny(plain, "•∙·") {
			t.Fatal("mixed activity must show Blocked and Working together")
		}
	}
	m.projectActivity(nil)
	rex.ApplySessionActivity(tabs, nil)
	if m.hasWorkingData() || m.launcher[0].dir.State != "" || tabs[0].State != "" {
		t.Fatal("activity not cleared")
	}
}

func TestWorkingIndicatorHasThreeDots(t *testing.T) {
	t.Setenv("NO_COLOR", "1")
	for _, motion := range []string{"", "1"} {
		t.Setenv("REX_REDUCED_MOTION", motion)
		for frame := 0; frame < 4; frame++ {
			indicator := activityIndicator("working", true, frame)
			if len([]rune(strings.TrimSpace(indicator))) != 3 || lipgloss.Width(indicator) != 4 {
				t.Fatalf("working indicator must keep three dots at fixed width: %q", indicator)
			}
		}
	}
	if got := activityIndicator("idle", false, 0); got != "" {
		t.Fatalf("idle indicator = %q", got)
	}
}

func TestActivityTickStartsStopsAndNoIdleTimer(t *testing.T) {
	t.Setenv("REX_REDUCED_MOTION", "")
	for _, view := range []int{0, 2} {
		m := &dirModel{viewMode: view}
		if m.scheduleActivityTick() != nil {
			t.Fatal("idle timer")
		}
		switch view {
		case 0:
			m.launcher = []launcherRow{{dir: &catalog.Directory{Label: "repo", Path: "/repo"}, host: rex.LocalHostLabel}}
			m.launcher[0].dir.Working = true
		case 2:
			m.agents = []rex.AgentEntry{pickerAgent("a")}
		}
		if m.scheduleActivityTick() == nil || !m.activityTickPending {
			t.Fatal("working timer not started")
		}
		if m.scheduleActivityTick() != nil {
			t.Fatal("duplicate timer")
		}
		before := m.activityFrame
		_, cmd := m.Update(activityTickMsg{m.activityTickID})
		if cmd == nil || m.activityFrame == before {
			t.Fatal("working timer did not continue")
		}
		m.launcher = nil
		m.agents = nil
		_, cmd = m.Update(activityTickMsg{m.activityTickID})
		if cmd != nil || m.activityTickPending {
			t.Fatal("idle timer continued")
		}
	}
	m := &dirModel{agents: []rex.AgentEntry{pickerAgent("a")}}
	m.scheduleActivityTick()
	m.Update(tea.KeyMsg{Type: tea.KeyEsc})
	if _, cmd := m.Update(activityTickMsg{m.activityTickID}); cmd != nil {
		t.Fatal("timer continued after dismiss")
	}
	for _, value := range []string{"1", "true", "yes"} {
		t.Setenv("REX_REDUCED_MOTION", value)
		m = &dirModel{agents: []rex.AgentEntry{pickerAgent("a")}}
		if m.scheduleActivityTick() != nil || activityIndicator("working", true, 0) != activityIndicator("working", true, 1) {
			t.Fatal("reduced motion ignored")
		}
	}
	t.Setenv("REX_REDUCED_MOTION", "")
	t.Setenv("NO_COLOR", "1")
	if activityIndicator("blocked", false, 0) != " !" || activityIndicator("working", true, 0) == activityIndicator("working", true, 1) {
		t.Fatal("NO_COLOR should remove color, not motion")
	}
	first, next := activityIndicator("blocked", true, 0), activityIndicator("blocked", true, 1)
	if !strings.HasPrefix(first, " ! ") || !strings.HasPrefix(next, " ! ") || first == next {
		t.Fatal("mixed activity must keep Blocked static and animate Working")
	}
}
