package picker

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/rex"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

// pickerRexLogSessions installs a fake rex that logs every call and answers a
// small case table: hosts.list advertises "hades", client.inspect/list provide
// the app client "app-1" labelled "mac", and ls returns the given payload.
// When fail is nonempty, matching calls exit 1 with an error on stderr.
func pickerRexLogSessions(t *testing.T, ls string, fail string) string {
	t.Helper()
	dir := t.TempDir()
	log := filepath.Join(dir, "calls")
	t.Setenv("PICKER_REX_LOG", log)
	t.Setenv("PATH", dir)
	failCase := ""
	if fail != "" {
		failCase = "*" + fail + "*)\n  echo boom >&2\n  exit 1 ;;\n"
	}
	script := "#!/bin/sh\n" +
		"printf '%s\\n' \"$*\" >> \"$PICKER_REX_LOG\"\n" +
		"case \"$*\" in\n" +
		failCase +
		"*hosts.list*)\n  printf '%s\\n' '{\"hosts\":[{\"id\":\"hades\",\"label\":\"hades\"}]}' ;;\n" +
		"*client.inspect*)\n  printf '%s\\n' '{\"client\":{\"client_id\":\"cli-1\",\"info\":{\"kind\":\"app\",\"label\":\"mac\"}}}' ;;\n" +
		"*client.list*)\n  printf '%s\\n' '{\"clients\":[{\"client_id\":\"app-1\",\"info\":{\"kind\":\"app\",\"label\":\"mac\"}}]}' ;;\n" +
		"*\"new --json\"*)\n  printf '%s\\n' '{\"session_id\":\"new-1\"}' ;;\n" +
		"*\"ls --json\"*)\n  printf '%s\\n' '" + ls + "' ;;\n" +
		"*)\n  printf '%s\\n' '{}' ;;\n" +
		"esac\n"
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return log
}

func pickerRexCalls(t *testing.T, log string) []string {
	t.Helper()
	data, err := os.ReadFile(log)
	if err != nil {
		t.Fatalf("fake rex was not called: %v", err)
	}
	return strings.Split(strings.TrimSpace(string(data)), "\n")
}

func sessionsTestModel(ctx rex.Ctx) *dirModel {
	m := &dirModel{ctx: ctx, viewMode: 1, width: 80, height: 14, sessionsLoaded: true, sessions: []rex.HostGroup{
		{Label: rex.LocalHostLabel, Local: true, Reachable: true, Entries: []rex.SessionEntry{
			{Kind: "session", ID: "s1", SessionID: "s1", Label: "work", Host: rex.LocalHostLabel},
			{Kind: "session", ID: "mine", SessionID: "mine", Label: "mine", Host: rex.LocalHostLabel, Active: true},
		}},
		{Label: "hades", Reachable: true, Entries: []rex.SessionEntry{
			{Kind: "session", ID: "r1", SessionID: "r1", Label: "ops", Host: "hades", State: "working", Working: true},
		}},
	}}
	m.applySessionFilter()
	return m
}

func TestSessionsFirstLoadRunsOnlyInCommand(t *testing.T) {
	log := pickerRexLog(t)
	m := &dirModel{width: 60, height: 10}
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyCtrlS})
	if cmd == nil || m.viewMode != 1 || !m.sessionsLoading || m.sessionsLoaded {
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
	if m.sessionsLoaded {
		t.Fatal("command mutated the model instead of returning a message")
	}
	m.Update(msg)
	if !m.sessionsLoaded || m.sessionsLoading || m.filter != "find" {
		t.Fatal("load did not keep input entered while pending")
	}
	if !strings.Contains(ansi.Strip(m.View()), "No matching sessions") {
		t.Fatal("empty state missing after load")
	}
}

