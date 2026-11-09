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
	worktreepkg "github.com/alienxp03/raptor/internal/worktree"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

// pickerRexLogSessions installs a fake rex that logs every call and answers a
// fixed session listing plus the client-label lookups the launcher's
// cross-host switch needs. It returns the log path.
func pickerRexLogSessions(t *testing.T, ls string, fail string) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	log := filepath.Join(dir, "calls")
	t.Setenv("REX_TEST_LOG", log)
	t.Setenv("REX_TEST_LS", ls)
	t.Setenv("REX_TEST_FAIL", fail)
	script := `#!/bin/sh
printf '%s\n' "$*" >> "$REX_TEST_LOG"
case "$*" in
  'api call hosts.list') printf '%s\n' "$REX_TEST_HOSTS" ;;
  'ls --json') [ -n "$REX_TEST_FAIL" ] && exit 1 ; printf '%s\n' "$REX_TEST_LS" ;;
  '-S hades --timeout 3s ls --json') echo '{"sessions":[{"session_id":"r1","label":"wispy-brook"}]}' ;;
  '-S hades --timeout 4s do'*) echo '{"sessions":[]}' ;;
  'do'*) echo '{"sessions":[]}' ;;
  'api call client.list {"kinds":["app"]}') echo '{"clients":[{"client_id":"client:local","info":{"kind":"app","label":"azuanz"}}]}' ;;
  '-S hades api call client.list {"kinds":["app"]}') echo '{"clients":[{"client_id":"client:remote-app","info":{"kind":"app","label":"azuanz"}}]}' ;;
  'capture -s '* | '-S hades --timeout 2s capture'*) echo 'screen line one' ;;
esac
`
	if os.Getenv("REX_TEST_HOSTS") == "" {
		t.Setenv("REX_TEST_HOSTS", `{"hosts":[]}`)
	}
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return log
}

// injectDirs registers (when needed) and delivers one host's directory
// reply without executing the real fetch.
func injectDirs(m *dirModel, host string, items []catalog.Directory) {
	if _, pending := m.launcherDirsPending[host]; !pending {
		m.loadLauncherDirs(host, true)
	}
	m.Update(launcherDirsMsg{request: m.launcherDirsPending[host], host: host, items: items})
}

// fakeZoxide installs a fake zoxide listing the given directories.
func fakeZoxide(t *testing.T, dirs ...string) {
	t.Helper()
	bin := t.TempDir()
	payload := "#!/bin/sh\n"
	for _, d := range dirs {
		payload += fmt.Sprintf("printf '%%s\\n' %q\n", d)
	}
	if err := os.WriteFile(filepath.Join(bin, "zoxide"), []byte(payload), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func launcherModel() *dirModel {
	return &dirModel{width: 80, height: 14, hostDirs: map[string][]catalog.Directory{}, cfg: config.Default(), target: "session"}
}

// seedLauncher routes directory rows through the model's own composition so
// applyLauncher keeps them (it always rebuilds from hostDirs).
func seedLauncher(m *dirModel, rows []launcherRow) {
	dirs := make([]catalog.Directory, 0, len(rows))
	for _, r := range rows {
		if r.dir != nil {
			dirs = append(dirs, *r.dir)
		}
	}
	m.hostDirs = map[string][]catalog.Directory{rex.LocalHostLabel: dirs}
	m.hostOrder = []string{rex.LocalHostLabel}
	m.launcherLoaded = true
	m.applyLauncher()
}

// launcherLabels returns the visible row labels in order.
func launcherLabels(m *dirModel) []string {
	labels := make([]string, 0, len(m.launcherView))
	for _, match := range m.launcherView {
		if r := m.launcher[match.index]; r.session != nil {
			labels = append(labels, r.session.Label)
		} else {
			labels = append(labels, r.dir.Label)
		}
	}
	return labels
}

func localGroups(entries ...rex.SessionEntry) []rex.HostGroup {
	return []rex.HostGroup{{Label: rex.LocalHostLabel, Local: true, Reachable: true, Entries: entries}}
}

func entry(id, label, host string, active bool) rex.SessionEntry {
	return rex.SessionEntry{Kind: "session", ID: id, Path: id, SessionID: id, Label: label, SessionLabel: label, Host: host, Active: active}
}

func TestLauncherFirstLoadIsAsyncAndKeepsInput(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	log := pickerRexLogSessions(t, `{"sessions":[{"session_id":"s1","label":"work"}]}`, "")
	m := &dirModel{width: 80, height: 14, hostDirs: map[string][]catalog.Directory{}, ctx: rex.Ctx{Session: "origin"}, viewMode: 2, agentsLoaded: true}
	m.applyCurrentFilter()
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyTab})
	if cmd == nil || !m.launcherSessionsLoading || m.viewMode != 0 {
		t.Fatal("switching to the launcher must start the async load")
	}
	if _, err := os.Stat(log); !os.IsNotExist(err) {
		t.Fatal("Update ran Rex before returning its command")
	}
	if !strings.Contains(ansi.Strip(m.View()), "Loading sessions") {
		t.Fatal("first load must show the loading state")
	}
	m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("find")})
	m.Update(cmd())
	if !m.launcherLoaded || m.launcherSessionsLoading || m.filter != "find" {
		t.Fatal("load did not keep input entered while pending")
	}
	if len(m.launcherView) != 0 {
		t.Fatal("filter must hide non-matching rows")
	}
	if !strings.Contains(ansi.Strip(m.View()), "No matching sessions or directories") {
		t.Fatal("missing empty state")
	}
}

