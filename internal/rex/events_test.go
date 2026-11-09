package rex

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRelevantEvents(t *testing.T) {
	for _, name := range []string{"program_status_changed", "program_status_removed", "pwd_changed", "process_changed", "child_exited", "title_changed"} {
		line := `{"type":"session_event","payload":{"session_id":"s","event":{"type":"block_event","payload":{"name":"` + name + `"}}}}`
		if !relevantEvent([]byte(line)) {
			t.Errorf("ignored %s", name)
		}
	}
	for _, line := range []string{`garbage`, `{"type":"client_joined"}`, `{"type":"client_left"}`, `{"type":"client_changed"}`, `{"type":"session_event","payload":{"event":{"type":"client_connected"}}}`, `{"type":"block_event","payload":{"name":"bell"}}`, `{"type":"future_event"}`} {
		if relevantEvent([]byte(line)) {
			t.Errorf("accepted %s", line)
		}
	}
	for _, name := range []string{"session_created", "session_destroyed", "session_label_changed", "session_view_changed", "window_closed", "hosts_changed"} {
		if !relevantEvent([]byte(`{"type":"` + name + `"}`)) {
			t.Errorf("ignored %s", name)
		}
	}
}

func fakeEventCLI(t *testing.T, script string) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte("#!/bin/sh\n"+script), 0755); err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestWatcherDeliveryReconnectCancel(t *testing.T) {
	dir := fakeEventCLI(t, `echo "$*" >> "$EVENT_LOG"
if [ -f "$EVENT_FIRST" ]; then
 printf '%s\n' '{"type":"session_event","payload":{"event":{"type":"block_event","payload":{"name":"program_status_changed"}}}}'
 exec sleep 60
fi
touch "$EVENT_FIRST"
exit 0
`)
	log := filepath.Join(dir, "log")
	t.Setenv("EVENT_LOG", log)
	t.Setenv("EVENT_FIRST", filepath.Join(dir, "first"))
	w := WatchEvents(context.Background())
	defer w.Close()
	w.AddHost("devbox")
	w.AddHost("devbox") // Idempotent, no second stream for the same host.
	deadline := time.After(3 * time.Second)
	for {
		select {
		case <-w.Changes:
			data, _ := os.ReadFile(log)
			if strings.Count(string(data), "--all --fail-fast") >= 3 {
				if !strings.Contains(string(data), "-S devbox do -e") {
					t.Fatalf("wrong host arguments: %s", data)
				}
				done := make(chan struct{})
				go func() { w.Close(); close(done) }()
				select {
				case <-done:
					return
				case <-time.After(time.Second):
					t.Fatal("cancel did not reap streams")
				}
			}
		case <-deadline:
			t.Fatal("no reconnect/delivery")
		}
	}
}

func TestWatcherReadyRefreshesWithoutStartupTimer(t *testing.T) {
	fakeEventCLI(t, `printf '%s\n' '{"type":"raptor_ready"}'
exec sleep 60
`)
	w := WatchEvents(context.Background())
	defer w.Close()
	select {
	case <-w.Changes:
	case <-time.After(time.Second):
		t.Fatal("native subscription acknowledgement did not invalidate snapshot")
	}
	select {
	case <-w.Changes:
		t.Fatal("quiet subscription caused another state refresh")
	case <-time.After(50 * time.Millisecond):
	}
	if !strings.Contains(eventsScript, `rex.call("session.attach_all", {event_scope="all"})`) || strings.Contains(eventsScript, "rex.every") {
		t.Fatal("subscription must use native attach acknowledgement, not a timer")
	}
}

func TestWatcherBoundedInvalidations(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ch := make(chan EventChange, 1)
	w := &EventWatcher{ctx: ctx, changes: ch}
	for range 10000 {
		w.changed("")
	}
	if len(ch) != 1 {
		t.Fatalf("queue length %d", len(ch))
	}
}
