package picker

import (
	"testing"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/rex"
	tea "github.com/charmbracelet/bubbletea"
)

func preferredFixture() *dirModel {
	return &dirModel{hostOrder: []string{rex.LocalHostLabel}, hostDirs: map[string][]catalog.Directory{rex.LocalHostLabel: {{Label: "directory", Path: "/directory"}}}, sessions: []rex.HostGroup{{Label: rex.LocalHostLabel, Local: true, Reachable: true, Entries: []rex.SessionEntry{
		{Kind: "session", ID: "current", Label: "current", Active: true},
		{Kind: "session", ID: "recent", Label: "recent"},
		{Kind: "session", ID: "older", Label: "older"},
	}}}}
}

func TestLauncherPreferredInitialClearAndReopen(t *testing.T) {
	m := preferredFixture()
	m.applyLauncher()
	if got := launcherRowID(*m.selectedLauncher()); got != "recent" {
		t.Fatalf("initial=%q", got)
	}
	m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("older")})
	if got := launcherRowID(*m.selectedLauncher()); got != "older" {
		t.Fatalf("query=%q", got)
	}
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlU})
	if got := launcherRowID(*m.selectedLauncher()); got != "recent" {
		t.Fatalf("clear=%q", got)
	}
	m.Update(tea.KeyMsg{Type: tea.KeyUp}) // Explicitly choose current.
	m.applyLauncher()
	if got := launcherRowID(*m.selectedLauncher()); got != "current" {
		t.Fatalf("manual current lost=%q", got)
	}
	m.selectPreferredLauncher() // Presentation/reopen resets the default.
	if got := launcherRowID(*m.selectedLauncher()); got != "recent" {
		t.Fatalf("reopen=%q", got)
	}
}

func TestLauncherOnlyCurrentPrefersDirectory(t *testing.T) {
	m := preferredFixture()
	m.sessions[0].Entries = m.sessions[0].Entries[:1]
	m.applyLauncher()
	if got := launcherRowID(*m.selectedLauncher()); got != "/directory" {
		t.Fatalf("got %q", got)
	}
	delete(m.hostDirs, rex.LocalHostLabel)
	m.applyLauncher()
	if got := launcherRowID(*m.selectedLauncher()); got != "current" {
		t.Fatalf("only current=%q", got)
	}
}

func TestLauncherAsyncDefaultCanUpgradeToSession(t *testing.T) {
	m := preferredFixture()
	groups := m.sessions
	m.sessions = nil
	m.applyLauncher()
	if got := launcherRowID(*m.selectedLauncher()); got != "/directory" {
		t.Fatal(got)
	}
	m.loadLauncherSessions(false)
	m.acceptLauncherSessions(launcherSessionsMsg{request: m.launcherSessionsRequest, groups: groups})
	if got := launcherRowID(*m.selectedLauncher()); got != "recent" {
		t.Fatalf("async default=%q", got)
	}
}