func TestLauncherRowOrderAndBadges(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	pickerRexLogSessions(t,
		`{"sessions":[{"session_id":"other","label":"other"},{"session_id":"mine","label":"mine","active":true}]}`, "")
	t.Setenv("REX_TEST_HOSTS", `{"hosts":[{"id":"h:1","label":"hades"}]}`)
	fakeZoxide(t, "/workspace/zeta", "/workspace/alpha")
	m := launcherModel()
	m.ctx = rex.Ctx{Session: "mine"}
	m.Update(m.loadLauncherSessions(true)())
	// Directory replies land per host, in either order, and only the newest
	// request for each host is accepted.
	injectDirs(m, rex.LocalHostLabel, []catalog.Directory{
		{Label: "alpha", Path: "/workspace/alpha"},
		{Label: "mine", Path: "/workspace/mine"},
		{Label: "zeta", Path: "/workspace/zeta"},
	})
	m.Update(launcherDirsMsg{request: m.launcherDirsRequest + 999, host: "hades", items: []catalog.Directory{
		{Label: "stale", Path: "/home/azuan/workspace/stale"},
	}})
	injectDirs(m, "hades", []catalog.Directory{
		{Label: "hnhiring", Path: "/home/azuan/workspace/hnhiring"},
	})
	labels := launcherLabels(m)
	want := []string{"mine", "other", "wispy-brook", "alpha", "zeta", "hnhiring"}
	if strings.Join(labels, ",") != strings.Join(want, ",") {
		t.Fatalf("row order = %v, want %v", labels, want)
	}
	// Remote rows carry an @host badge; local rows stay clean.
	view := ansi.Strip(m.View())
	if !strings.Contains(view, "· hades") {
		t.Fatal("remote rows must show the @host badge")
	}
	if strings.Contains(view, "· This Mac") {
		t.Fatal("local rows must not show a host badge")
	}
	if !strings.Contains(view, "● mine") {
		t.Fatal("origin session must show the active dot")
	}
}

