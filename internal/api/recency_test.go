package api

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
)

func recencyHandler(t *testing.T) *Handler {
	t.Helper()
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	h := New(rex.Ctx{}, config.Default())
	h.recordFocus = func(string, string, time.Time, bool) error { t.Error("unexpected history write"); return nil }
	return h
}

func sessionRows(h *Handler, query string) []string {
	p, _ := json.Marshal(map[string]string{"query": query})
	value, err := h.call("sessions", p)
	if err != nil {
		panic(err)
	}
	var ids []string
	for _, row := range value.(sessionsResult).Items {
		ids = append(ids, row.Host+"/"+row.SessionID)
	}
	return ids
}

func TestSessionRecencyFrozenOrdering(t *testing.T) {
	h := recencyHandler(t)
	rows := []catalog.LauncherItem{}
	for i := 0; i < 8; i++ {
		id := fmt.Sprintf("session:%d", i)
		rows = append(rows, catalog.LauncherItem{Kind: "session", ID: id, SessionID: id, Host: rex.LocalHostLabel, Local: true, Label: "project", SessionLabel: "project"})
	}
	rows = append(rows, catalog.LauncherItem{Kind: "session", ID: "session:7", SessionID: "session:7", Host: "remote", Label: "project", SessionLabel: "project"}, catalog.LauncherItem{Kind: "dir", ID: "/one", Path: "/one", Host: "dir-one"}, catalog.LauncherItem{Kind: "dir", ID: "/two", Path: "/two", Host: "dir-two"})
	h.launcherLoaded = true
	h.launcher.Items = rows
	h.ctx.Session = "session:3"
	latest := rex.SessionRecency{"remote\x00session:7": 0, "\x00session:6": 1, "\x00session:7": 2}
	h.loadRecency = func() rex.SessionRecency { return latest }
	h.captureRecency(false)
	want := []string{"This Mac/session:3", "remote/session:7", "This Mac/session:6", "This Mac/session:7", "This Mac/session:0", "This Mac/session:1", "This Mac/session:2", "This Mac/session:4", "This Mac/session:5", "dir-one/", "dir-two/"}
	if got := sessionRows(h, ""); !reflect.DeepEqual(got, want) {
		t.Fatalf("order = %v", got)
	}
	// Even a caller mutating its map cannot change the published snapshot.
	latest["\x00session:0"] = -1
	h.invalidateActivity()
	h.storeLauncher(h.cacheGeneration(), rows, nil)
	if got := sessionRows(h, ""); !reflect.DeepEqual(got, want) {
		t.Fatalf("live refresh changed ranks: %v", got)
	}
	if _, err := h.call("context", json.RawMessage(`{"session":"session:3"}`)); err != nil {
		t.Fatal(err)
	}
	if got := sessionRows(h, ""); got[1] != "This Mac/session:0" {
		t.Fatalf("context did not reload ranks: %v", got)
	}
}

func TestSessionRecencyFuzzyScoreBeforeRanks(t *testing.T) {
	h := recencyHandler(t)
	h.launcherLoaded = true
	h.ranks = rex.SessionRecency{"\x00session:new": 0}
	h.launcher.Items = []catalog.LauncherItem{
		{Kind: "session", ID: "session:new", SessionID: "session:new", Local: true, Host: rex.LocalHostLabel, Label: "a long project", SessionLabel: "a long project"},
		{Kind: "session", ID: "session:old", SessionID: "session:old", Local: true, Host: rex.LocalHostLabel, Label: "project", SessionLabel: "project"},
	}
	if got := sessionRows(h, "project"); len(got) != 2 || got[0] != "This Mac/session:old" {
		t.Fatalf("fuzzy score lost: %v", got)
	}
}

func observation(sid string, pid int, at time.Time, initial bool) json.RawMessage {
	data, _ := json.Marshal(map[string]any{"session_id": sid, "client_pid": fmt.Sprint(pid), "observed_at": at.Format(time.RFC3339Nano), "initial": initial})
	return data
}

func waitFocus[T any](t *testing.T, c <-chan T) T {
	t.Helper()
	select {
	case v := <-c:
		return v
	case <-time.After(2 * time.Second):
		t.Fatal("focus worker stalled")
		var zero T
		return zero
	}
}