func TestSessionsLoadGroupsAndRender(t *testing.T) {
	log := pickerRexLogSessions(t, `{"sessions":[{"session_id":"s1","label":"work"},{"session_id":"s2","label":"play"}]}`, "")
	m := &dirModel{ctx: rex.Ctx{Session: "s1"}, width: 80, height: 14}
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyCtrlS})
	if cmd == nil || !m.sessionsLoading {
		t.Fatal("ctrl+s must start the sessions view asynchronously")
	}
	if _, err := os.Stat(log); !os.IsNotExist(err) {
		t.Fatal("Update called Rex")
	}
	msg := cmd()
	if len(m.sessions) != 0 {
		t.Fatal("command mutated the model")
	}
	m.Update(msg)
	if !m.sessionsLoaded || m.sessionsLoading || len(m.sessions) != 2 {
		t.Fatal("host groups did not load")
	}
	// Two sessions plus the "+ New session" row on each of the two hosts.
	if len(m.sessionsView) != 6 {
		t.Fatalf("unexpected selectable rows: %d", len(m.sessionsView))
	}
	view := ansi.Strip(m.View())
	for _, want := range []string{
		"▸ This Mac", "▸ hades", "1 ● work", "2 play", "3 + New session", "4 work", "5 play", "6 + New session", "^x close", "⇥ agents",
	} {
		if !strings.Contains(view, want) {
			t.Fatalf("sessions view missing %q: %q", want, view)
		}
	}
	if strings.Contains(view, "Loading") {
		t.Fatal("loaded view still shows the loading state")
	}
}

func TestSessionsUnreachableGroupKeepsHeaderAndError(t *testing.T) {
	m := &dirModel{viewMode: 1, width: 80, height: 14, sessionsLoaded: true, sessions: []rex.HostGroup{
		{Label: rex.LocalHostLabel, Local: true, Reachable: true, Entries: []rex.SessionEntry{
			{Kind: "session", ID: "s1", SessionID: "s1", Label: "work", Host: rex.LocalHostLabel},
		}},
		{Label: "hades", Reachable: false, Error: "ssh: connection refused"},
	}}
	m.applySessionFilter()
	if len(m.sessionsView) != 2 {
		t.Fatalf("unreachable groups must contribute no selectable rows: %d", len(m.sessionsView))
	}
	view := ansi.Strip(m.View())
	for _, want := range []string{"▸ hades", "unreachable"} {
		if !strings.Contains(view, want) {
			t.Fatalf("sessions view missing %q: %q", want, view)
		}
	}
	if strings.Count(view, "+ New session") != 1 {
		t.Fatalf("unreachable groups must not offer creating sessions: %q", view)
	}
}

func TestSessionsFilterHidesEmptyGroupsAndKeepsNewRow(t *testing.T) {
	m := sessionsTestModel(rex.Ctx{})
	m.filter = "ops"
	m.applySessionFilter()
	view := ansi.Strip(m.View())
	if strings.Contains(view, "This Mac") || strings.Contains(view, "work") {
		t.Fatalf("groups without matches must disappear: %q", view)
	}
	if !strings.Contains(view, "ops") || strings.Count(view, "+ New session") != 1 {
		t.Fatalf("matched group must keep its session and new row: %q", view)
	}
	m.filter = ""
	m.applySessionFilter()
	if count := strings.Count(ansi.Strip(m.View()), "+ New session"); count != 2 {
		t.Fatalf("empty query must restore both new-session rows, got %d", count)
	}
}

