package picker

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/rex"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

func pickerSession(id, label string) rex.SessionEntry {
	return rex.SessionEntry{Kind: "session", ID: id, SessionID: id, Label: label, SessionLabel: label}
}

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

func TestSessionsFirstLoadRunsOnlyInCommand(t *testing.T) {
	log := pickerRexLog(t)
	m := &dirModel{width: 60, height: 10}
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyTab})
	if cmd == nil || !m.tabsLoading || m.tabsLoaded {
		t.Fatal("first switch must start an asynchronous load")
	}
	if _, err := os.Stat(log); !os.IsNotExist(err) {
		t.Fatal("Update ran Rex before returning its command")
	}
	if !strings.Contains(ansi.Strip(m.View()), "Loading sessions") {
		t.Fatal("first load must show loading state")
	}
	// Input stays available while the command is pending.
	m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("find")})
	msg := cmd()
	if m.tabsLoaded {
		t.Fatal("command mutated the model instead of returning a message")
	}
	m.Update(msg)
	if !m.tabsLoaded || m.tabsLoading || m.filter != "find" {
		t.Fatal("load did not keep input entered while pending")
	}
}

func TestPickerSwitchKeepsEachViewsFilterSelectionAndScroll(t *testing.T) {
	m := &dirModel{width: 60, height: 8, filter: "repo", sel: 7, tabsLoaded: true}
	for i := 0; i < 10; i++ {
		m.rows = append(m.rows, row{label: fmt.Sprintf("repo%d", i), path: fmt.Sprintf("/repo%d", i)})
		m.tabs = append(m.tabs, pickerSession(fmt.Sprint(i), fmt.Sprintf("session%d", i)))
	}
	m.applyFilter()
	beforeRepos := m.View()
	if m.switchToTabs() == nil || m.filter != "" || m.sel != 0 || len(m.tabsView) != 10 {
		t.Fatal("cached sessions must appear immediately with independent state")
	}
	m.filter, m.sel = "session", 8
	m.applyTabFilter()
	beforeSessions := m.View()
	m.switchToRepos()
	if m.filter != "repo" || m.sel != 7 || m.View() != beforeRepos {
		t.Fatal("repository filter, selection, or viewport changed")
	}
	if cmd := m.switchToTabs(); cmd != nil {
		t.Fatal("switch must not duplicate a pending refresh")
	}
	if m.filter != "session" || m.sel != 8 || m.View() != beforeSessions {
		t.Fatal("session filter, selection, or viewport changed")
	}
}

func TestSessionRefreshKeepsLatestSelectionAndInactiveViewState(t *testing.T) {
	m := &dirModel{tabs: []rex.SessionEntry{pickerSession("a", "session a"), pickerSession("b", "session b")}, tabsLoaded: true}
	m.switchToTabs()
	request := m.tabsRequest
	m.filter, m.sel = "session", 1
	m.applyTabFilter()
	m.switchToRepos()
	m.filter = "repo query"
	m.Update(tabsLoadedMsg{request: request, entries: []rex.SessionEntry{pickerSession("b", "session b"), pickerSession("a", "session a")}})
	if m.viewMode != 0 || m.filter != "repo query" || m.sel != 0 {
		t.Fatal("inactive session refresh changed the repository view")
	}
	if cmd := m.switchToTabs(); cmd == nil {
		t.Fatal("completed cache must refresh again on the next switch")
	}
	if m.filter != "session" || m.selectedEntry().ID != "b" || m.sel != 0 {
		t.Fatal("refresh lost saved query or selected identity")
	}
}

func TestSessionRefreshRejectsStaleResponsesAndKeepsCacheOnFailure(t *testing.T) {
	m := &dirModel{viewMode: 1, tabs: []rex.SessionEntry{pickerSession("a", "alpha")}, tabsLoaded: true}
	m.applyTabFilter()
	m.loadTabs(false)
	stale := m.tabsRequest
	m.loadTabs(true)
	latest := m.tabsRequest
	m.Update(tabsLoadedMsg{request: stale, entries: []rex.SessionEntry{pickerSession("stale", "stale")}})
	m.Update(tabsLoadedMsg{request: stale, err: errors.New("stale error")})
	if !m.tabsLoading || m.err != "" || m.selectedEntry().ID != "a" {
		t.Fatal("stale response changed the cache or loading state")
	}
	m.Update(tabsLoadedMsg{request: latest, err: errors.New("offline")})
	if m.tabsLoading || m.err != "offline" || m.selectedEntry().ID != "a" {
		t.Fatal("failed refresh discarded cached rows")
	}
	// Even a duplicate response for the completed request is ignored.
	m.Update(tabsLoadedMsg{request: latest, entries: nil})
	if len(m.tabs) != 1 {
		t.Fatal("duplicate response replaced cached rows")
	}
}

