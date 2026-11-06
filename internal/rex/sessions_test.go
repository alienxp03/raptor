package rex

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func fakeSessionRex(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	log := filepath.Join(dir, "calls")
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("REX_TEST_LOG", log)
	script := `#!/bin/sh
printf '%s\n' "$*" >> "$REX_TEST_LOG"
case "$*" in
  'ls --json')
    if [ "$REX_TEST_FAIL" = list ]; then exit 1; fi
    if [ "$REX_TEST_FAIL" = json ]; then echo '{'; exit 0; fi
    if [ "$REX_TEST_FAIL" = empty ]; then echo '{"sessions":[]}'; exit 0; fi
    echo '{"sessions":[{"session_id":"a","label":"Project"},{"session_id":"dead","label":"Dead"},{"session_id":"b","label":"Tools"}]}' ;;
  'api call -s a session.view '*)
    echo '{"active_window_id":"a2","windows":[{"window_id":"a1","label":"shell"},{"window_id":"a2","label":"build"}]}' ;;
  'api call -s dead session.view '*) exit 1 ;;
  'api call -s b session.view '*) echo '{"windows":[]}' ;;
  *) if [ "$REX_TEST_FAIL" = jump ]; then exit 1; fi ;;
esac
`
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return log
}

func TestSessionEntriesGroupedShape(t *testing.T) {
	fakeSessionRex(t)
	got, err := SessionEntries("a")
	if err != nil {
		t.Fatal(err)
	}
	want := []SessionEntry{
		{Kind: "session", ID: "a", Path: "a", SessionID: "a", Label: "Project", SessionLabel: "Project", Active: true},
		{Kind: "window", ID: "a1", Path: "a1", SessionID: "a", Label: "shell", SessionLabel: "Project"},
		{Kind: "window", ID: "a2", Path: "a2", SessionID: "a", Label: "build", SessionLabel: "Project", Active: true},
		{Kind: "session", ID: "dead", Path: "dead", SessionID: "dead", Label: "Dead", SessionLabel: "Dead"},
		{Kind: "session", ID: "b", Path: "b", SessionID: "b", Label: "Tools", SessionLabel: "Tools"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("entries = %+v, want %+v", got, want)
	}
}

func TestSessionEntriesListErrors(t *testing.T) {
	fakeSessionRex(t)
	for _, failure := range []string{"list", "json"} {
		t.Run(failure, func(t *testing.T) {
			t.Setenv("REX_TEST_FAIL", failure)
			if _, err := SessionEntries("a"); err == nil {
				t.Fatal("expected list error")
			}
		})
	}
}

func TestSessionEntriesEmpty(t *testing.T) {
	fakeSessionRex(t)
	t.Setenv("REX_TEST_FAIL", "empty")
	entries, err := SessionEntries("missing")
	if err != nil || len(entries) != 0 {
		t.Fatalf("entries = %+v, error = %v", entries, err)
	}
}

func TestSessionEntriesBoundedParallelOrderAndFailures(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("REX_TEST_STATE", dir)
	var sessions []apiSession
	var want []SessionEntry
	for i := range sessionWindowWorkers * 3 {
		id := fmt.Sprintf("s%d", i)
		sessions = append(sessions, apiSession{SessionID: id, Label: id})
		want = append(want, SessionEntry{
			Kind: "session", ID: id, Path: id, SessionID: id,
			Label: id, SessionLabel: id, Active: i == 1,
		})
		// Both a dead session and an invalid response must keep their rows.
		if i == 2 || i == 3 {
			continue
		}
		for _, suffix := range []string{"b", "a"} {
			windowID := id + suffix
			want = append(want, SessionEntry{
				Kind: "window", ID: windowID, Path: windowID, SessionID: id,
				Label: windowID, SessionLabel: id, Active: suffix == "a",
			})
		}
	}
	payload, err := json.Marshal(struct {
		Sessions []apiSession `json:"sessions"`
	}{sessions})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "sessions"), payload, 0o600); err != nil {
		t.Fatal(err)
	}
	// Atomic directories count active calls. No call can finish before the
	// test releases the gate, so reaching the worker limit proves overlap.
	script := fmt.Sprintf(`#!/bin/sh
state="$REX_TEST_STATE"
if [ "$1" = ls ]; then cat "$state/sessions"; exit; fi
id="$4"
slot=1
while ! mkdir "$state/slot-$slot" 2>/dev/null; do
  slot=$((slot + 1))
  if [ "$slot" -gt %d ]; then
    touch "$state/overflow"
    exit 1
  fi
done
trap 'rmdir "$state/slot-$slot"' EXIT
touch "$state/started-$id"
while [ ! -f "$state/release" ]; do sleep 0.01; done
# Force a later sidebar session to finish before the first session.
if [ "$id" = s0 ]; then
  while [ ! -f "$state/finished-s1" ]; do sleep 0.01; done
fi
touch "$state/finished-$id"
case "$id" in
  s2) exit 1 ;;
  s3) echo '{'; exit 0 ;;
esac
printf '{"active_window_id":"%%sa","windows":[{"window_id":"%%sb","label":"%%sb"},{"window_id":"%%sa","label":"%%sa"}]}' "$id" "$id" "$id" "$id" "$id"
`, sessionWindowWorkers)
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	release := func() {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, "release"), nil, 0o600); err != nil {
			t.Error(err)
		}
	}
	t.Cleanup(release)
	type result struct {
		entries []SessionEntry
		err     error
	}
	done := make(chan result, 1)
	go func() {
		entries, err := SessionEntries("s1")
		done <- result{entries, err}
	}()
	deadline := time.Now().Add(5 * time.Second)
	for {
		started, err := filepath.Glob(filepath.Join(dir, "started-*"))
		if err != nil {
			t.Fatal(err)
		}
		if len(started) == sessionWindowWorkers {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("only %d window calls started before release; want %d", len(started), sessionWindowWorkers)
		}
		time.Sleep(10 * time.Millisecond)
	}
	release()
	select {
	case got := <-done:
		if got.err != nil || !reflect.DeepEqual(got.entries, want) {
			t.Fatalf("entries = %+v, error = %v; want %+v", got.entries, got.err, want)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("session listing did not finish")
	}
	if _, err := os.Stat(filepath.Join(dir, "overflow")); !os.IsNotExist(err) {
		t.Fatalf("window concurrency exceeded %d (stat error: %v)", sessionWindowWorkers, err)
	}
}