func TestSessionsEnterJumpsAndCtrlXGuardsOrigin(t *testing.T) {
	s1 := rex.SessionEntry{Kind: "session", ID: "s1", SessionID: "s1", Label: "work", Host: rex.LocalHostLabel}
	ops := rex.SessionEntry{Kind: "session", ID: "r1", SessionID: "r1", Label: "ops", Host: "hades", State: "working", Working: true}
	m := sessionsTestModel(rex.Ctx{Session: "mine"})
	if entry := m.selectedSessionEntry(); entry == nil || entry.ID != "s1" {
		t.Fatalf("unexpected first selectable row: %+v", m.sessionsView)
	}
	// Enter on the first session quits with an exact copy.
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil || m.jumpSession == nil || *m.jumpSession != s1 || m.picked != nil {
		t.Fatal("enter did not record the selected session")
	}
	if _, ok := cmd().(tea.QuitMsg); !ok {
		t.Fatal("enter must quit the picker")
	}
	// ctrl+x refuses to close the origin session on the local host.
	m.jumpSession = nil
	m.sel = 1
	_, cmd = m.Update(tea.KeyMsg{Type: tea.KeyCtrlX})
	if cmd != nil || m.closeSession != nil || m.err == "" {
		t.Fatal("origin session close must be refused locally")
	}
	// ctrl+x on a remote row records the close result and quits.
	m.err = ""
	m.sel = 3
	_, cmd = m.Update(tea.KeyMsg{Type: tea.KeyCtrlX})
	if cmd == nil || m.closeSession == nil || *m.closeSession != ops {
		t.Fatal("remote close did not record the entry")
	}
	if _, ok := cmd().(tea.QuitMsg); !ok {
		t.Fatal("close must quit the picker")
	}
}

func TestSessionsResultPerformsRexCalls(t *testing.T) {
	log := pickerRexLogSessions(t, `{"sessions":[{"session_id":"old","label":"old"}]}`, "")
	ctx := rex.Ctx{Client: "cli-1"}
	// Local jump selects through the app client.
	dm := &dirModel{ctx: ctx, jumpSession: &rex.SessionEntry{Kind: "session", ID: "s1", SessionID: "s1", SessionLabel: "work", Host: rex.LocalHostLabel}}
	if code, done := finishSessionsResult(ctx, dm); !done || code != 0 {
		t.Fatalf("local jump failed: code=%d done=%v", code, done)
	}
	// Remote jump targets the host.
	dm = &dirModel{ctx: ctx, jumpSession: &rex.SessionEntry{Kind: "session", ID: "r1", SessionID: "r1", SessionLabel: "ops", Host: "hades"}}
	if code, done := finishSessionsResult(ctx, dm); !done || code != 0 {
		t.Fatalf("remote jump failed: code=%d done=%v", code, done)
	}
	// Remote close destroys the session on its host.
	dm = &dirModel{ctx: ctx, closeSession: &rex.SessionEntry{Kind: "session", ID: "r9", SessionID: "r9", Host: "hades"}}
	if code, done := finishSessionsResult(ctx, dm); !done || code != 0 {
		t.Fatalf("remote close failed: code=%d done=%v", code, done)
	}
	// Create reuses-or-creates the session and selects it.
	dm = &dirModel{ctx: ctx, createSession: &sessionCreate{Host: "hades", Dir: "/repo/demo"}}
	if code, done := finishSessionsResult(ctx, dm); !done || code != 0 {
		t.Fatalf("create failed: code=%d done=%v", code, done)
	}
	calls := strings.Join(pickerRexCalls(t, log), "\n")
	for _, want := range []string{
		"-C cli-1 do session.select session_id=s1",
		"-S hades -C app-1 do session.select session_id=r1",
		"-S hades api call session.destroy",
		"-S hades new --json -c /repo/demo demo",
		"-S hades -C app-1 do session.select session_id=new-1",
	} {
		if !strings.Contains(calls, want) {
			t.Fatalf("missing rex call %q in %q", want, calls)
		}
	}
}

func TestSessionsResultReportsFailures(t *testing.T) {
	log := pickerRexLogSessions(t, `{"sessions":[]}`, "session.destroy")
	dm := &dirModel{closeSession: &rex.SessionEntry{Kind: "session", ID: "r9", SessionID: "r9", Host: "hades"}}
	if code, done := finishSessionsResult(rex.Ctx{Client: "cli-1"}, dm); !done || code != 1 {
		t.Fatalf("failed close must exit 1: code=%d done=%v", code, done)
	}
	if calls := pickerRexCalls(t, log); len(calls) == 0 {
		t.Fatal("failed close never reached rex")
	}
}