func TestLauncherPinnedLocalDirsFloatFirst(t *testing.T) {
	t.Setenv("HOME", t.TempDir()) // Pins live in ~/.config/raptor/config.toml.
	pickerRexLogSessions(t, `{"sessions":[]}`, "")
	fakeZoxide(t, "/workspace/beta", "/workspace/alpha")
	m := launcherModel()
	m.hostOrder = []string{rex.LocalHostLabel}
	m.hostDirs[rex.LocalHostLabel] = []catalog.Directory{
		{Label: "beta", Path: "/workspace/beta"},
		{Label: "alpha", Path: "/workspace/alpha"},
	}
	if _, err := config.TogglePin("/workspace/alpha"); err != nil {
		t.Fatal(err)
	}
	m.loadPins()
	m.applyLauncher()
	if labels := launcherLabels(m); strings.Join(labels, ",") != "alpha,beta" {
		t.Fatalf("pinned directory must float first: %v", labels)
	}
	// Pins are local: remote directories never pin.
	if _, err := config.TogglePin("/home/azuan/workspace/hnhiring"); err != nil {
		t.Fatal(err)
	}
	m.loadPins()
	remote := launcherRow{dir: &catalog.Directory{Label: "hnhiring", Path: "/home/azuan/workspace/hnhiring"}, host: "hades"}
	if remote.host != rex.LocalHostLabel && remote.pinned {
		t.Fatal("remote directories must not pin")
	}
}

func TestLauncherSkipsDirsWithSameHostSessionLabel(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	pickerRexLogSessions(t, `{"sessions":[]}`, "")
	fakeZoxide(t, "/workspace/dotfiles")
	m := launcherModel()
	m.sessions = localGroups(entry("s1", "dotfiles", rex.LocalHostLabel, false))
	m.hostOrder = []string{rex.LocalHostLabel}
	m.hostDirs[rex.LocalHostLabel] = []catalog.Directory{{Label: "dotfiles", Path: "/workspace/dotfiles"}}
	m.applyLauncher()
	labels := launcherLabels(m)
	if len(labels) != 1 || labels[0] != "dotfiles" || m.launcher[m.launcherView[0].index].dir != nil {
		t.Fatalf("the session stays, its same-name directory row must go: %v", labels)
	}
}

func TestLauncherEnterSessionJumpsCrossHost(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	log := pickerRexLogSessions(t, `{"sessions":[]}`, "")
	m := launcherModel()
	m.ctx = rex.Ctx{Client: "client:local"}
	m.sessions = []rex.HostGroup{
		{Label: rex.LocalHostLabel, Local: true, Reachable: true, Entries: []rex.SessionEntry{entry("s1", "work", rex.LocalHostLabel, false)}},
		{Label: "hades", Reachable: true, Entries: []rex.SessionEntry{entry("r1", "wispy-brook", "hades", false)}},
	}
	m.applyLauncher()
	if m.launcherView[0].index != 0 || m.launcher[0].session == nil || m.launcher[0].session.ID != "s1" {
		t.Fatal("sanity: the local session should be the first row")
	}
	// Remote session row: Enter quits with the jump result.
	m.sel = 1
	m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if m.jumpSession == nil || m.jumpSession.Host != "hades" {
		t.Fatalf("remote session Enter must request a jump: %+v", m.jumpSession)
	}
	if code, done := finishSessionsResult(rex.Ctx{Client: "client:local"}, m); !done || code != 0 {
		t.Fatalf("finish must jump cleanly: code=%d done=%v", code, done)
	}
	got, err := os.ReadFile(log)
	want := "api call client.list {\"kinds\":[\"app\"]}\n" +
		"-S hades api call client.list {\"kinds\":[\"app\"]}\n" +
		"-S hades -C client:remote-app do session.select session_id=r1\n"
	if err != nil || !strings.Contains(string(got), want) {
		t.Fatalf("jump calls = %q, want substring %q", got, want)
	}
}