func TestFocusImmediateAckHiddenAndShutdown(t *testing.T) {
	h := recencyHandler(t)
	h.launcherLoaded = true
	h.launcher.Items = []catalog.LauncherItem{}
	entered := make(chan struct{})
	exited := make(chan struct{})
	h.validateFocus = func(ctx context.Context, pid int) bool { close(entered); <-ctx.Done(); close(exited); return true }
	h.resolveFocus = func(context.Context, string) (string, bool) { t.Error("resolved after shutdown"); return "", false }
	input, requests := io.Pipe()
	responses, output := io.Pipe()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	defer input.Close()
	defer requests.Close()
	defer responses.Close()
	defer output.Close()
	done := make(chan error, 1)
	go func() { done <- h.ServeContext(ctx, input, output) }()
	received := make(chan response, 3)
	go func() {
		scanner := bufio.NewScanner(responses)
		for scanner.Scan() {
			var r response
			_ = json.Unmarshal(scanner.Bytes(), &r)
			received <- r
		}
	}()
	send := func(id int, method string, p json.RawMessage) {
		_, err := fmt.Fprintf(requests, "{\"id\":%d,\"method\":%q,\"params\":%s}\n", id, method, p)
		if err != nil {
			t.Fatal(err)
		}
	}
	send(1, "events.subscribe", json.RawMessage(`{"enabled":false}`))
	if r := waitFocus(t, received); r.Error != "" {
		t.Fatal(r)
	}
	send(2, "sessions.visit", observation("session:focus", 123, time.Now().Add(-time.Second), false))
	if r := waitFocus(t, received); r.Error != "" {
		t.Fatal(r)
	}
	waitFocus(t, entered)
	// A blocked worker cannot block the next request, even while hidden.
	send(3, "sessions", json.RawMessage(`{}`))
	if r := waitFocus(t, received); r.Error != "" {
		t.Fatal(r)
	}
	cancel()
	if err := waitFocus(t, done); err != nil {
		t.Fatal(err)
	}
	waitFocus(t, exited)
}

func TestFocusValidationPreservesDistinctVisitsAndDeduplicates(t *testing.T) {
	h := recencyHandler(t)
	entered, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	h.validateFocus = func(context.Context, int) bool { once.Do(func() { close(entered); <-release }); return true }
	h.resolveFocus = func(context.Context, string) (string, bool) { return "remote", true }
	recorded := make(chan focusObservation, 4)
	h.recordFocus = func(host, sid string, at time.Time, initial bool) error {
		if host != "remote" {
			t.Errorf("host = %q", host)
		}
		recorded <- focusObservation{sid: sid, at: at, initial: initial}
		return nil
	}
	stop := h.startFocusWorker(context.Background())
	defer stop()
	at := time.Now().Add(-time.Hour)
	send := func(sid string, n int, initial bool) {
		t.Helper()
		if _, err := h.observeFocus(observation(sid, 123, at.Add(time.Duration(n)*time.Second), initial)); err != nil {
			t.Fatal(err)
		}
	}
	send("session:first", 0, true)
	waitFocus(t, entered)
	send("session:second", 1, false)
	send("session:third", 2, false)
	send("session:third", 2, false) // Duplicate.
	send("session:third", 1, false) // Older report for the same session.
	close(release)
	for i, sid := range []string{"session:first", "session:second", "session:third"} {
		got := waitFocus(t, recorded)
		if got.sid != sid || !got.at.Equal(at.Add(time.Duration(i)*time.Second)) || got.initial != (i == 0) {
			t.Fatalf("observation %d = %+v", i, got)
		}
	}
	// Stop joins the worker; there must be no duplicate writes left behind.
	stop()
	if len(recorded) != 0 {
		t.Fatalf("duplicate writes = %d", len(recorded))
	}
}

func TestFocusQueueBoundAndNewest(t *testing.T) {
	w := &focusWorker{wake: make(chan struct{}, 1), latest: make(map[focusKey]focusObservation)}
	at := time.Now().Add(-time.Hour)
	for i := 1; i <= 300; i++ {
		w.enqueue(focusObservation{pid: i, sid: "session:focus", at: at.Add(time.Duration(i) * time.Second)})
	}
	if len(w.pending) != focusQueueLimit || len(w.latest) > 128 {
		t.Fatalf("unbounded queue: %d/%d", len(w.pending), len(w.latest))
	}
	if w.pending[len(w.pending)-1].pid != 300 {
		t.Fatal("newest observation lost")
	}
}

func TestFocusInvalidPayload(t *testing.T) {
	h := recencyHandler(t)
	for _, p := range []json.RawMessage{
		json.RawMessage(`{}`), json.RawMessage(`{"session_id":"short","client_pid":"1","observed_at":"bad"}`),
		observation("session:ok", -1, time.Now(), false), observation("session:ok", 1, time.Now().Add(time.Hour), false),
		observation("session:bad id", 1, time.Now(), false),
	} {
		if _, err := h.observeFocus(p); err == nil {
			t.Fatalf("accepted %s", p)
		}
	}
}