func TestSessionsCreateFlowInsideSameProgram(t *testing.T) {
	log := pickerRexLogSessions(t, `{"sessions":[]}`, "")
	dir, _ := os.LookupEnv("PATH")
	// Local zoxide answers the directory listing for "This Mac".
	if err := os.WriteFile(filepath.Join(dir, "zoxide"), []byte("#!/bin/sh\nprintf '%s\\n' /repo/demo /repo/other\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	m := sessionsTestModel(rex.Ctx{Client: "cli-1"})
	m.sel = 2 // "+ New session" row of This Mac
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil || m.createSession == nil || m.createSession.Host != rex.LocalHostLabel || m.createSession.Dir != "" {
		t.Fatal("new-session row did not open the create flow")
	}
	if _, err := os.Stat(log); !os.IsNotExist(err) {
		t.Fatal("Update called Rex or zoxide")
	}
	view := ansi.Strip(m.View())
	for _, want := range []string{"directory ❯", "New session on This Mac", "Loading directories"} {
		if !strings.Contains(view, want) {
			t.Fatalf("create view missing %q: %q", want, view)
		}
	}
	// Escape returns to the sessions list inside the same program.
	if _, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEsc}); cmd != nil || m.createSession != nil || m.viewMode != 1 {
		t.Fatal("escape did not return to the sessions list")
	}
	if !strings.Contains(ansi.Strip(m.View()), "+ New session") {
		t.Fatal("sessions list not restored after escape")
	}
	// Re-enter and confirm the demo directory.
	m.sel = 2
	_, cmd = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	msg := cmd()
	if len(m.createSession.dirs) != 0 {
		t.Fatal("command mutated the model")
	}
	m.Update(msg)
	if m.createSession.loading || len(m.createSession.view) != 2 {
		t.Fatalf("directory list did not load: %+v", m.createSession.dirs)
	}
	m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("demo")})
	if m.createSession.filter != "demo" || len(m.createSession.view) != 1 {
		t.Fatal("create search did not filter directories")
	}
	_, cmd = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if m.createSession == nil || m.createSession.Dir != "/repo/demo" || cmd == nil {
		t.Fatalf("enter did not pick the directory: %+v", m.createSession)
	}
	if _, ok := cmd().(tea.QuitMsg); !ok {
		t.Fatal("confirmed create must quit the picker")
	}
	if code, done := finishSessionsResult(rex.Ctx{Client: "cli-1"}, m); !done || code != 0 {
		t.Fatalf("create result failed: code=%d done=%v", code, done)
	}
	calls := strings.Join(pickerRexCalls(t, log), "\n")
	for _, want := range []string{"new --json -c /repo/demo demo", "do session.select session_id=new-1"} {
		if !strings.Contains(calls, want) {
			t.Fatalf("missing rex call %q in %q", want, calls)
		}
	}
}

func TestSessionsCreateFlowLoadsRemoteDirectoriesOverSSH(t *testing.T) {
	pickerRexLogSessions(t, `{"sessions":[]}`, "")
	dir, _ := os.LookupEnv("PATH")
	sshLog := filepath.Join(dir, "ssh-calls")
	ssh := "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"" + sshLog + "\"\ncase \"$*\" in\n*zoxide*) printf '%s\\n' /remote/demo ;;\n*) exit 1 ;;\nesac\n"
	if err := os.WriteFile(filepath.Join(dir, "ssh"), []byte(ssh), 0o755); err != nil {
		t.Fatal(err)
	}
	m := &dirModel{viewMode: 1, width: 80, height: 14, sessionsLoaded: true, sessions: []rex.HostGroup{
		{Label: "hades", Reachable: true, Entries: []rex.SessionEntry{}},
	}}
	m.applySessionFilter()
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil || m.createSession == nil || m.createSession.Host != "hades" {
		t.Fatal("remote new-session row did not open the create flow")
	}
	m.Update(cmd())
	if len(m.createSession.view) != 1 || m.createSession.dirs[0].Path != "/remote/demo" {
		t.Fatalf("remote directories did not load: %+v", m.createSession.dirs)
	}
	if _, err := os.Stat(sshLog); err != nil {
		t.Fatalf("remote directory list must go over ssh: %v", err)
	}
}
