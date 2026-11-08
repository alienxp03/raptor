package rex

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func fakeRexWithHosts(t *testing.T, script string) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestHostsListsLocalFirstThenRemoteLabels(t *testing.T) {
	fakeRexWithHosts(t, `#!/bin/sh
case "$*" in
  'api call hosts.list') echo '{"hosts":[{"id":"host:1","label":"hades"},{"id":"host:2","label":"azuanz.local"}]}' ;;
  *) exit 1 ;;
esac
`)
	hosts := Hosts()
	if len(hosts) != 3 {
		t.Fatalf("hosts = %+v", hosts)
	}
	if !hosts[0].Local || hosts[0].Label != LocalHostLabel {
		t.Fatalf("local host = %+v", hosts[0])
	}
	if hosts[1].Label != "hades" || hosts[1].Local {
		t.Fatalf("remote host = %+v", hosts[1])
	}
	// Duplicate local labels collapse.
	if hosts[2].Label != "azuanz.local" {
		t.Fatalf("second remote = %+v", hosts[2])
	}
}

func TestHostsKeepsLocalWhenListingFails(t *testing.T) {
	fakeRexWithHosts(t, "#!/bin/sh\nexit 1\n")
	hosts := Hosts()
	if len(hosts) != 1 || !hosts[0].Local {
		t.Fatalf("hosts = %+v", hosts)
	}
}

func TestSessionGroupsOrderActivityAndUnreachable(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	script := `#!/bin/sh
case "$*" in
  'api call hosts.list') echo '{"hosts":[{"id":"host:1","label":"hades"},{"id":"host:2","label":"gone"}]}' ;;
  'ls --json') echo '{"sessions":[{"session_id":"a","label":"local"},{"session_id":"b","label":"origin"}]}' ;;
  '-S hades --timeout 3s ls --json') echo '{"sessions":[{"session_id":"r1","label":"wispy-brook"}]}' ;;
  '-S gone --timeout 3s ls --json') echo 'down' >&2; exit 255 ;;
  'do'*) echo '{"sessions":[]}' ;;
  '-S hades --timeout 4s do'*) echo '{"sessions":[{"session_id":"r1","active_window_id":"w","windows":[{"window_id":"w","focused_block_id":"b","blocks":[{"block_id":"b","records":[{"app":"pi","state":"working"}]}]}]}]}' ;;
esac
`
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	groups := SessionGroups("b", nil)
	if len(groups) != 3 {
		t.Fatalf("groups = %+v", groups)
	}
	local, hades, gone := groups[0], groups[1], groups[2]
	if !local.Local || local.Label != LocalHostLabel || !local.Reachable || len(local.Entries) != 2 {
		t.Fatalf("local group = %+v", local)
	}
	if !local.Entries[1].Active {
		t.Fatalf("origin session = %+v", local.Entries[1])
	}
	if !hades.Reachable || len(hades.Entries) != 1 || hades.Entries[0].State != "working" || !hades.Entries[0].Working {
		t.Fatalf("hades group = %+v", hades)
	}
	if gone.Reachable || gone.Error == "" || gone.Entries == nil {
		t.Fatalf("gone group = %+v", gone)
	}
}

func TestZoxideListOnRemoteFallsBackToShim(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, "ssh-calls")
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	ssh := `#!/bin/sh
printf '%s\n' "$*" >> "$SSH_LOG"
echo '/home/azuan/workspace'
`
	if err := os.WriteFile(filepath.Join(dir, "ssh"), []byte(ssh), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SSH_LOG", log)
	dirs := ZoxideListOn("hades")
	if len(dirs) != 1 || dirs[0] != "/home/azuan/workspace" {
		t.Fatalf("dirs = %+v", dirs)
	}
	got, err := os.ReadFile(log)
	if err != nil || !strings.Contains(string(got), "hades") {
		t.Fatalf("ssh calls = %s, err = %v", got, err)
	}
}

func TestZoxideListOnLocalNeverRunsSSH(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	ssh := "#!/bin/sh\necho 'ssh must not run' >&2\nexit 1\n"
	zoxide := "#!/bin/sh\necho /local/one\necho /local/two\n"
	for name, contents := range map[string]string{"rex": "#!/bin/sh\nexit 1\n", "ssh": ssh, "zoxide": zoxide} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(contents), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	dirs := ZoxideListOn("")
	if len(dirs) != 2 || dirs[0] != "/local/one" {
		t.Fatalf("dirs = %+v", dirs)
	}
}

func TestCreateSessionOnReusesLabelFirst(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, "calls")
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("REX_TEST_LOG", log)
	script := `#!/bin/sh
printf '%s\n' "$*" >> "$REX_TEST_LOG"
case "$*" in
  'ls --json') echo '{"sessions":[{"session_id":"s1","label":"raptor"}]}' ;;
esac
`
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	sid, existing, err := CreateSessionOn("", "/Users/x/Workspace/raptor")
	if err != nil || sid != "s1" || !existing {
		t.Fatalf("sid=%s existing=%v err=%v", sid, existing, err)
	}
	got, _ := os.ReadFile(log)
	if strings.Contains(string(got), "new ") {
		t.Fatalf("an existing session label must not create: %s", got)
	}
}