func TestJumpSessionAndTab(t *testing.T) {
	for _, tt := range []struct {
		name   string
		entry  SessionEntry
		client string
		want   string
	}{
		{"client session", SessionEntry{Kind: "session", ID: "a", SessionID: "a"}, "client", "-C client do session.select session_id=a\n"},
		{"client tab", SessionEntry{Kind: "window", ID: "a1", SessionID: "a"}, "client", "-C client do session.select session_id=a window_id=a1\n"},
		{"fallback session uses active tab", SessionEntry{Kind: "session", ID: "a", SessionID: "a"}, "", "api call -s a session.view {\"session_id\":\"a\"}\napi call session.focus_window {\"session_id\":\"a\",\"window_id\":\"a2\"}\n"},
		{"fallback tab", SessionEntry{Kind: "window", ID: "a1", SessionID: "a"}, "", "api call session.focus_window {\"session_id\":\"a\",\"window_id\":\"a1\"}\n"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			log := fakeSessionRex(t)
			if err := Jump(tt.entry, tt.client); err != nil {
				t.Fatal(err)
			}
			got, err := os.ReadFile(log)
			if err != nil || string(got) != tt.want {
				t.Fatalf("calls = %s, want %s; error = %v", got, tt.want, err)
			}
		})
	}
}

func TestJumpFailure(t *testing.T) {
	fakeSessionRex(t)
	t.Setenv("REX_TEST_FAIL", "jump")
	if err := Jump(SessionEntry{Kind: "session", SessionID: "a"}, "client"); err == nil {
		t.Fatal("expected selection error")
	}
	if err := Jump(SessionEntry{Kind: "session", SessionID: "b", SessionLabel: "Tools"}, ""); err == nil || !strings.Contains(err.Error(), "no windows") {
		t.Fatalf("expected empty-session error, got %v", err)
	}
}