func TestFocusRejectPIDAndAmbiguousSession(t *testing.T) {
	for _, validPID := range []bool{false, true} {
		t.Run(fmt.Sprint(validPID), func(t *testing.T) {
			h := recencyHandler(t)
			h.launcher.Items = []catalog.LauncherItem{{Kind: "session", SessionID: "session:duplicate", Local: true, Host: rex.LocalHostLabel}, {Kind: "session", SessionID: "session:duplicate", Host: "remote"}}
			validated := make(chan struct{}, 1)
			h.validateFocus = func(context.Context, int) bool { validated <- struct{}{}; return validPID }
			if !validPID {
				h.resolveFocus = func(context.Context, string) (string, bool) {
					t.Error("session resolution ran before PID validation")
					return "", false
				}
			}
			stop := h.startFocusWorker(context.Background())
			_, err := h.observeFocus(observation("session:duplicate", 123, time.Now().Add(-time.Second), true))
			if err != nil {
				t.Fatal(err)
			}
			waitFocus(t, validated)
			stop()
		})
	}
}

func TestFocusCachedCrossHostIdentity(t *testing.T) {
	h := recencyHandler(t)
	h.launcher.Items = []catalog.LauncherItem{{Kind: "session", SessionID: "session:remote", Host: "remote"}}
	if host, ok := h.resolveFocusHost(context.Background(), "session:remote"); !ok || host != "remote" {
		t.Fatalf("host = %q/%v", host, ok)
	}
}

func TestFocusNativeMembershipNotAttachments(t *testing.T) {
	h := recencyHandler(t)
	dir := t.TempDir()
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	script := `#!/bin/sh
case "$*" in
 'ls --json') echo '{"sessions":[{"session_id":"session:local"},{"session_id":"session:duplicate"}]}' ;;
 'api call hosts.list') echo '{"hosts":[{"label":"remote"}]}' ;;
 '-S remote --timeout 2s ls --json') echo '{"sessions":[{"session_id":"session:remote"},{"session_id":"session:duplicate"}]}' ;;
 *) exit 1 ;;
esac
`
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte(script), 0755); err != nil {
		t.Fatal(err)
	}
	for _, tt := range []struct {
		sid, host string
		ok        bool
	}{{"session:local", "", true}, {"session:remote", "remote", true}, {"session:duplicate", "", false}, {"session:attached-only", "", false}} {
		host, ok := h.resolveFocusHost(context.Background(), tt.sid)
		if host != tt.host || ok != tt.ok {
			t.Fatalf("%s = %q/%v", tt.sid, host, ok)
		}
	}
}

func TestFocusVisitDoesNotReloadRanks(t *testing.T) {
	h := recencyHandler(t)
	h.ranks = rex.SessionRecency{"\x00session:old": 0}
	h.loadRecency = func() rex.SessionRecency { t.Error("visit reloaded ranks"); return nil }
	h.validateFocus = func(context.Context, int) bool { return true }
	h.resolveFocus = func(context.Context, string) (string, bool) { return "", true }
	written := make(chan bool, 1)
	h.recordFocus = func(_ string, _ string, _ time.Time, initial bool) error { written <- initial; return nil }
	stop := h.startFocusWorker(context.Background())
	defer stop()
	at := time.Now().Add(-time.Hour)
	if _, err := h.observeFocus(observation("session:observed", 123, at, true)); err != nil {
		t.Fatal(err)
	}
	if !waitFocus(t, written) {
		t.Fatal("initial flag lost")
	}
	if h.ranks.Rank("", "session:old") != 0 {
		t.Fatal("ranks changed")
	}
}

func TestFocusNativeCancellation(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte("#!/bin/sh\nexec sleep 30\n"), 0755); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	var result any
	started := time.Now()
	if focusRead(ctx, []string{"ls", "--json"}, &result) {
		t.Fatal("cancelled listing succeeded")
	}
	if time.Since(started) > time.Second {
		t.Fatal("native child did not stop on cancellation")
	}
}

func TestFocusSubscribeReloadsRanks(t *testing.T) {
	h := recencyHandler(t)
	dir := t.TempDir()
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte("#!/bin/sh\nexit 1\n"), 0755); err != nil {
		t.Fatal(err)
	}
	loads := 0
	h.loadRecency = func() rex.SessionRecency { loads++; return rex.SessionRecency{"\x00session:shared": loads} }
	for i := 1; i <= 2; i++ {
		var output bytes.Buffer
		if err := h.Serve(strings.NewReader(`{"id":1,"method":"events.subscribe","params":{"enabled":true}}`), &output); err != nil {
			t.Fatal(err)
		}
		if h.ranks.Rank("", "session:shared") != i {
			t.Fatal("warm reopen did not reload")
		}
	}
}
