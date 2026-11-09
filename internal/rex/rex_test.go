package rex

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func fakeRex(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	log := filepath.Join(dir, "calls")
	t.Setenv("REX_TEST_LOG", log)
	script := `#!/bin/sh
printf '%s\n' "$*" >> "$REX_TEST_LOG"
case "$*" in
  *session.select*)
    if [ "$REX_TEST_FAIL" = select ]; then echo 'selection failed' >&2; exit 1; fi;;
  *client.list*)
    if [ "$REX_TEST_FAIL" = client ]; then echo '{"clients":[]}'; exit 0; fi
    echo '{"clients":[{"client_id":"client:app","info":{"kind":"app","label":"my-mac"}}]}';;
  *'ls --json')
    if [ "$REX_TEST_FAIL" = list ]; then echo 'host unavailable' >&2; exit 1; fi
    if [ "$REX_TEST_FAIL" = malformed ]; then echo '{}'; exit 0; fi
    echo '{"sessions":[{"session_id":"session:previous"},{"session_id":"session:current"}]}';;
esac
`
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return log
}

func seedHistory(t *testing.T, host string, ids ...string) {
	t.Helper()
	for i, id := range ids {
		if err := RecordSessionVisit(host, id, time.Now().Add(time.Duration(i-len(ids))*time.Minute), false); err != nil {
			t.Fatal(err)
		}
	}
}

func TestSelectSessionRemembersOnlyOnSuccess(t *testing.T) {
	fakeRex(t)
	ctx := Ctx{Session: "session:current", Client: "client:app"}
	seedHistory(t, "", "session:previous")
	before, _ := os.ReadFile(recencyPath())
	t.Setenv("REX_TEST_FAIL", "select")
	if err := SelectSession(ctx, "session:previous"); err == nil {
		t.Fatal("expected selection failure")
	}
	after, _ := os.ReadFile(recencyPath())
	if string(before) != string(after) {
		t.Fatal("failed selection changed history")
	}
	t.Setenv("REX_TEST_FAIL", "")
	if err := SelectSession(ctx, "session:previous"); err != nil {
		t.Fatal(err)
	}
	ranks := LoadSessionRecency()
	if ranks.Rank("", "session:previous") != 0 || ranks.Rank("", ctx.Session) != 1 {
		t.Fatalf("wrong history: %v", ranks)
	}
}

func TestSelectLastSkipsDeletedAndToggles(t *testing.T) {
	fakeRex(t)
	seedHistory(t, "", "session:previous", "session:deleted", "session:current")
	ctx := Ctx{Session: "session:current", Client: "client:app"}
	for _, want := range []string{"session:previous", "session:current", "session:previous"} {
		got, err := SelectLast(ctx)
		if err != nil || got != want {
			t.Fatalf("selected %q, error %v, want %q", got, err, want)
		}
		ctx.Session = got
	}
}

func TestSelectLastFailurePreservesHistory(t *testing.T) {
	for _, failure := range []string{"select", "list", "malformed"} {
		t.Run(failure, func(t *testing.T) {
			fakeRex(t)
			seedHistory(t, "", "session:previous")
			before, _ := os.ReadFile(recencyPath())
			t.Setenv("REX_TEST_FAIL", failure)
			if _, err := SelectLast(Ctx{Session: "session:current", Client: "client:app"}); err == nil {
				t.Fatal("expected failure")
			}
			after, _ := os.ReadFile(recencyPath())
			if string(before) != string(after) {
				t.Fatal("failed navigation changed history")
			}
		})
	}
}

func TestSelectLastRemote(t *testing.T) {
	log := fakeRex(t)
	seedHistory(t, "work-host", "session:previous")
	got, err := SelectLast(Ctx{Session: "session:current", Client: "client:app"})
	if err != nil || got != "session:previous" {
		t.Fatalf("selected %q, error %v", got, err)
	}
	calls, _ := os.ReadFile(log)
	if !strings.Contains(string(calls), "-S work-host -C client:app do session.select session_id=session:previous") {
		t.Fatalf("wrong remote routing: %s", calls)
	}
	if LoadSessionRecency().Rank("work-host", got) != 0 {
		t.Fatal("remote selection not recorded")
	}
}

func TestSelectLastRemoteRequiresApp(t *testing.T) {
	log := fakeRex(t)
	seedHistory(t, "work-host", "session:previous")
	t.Setenv("REX_TEST_FAIL", "client")
	before, _ := os.ReadFile(recencyPath())
	if _, err := SelectLast(Ctx{Session: "session:current", Client: "client:app"}); err == nil {
		t.Fatal("accepted a remote host without the requesting app")
	}
	after, _ := os.ReadFile(recencyPath())
	calls, _ := os.ReadFile(log)
	if string(before) != string(after) || strings.Contains(string(calls), "session.select") || strings.Contains(string(calls), "session.focus_window") {
		t.Fatal("failed remote routing changed history or focus")
	}
}

func TestSelectLastLegacyFallback(t *testing.T) {
	fakeRex(t)
	if err := os.MkdirAll(filepath.Dir(statePath()), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(statePath(), []byte("session:previous\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := SelectLast(Ctx{Session: "session:current", Client: "client:app"})
	if err != nil || got != "session:previous" {
		t.Fatalf("selected %q, error %v", got, err)
	}
}

func TestSelectLastRejectsMissingContextOrHistory(t *testing.T) {
	fakeRex(t)
	for _, ctx := range []Ctx{{}, {Session: "session:current"}, {Client: "client:app"}, {Session: "session:current", Client: "client:app"}} {
		if _, err := SelectLast(ctx); err == nil {
			t.Fatalf("expected error for %+v", ctx)
		}
	}
}