func TestRepositoryRefreshKeepsSelectionAndInactiveState(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	m := &dirModel{rows: []row{{label: "a", path: "/a"}, {label: "b", path: "/b"}}, sel: 1}
	m.applyFilter()
	m.refreshRepos()
	request := m.reposRequest
	m.switchToTabs()
	m.filter = "sessions query"
	m.Update(reposLoadedMsg{request: request + 1, rows: nil})
	if !m.reposLoading || len(m.rows) != 2 {
		t.Fatal("stale repository refresh was accepted")
	}
	m.Update(reposLoadedMsg{request: request, rows: []row{{label: "b", path: "/b"}, {label: "a", path: "/a"}}})
	if m.filter != "sessions query" || m.viewMode != 1 {
		t.Fatal("repository refresh changed active session state")
	}
	m.switchToRepos()
	if m.filter != "" || m.sel != 0 || m.selected().path != "/b" {
		t.Fatal("repository refresh lost the selected path")
	}
}

func TestRenameKeepsOriginalTargetAcrossRefreshAndInvalidatesOldLoad(t *testing.T) {
	log := pickerRexLog(t)
	m := &dirModel{viewMode: 1, tabsLoaded: true, tabs: []rex.SessionEntry{pickerSession("a", "alpha")}}
	m.applyTabFilter()
	m.loadTabs(false)
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlR})
	m.renameBuf = "renamed"
	m.Update(tabsLoadedMsg{request: m.tabsRequest, entries: []rex.SessionEntry{pickerSession("b", "beta")}})
	// A second background load can still be pending when rename completes.
	m.loadTabs(false)
	stale := m.tabsRequest
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil || m.renaming || m.renameEntry != nil || m.tabsRequest <= stale {
		t.Fatal("rename must exit and force a new refresh")
	}
	calls, err := os.ReadFile(log)
	if err != nil || !strings.Contains(string(calls), `session.set_label {"label":"renamed","session_id":"a"}`) {
		t.Fatalf("rename targeted a changed selection: %s (%v)", calls, err)
	}
	m.Update(tabsLoadedMsg{request: stale, entries: nil})
	if len(m.tabs) != 1 || !m.tabsLoading {
		t.Fatal("pre-mutation response replaced the cache")
	}
}

func TestCloseRefreshAndConfirmationSafety(t *testing.T) {
	for _, kind := range []string{"session", "window"} {
		t.Run(kind, func(t *testing.T) {
			log := pickerRexLog(t)
			entry := pickerSession("other", "Other")
			entry.Kind = kind
			m := &dirModel{viewMode: 1, ctx: rex.Ctx{Session: "current"}, tabsLoaded: true, tabs: []rex.SessionEntry{entry}}
			m.applyTabFilter()
			m.loadTabs(false)
			stale := m.tabsRequest
			_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyCtrlX})
			if cmd != nil || m.closeArm == "" {
				t.Fatal("first close must only arm confirmation")
			}
			_, cmd = m.Update(tea.KeyMsg{Type: tea.KeyCtrlX})
			if cmd == nil || m.closeArm != "" || m.tabsRequest <= stale {
				t.Fatal("confirmed close must invalidate pending loads and refresh")
			}
			calls, err := os.ReadFile(log)
			method := "session.destroy"
			if kind == "window" {
				method = "session.close_window"
			}
			if err != nil || !strings.Contains(string(calls), method) {
				t.Fatalf("wrong close mutation: %s (%v)", calls, err)
			}
			m.Update(tabsLoadedMsg{request: stale, entries: []rex.SessionEntry{pickerSession("stale", "Stale")}})
			m.Update(cmd())
			if len(m.tabs) != 0 || m.tabsLoading {
				t.Fatal("close refresh did not remove closed entry")
			}
		})
	}
}

func TestRefreshAndNavigationDisarmClose(t *testing.T) {
	m := &dirModel{viewMode: 1, tabsLoaded: true, tabs: []rex.SessionEntry{pickerSession("a", "A"), pickerSession("b", "B")}}
	m.applyTabFilter()
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlX})
	m.Update(tea.KeyMsg{Type: tea.KeyDown})
	if m.closeArm != "" {
		t.Fatal("navigation must cancel confirmation")
	}
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlX})
	m.loadTabs(false)
	m.Update(tabsLoadedMsg{request: m.tabsRequest, entries: []rex.SessionEntry{pickerSession("a", "A")}})
	if m.closeArm != "" {
		t.Fatal("a removed selection must cancel confirmation")
	}
	m.ctx.Session = "a"
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlX})
	if m.closeArm != "" || m.err != "cannot close this session" {
		t.Fatal("current session close guard changed")
	}
}

func TestPickerResumeRestartsPendingLoads(t *testing.T) {
	m := &dirModel{}
	m.loadTabs(false)
	m.refreshRepos()
	tabs, repos := m.tabsRequest, m.reposRequest
	if m.Init() == nil || m.tabsRequest <= tabs || m.reposRequest <= repos {
		t.Fatal("resumed picker must restart interrupted loads")
	}
}
