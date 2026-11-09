package api

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
)

func TestActivitySnapshotViewsCacheAndFailure(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	dir := t.TempDir()
	log := filepath.Join(dir, "scans")
	fail := filepath.Join(dir, "fail")
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("ACTIVITY_LOG", log)
	t.Setenv("ACTIVITY_FAIL", fail)
	script := `#!/bin/sh
if [ "$1" = do ]; then
 echo scan >> "$ACTIVITY_LOG"
 [ ! -f "$ACTIVITY_FAIL" ] || exit 1
 echo '{"sessions":[{"session_id":"s","active_window_id":"w","windows":[{"window_id":"w","focused_block_id":"b","blocks":[{"block_id":"b","process":{"foreground":{"cwd":"/repo/sub"}},"records":[{"app":"pi","state":"working"},{"app":"codex","state":"blocked"}]}]}]}]}'
 exit 0
fi
case "$*" in
 'ls --json') echo '{"sessions":[{"session_id":"s","label":"Repo"}]}' ;;
 'api call -s s session.view '*) echo '{"windows":[{"window_id":"w","label":"Tab"}]}' ;;
 *) exit 1 ;;
esac
`
	for name, contents := range map[string]string{"rex": script, "zoxide": "#!/bin/sh\nprintf '/repo\\n/repo/sub\\n/repo-other\\n'\n"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(contents), 0755); err != nil {
			t.Fatal(err)
		}
	}
	h := New(rex.Ctx{Session: "s"}, config.Default())
	call := func(method string) any {
		t.Helper()
		result, err := h.call(method, json.RawMessage(`{}`))
		if err != nil {
			t.Fatal(err)
		}
		return result
	}
	scans := func(want int) {
		t.Helper()
		data, err := os.ReadFile(log)
		if err != nil {
			t.Fatal(err)
		}
		if got := strings.Count(string(data), "scan"); got != want {
			t.Fatalf("scans=%d want=%d", got, want)
		}
	}
	// The launcher cache is per test; legs that must hit the live fetch
	// clear it first.
	clearCache := func() {
		t.Helper()
		if err := os.Remove(h.launcherCachePath()); err != nil && !os.IsNotExist(err) {
			t.Fatal(err)
		}
	}
	checkSessions := func(active bool) {
		t.Helper()
		result := call("sessions").(sessionsResult)
		if len(result.Items) != 4 {
			t.Fatalf("sessions=%+v", result)
		}
		// The session and exact working folder light up. The parent and
		// unrelated directories stay quiet, even while the agent is working.
		for i, item := range result.Items {
			matches := active && (item.Kind == "session" || item.Path == "/repo/sub")
			if matches && (item.State != "blocked" || !item.Working) {
				t.Fatalf("row %d=%+v", i, item)
			}
			if !matches && (item.State != "" || item.Working) {
				t.Fatalf("failed snapshot row %d=%+v", i, item)
			}
		}
	}

	clearCache()
	call("sessions") // Cold start: snapshot scan + live fetch + cache write.
	checkSessions(true)
	scans(1)
	if _, err := h.call("context", json.RawMessage(`{"session":"other"}`)); err != nil {
		t.Fatal(err)
	}
	// A fresh cache answers without touching the snapshot.
	checkSessions(true)
	scans(1)
	agents := call("agents").(agentsResult)
	if len(agents.Items) != 2 || agents.Items[0].Active {
		t.Fatalf("agents=%+v", agents)
	}
	scans(2)
	h.activityAt = time.Now().Add(-activitySnapshotTTL - time.Second)
	checkSessions(true)
	scans(2) // Fresh cache: the stale snapshot is never consulted.

	// No cache: the stale snapshot refreshes and lights the rows.
	clearCache()
	checkSessions(true)
	scans(3)

	if err := os.WriteFile(fail, nil, 0600); err != nil {
		t.Fatal(err)
	}
	h.activityAt = time.Now().Add(-activitySnapshotTTL - time.Second)
	clearCache()
	checkSessions(false)
	scans(5) // Failed snapshot: rows keep plain state, cache stores them.
	// A failed fresh agent request must still fail, not return cached activity.
	if _, err := h.call("agents", json.RawMessage(`{}`)); err == nil {
		t.Fatal("accepted failed agents snapshot")
	}
	scans(6)
	if err := os.Remove(fail); err != nil {
		t.Fatal(err)
	}
	clearCache()
	checkSessions(true)
	scans(7)
	// Cache is per Handler, not process-wide.
	other := New(rex.Ctx{}, config.Default())
	if _, err := other.activitySnapshot(false); err != nil {
		t.Fatal(err)
	}
	scans(8)

}

func TestActivityCachesSuccessfulEmptySnapshot(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, "log")
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("ACTIVITY_LOG", log)
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte("#!/bin/sh\necho scan >> \"$ACTIVITY_LOG\"\necho '{}'\n"), 0755); err != nil {
		t.Fatal(err)
	}
	h := New(rex.Ctx{}, config.Default())
	for range 2 {
		if _, err := h.activitySnapshot(false); err != nil {
			t.Fatal(err)
		}
	}
	data, err := os.ReadFile(log)
	if err != nil || strings.Count(string(data), "scan") != 1 {
		t.Fatalf("log=%s err=%v", data, err)
	}
}