func TestLauncherEnterLocalDirCreatesAndSwitches(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	log := pickerRexLogSessions(t, `{"sessions":[{"session_id":"existing","label":"project"}]}`, "")
	fakeZoxide(t, "/workspace/project")
	m := launcherModel()
	m.ctx = rex.Ctx{Client: "client"}
	m.sessions = localGroups()
	m.hostOrder = []string{rex.LocalHostLabel}
	m.hostDirs[rex.LocalHostLabel] = []catalog.Directory{{Label: "project", Path: "/workspace/project"}}
	m.applyLauncher()
	m.sel = 0
	m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if m.launchDir == nil || m.launchDir.Path != "/workspace/project" || m.picked != nil {
		t.Fatalf("default Enter must launch a session: %+v", m.launchDir)
	}
	if code, done := finishSessionsResult(rex.Ctx{Client: "client"}, m); !done || code != 0 {
		t.Fatalf("finish must switch cleanly: code=%d done=%v", code, done)
	}
	got, err := os.ReadFile(log)
	want := "-C client do session.select session_id=existing\n"
	if err != nil || !strings.Contains(string(got), want) {
		t.Fatalf("select calls = %q, want substring %q", got, want)
	}
	if strings.Contains(string(got), "new --json") {
		t.Fatal("an existing session label must be reused, never created")
	}
}

func TestLauncherOverriddenTargetDispatchesDirectory(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	pickerRexLogSessions(t, `{"sessions":[]}`, "")
	fakeZoxide(t, "/workspace/project")
	m := launcherModel()
	m.cfg.Targets = []string{"session", "tab", "pane_right", "pane_below", "here"}
	m.ctx = rex.Ctx{Block: "origin"}
	m.sessions = localGroups()
	m.hostOrder = []string{rex.LocalHostLabel}
	m.hostDirs[rex.LocalHostLabel] = []catalog.Directory{{Label: "project", Path: "/workspace/project"}}
	m.applyLauncher()
	// ctrl+o cycles the target on local directory rows only.
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyCtrlO})
	if cmd != nil || m.target == "session" {
		t.Fatalf("ctrl+o must cycle the open target: %s", m.target)
	}
	m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if m.launchDir != nil || m.picked == nil || m.picked.path != "/workspace/project" {
		t.Fatalf("overridden target must dispatch the directory: %+v %+v", m.launchDir, m.picked)
	}
	// Remote directory rows always launch sessions on their host, whatever
	// the open target says. The target only ever applies to local rows.
	m = launcherModel()
	m.sessions = []rex.HostGroup{{Label: "hades", Reachable: true, Entries: []rex.SessionEntry{entry("r1", "wispy-brook", "hades", false)}}}
	m.hostOrder = []string{rex.LocalHostLabel, "hades"}
	m.hostDirs["hades"] = []catalog.Directory{{Label: "hnhiring", Path: "/home/azuan/workspace/hnhiring"}}
	m.applyLauncher()
	for i, match := range m.launcherView {
		if row := m.launcher[match.index]; row.dir != nil && row.host == "hades" {
			m.sel = i
			break
		}
	}
	m.target = "tab"
	m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if m.launchDir == nil || m.launchDir.Host != "hades" || m.picked != nil {
		t.Fatal("remote directories must always launch sessions on their host")
	}
}

func TestLauncherCloseGuardsOrigin(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	log := pickerRexLogSessions(t, `{"sessions":[]}`, "")
	m := launcherModel()
	m.ctx = rex.Ctx{Session: "s1", Client: "client"}
	m.sessions = localGroups(entry("s1", "work", rex.LocalHostLabel, true))
	m.applyLauncher()
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlX})
	if m.closeSession != nil || m.err == "" {
		t.Fatal("the origin session must refuse to close")
	}
	m.sessions = localGroups(entry("s1", "work", rex.LocalHostLabel, true), entry("s2", "play", rex.LocalHostLabel, false))
	m.applyLauncher()
	m.sel = 1
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlX})
	if m.closeSession == nil || m.closeSession.ID != "s2" {
		t.Fatalf("close must target the selected session: %+v", m.closeSession)
	}
	if code, done := finishSessionsResult(m.ctx, m); !done || code != 0 {
		t.Fatalf("close must finish cleanly: %d %v", code, done)
	}
	got, err := os.ReadFile(log)
	if err != nil || !strings.Contains(string(got), "api call session.destroy {\"session_id\":\"s2\"}") {
		t.Fatalf("close calls = %q", got)
	}
}

func TestLauncherWorktreeShortcutUsesGitRepo(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	pickerRexLogSessions(t, `{"sessions":[]}`, "")
	repo := fixtureRepo(t)
	fakeZoxide(t, repo, t.TempDir())
	m := launcherModel()
	m.sessions = localGroups()
	m.hostOrder = []string{rex.LocalHostLabel}
	m.hostDirs[rex.LocalHostLabel] = []catalog.Directory{
		{Label: worktreepkg.RepoRoot(repo), Path: repo},
		{Label: "plain", Path: t.TempDir()},
	}
	m.applyLauncher()
	// Select the repo row: first row is the git repo (pins empty, zoxide order).
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlT})
	if m.next != "wt" || m.nextRepo != worktreepkg.RepoRoot(repo) {
		t.Fatalf("ctrl+t must open worktrees for the git repo: %s %s", m.next, m.nextRepo)
	}
	m = launcherModel()
	m.sessions = localGroups()
	m.hostOrder = []string{rex.LocalHostLabel}
	m.hostDirs[rex.LocalHostLabel] = []catalog.Directory{{Label: "plain", Path: t.TempDir()}}
	m.applyLauncher()
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlT})
	if m.next != "" || m.err != "not a git repo" {
		t.Fatalf("non-repo rows must report the error: %q %q", m.next, m.err)
	}
}

func TestLauncherPreviewRunsForSessionRowsOnly(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	log := pickerRexLogSessions(t, `{"sessions":[]}`, "")
	m := launcherModel()
	m.width = 120
	m.sessions = localGroups(entry("s1", "work", rex.LocalHostLabel, false))
	m.applyLauncher()
	tick := m.schedulePreview()
	if tick == nil {
		t.Fatal("wide terminal with a session row must schedule a capture")
	}
	if _, err := os.Stat(log); !os.IsNotExist(err) {
		t.Fatal("capture must run in its command, not in Update")
	}
	tickMsg := tick().(previewTickMsg)
	if tickMsg.request != m.previewRequest {
		t.Fatalf("tick request = %d, want %d", tickMsg.request, m.previewRequest)
	}
	_, fetchCmd := m.Update(tickMsg)
	if fetchCmd == nil {
		t.Fatal("the tick must start the capture fetch")
	}
	msg := fetchCmd().(captureMsg)
	if !strings.Contains(msg.text, "screen") {
		t.Fatalf("capture text missing: %q", msg.text)
	}
	m.Update(msg)
	if m.previewPending || !strings.Contains(m.previewText, "screen") {
		t.Fatal("capture not accepted")
	}
	// A stale reply must not overwrite the newest state.
	stale := captureMsg{request: m.previewRequest - 1, text: "stale"}
	m.previewText = "fresh"
	m.Update(stale)
	if m.previewText != "fresh" {
		t.Fatal("stale capture overwrote fresh text")
	}
	// Directory rows clear the preview instead of capturing.
	m.launcher = append(m.launcher, launcherRow{dir: &catalog.Directory{Label: "project", Path: "/workspace/project"}, host: rex.LocalHostLabel})
	m.launcherView = append(m.launcherView, launcherMatch{index: len(m.launcher) - 1})
	m.sel = len(m.launcherView) - 1
	if cmd := m.schedulePreview(); cmd != nil {
		t.Fatal("directory rows must not capture")
	}
	// Narrow terminals never capture.
	m = launcherModel()
	m.width = 80
	m.sessions = localGroups(entry("s1", "work", rex.LocalHostLabel, false))
	m.applyLauncher()
	if cmd := m.schedulePreview(); cmd != nil {
		t.Fatal("narrow terminals must not capture")
	}
}
