package api

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
)

type eventOutput struct {
	lines       chan []byte
	writing     atomic.Bool
	interleaved atomic.Bool
}

func (w *eventOutput) Write(data []byte) (int, error) {
	if w.writing.Swap(true) {
		w.interleaved.Store(true)
	}
	defer w.writing.Store(false)
	w.lines <- append([]byte{}, data...)
	return len(data), nil
}

func TestServeContextCancellationUnblocksIdleRead(t *testing.T) {
	input, writer := io.Pipe()
	defer input.Close()
	defer writer.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- New(rex.Ctx{}, config.Default()).ServeContext(ctx, input, io.Discard) }()
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("shutdown waited for another input line")
	}
}

func TestServeEventsSubscriptionFreshCacheAndEOF(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	dir := t.TempDir()
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	script := `#!/bin/sh
case "$*" in
 *'do -e'*'--all --fail-fast')
 printf '%s\n' '{"type":"session_created","payload":{"session":{"session_id":"new","label":"New"}}}'
 exec sleep 60 ;;
 'ls --json') echo '{"sessions":[]}' ;;
 *) echo '{}' ;;
esac
`
	for name, content := range map[string]string{"rex": script, "zoxide": "#!/bin/sh\nexit 0\n"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0755); err != nil {
			t.Fatal(err)
		}
	}
	h := New(rex.Ctx{}, config.Default())
	if err := os.MkdirAll(filepath.Dir(h.launcherCachePath()), 0755); err != nil {
		t.Fatal(err)
	}
	h.writeLauncherCache([]catalog.LauncherItem{{Kind: "dir", Path: "/stale", Label: "Stale"}}, nil)
	h.activityAgents = []rex.AgentEntry{{State: "blocked"}}
	h.activityAt = time.Now()
	input, send := io.Pipe()
	out := &eventOutput{lines: make(chan []byte, 128)}
	done := make(chan error, 1)
	go func() { done <- h.Serve(input, out) }()
	defer send.Close()
	request := func(id int, method, params string) {
		t.Helper()
		if _, err := fmt.Fprintf(send, "{\"id\":%d,\"method\":%q,\"params\":%s}\n", id, method, params); err != nil {
			t.Fatal(err)
		}
	}
	read := func() map[string]json.RawMessage {
		t.Helper()
		select {
		case data := <-out.lines:
			var value map[string]json.RawMessage
			if err := json.Unmarshal(data, &value); err != nil {
				t.Fatalf("interleaved JSON: %s", data)
			}
			return value
		case <-time.After(5 * time.Second):
			t.Fatal("no protocol output")
			return nil
		}
	}
	request(1, "theme", "{}")
	if got := read(); string(got["id"]) != "1" || got["event"] != nil {
		t.Fatalf("unexpected initial output %s", got)
	}
	select {
	case value := <-out.lines:
		t.Fatalf("notification before opt-in: %s", value)
	case <-time.After(50 * time.Millisecond):
	}
	request(2, "events.subscribe", `{"enabled":true}`)
	sawResponse, sawEvent := false, false
	for !sawResponse || !sawEvent {
		value := read()
		if string(value["id"]) == "2" {
			sawResponse = true
			if string(value["result"]) != "{}" {
				t.Fatalf("subscribe response: %s", value)
			}
		}
		if string(value["event"]) == `"rex.changed"` {
			sawEvent = true
			if value["id"] != nil || len(value) != 1 {
				t.Fatalf("invalid notification %s", value)
			}
		}
	}
	request(3, "sessions", "{}")
	for {
		value := read()
		if string(value["id"]) == "3" {
			if strings.Contains(string(value["result"]), "/stale") {
				t.Fatal("live request returned disk cache")
			}
			break
		}
	}
	for id := 4; id < 20; id++ {
		request(id, "theme", "{}")
		for {
			if string(read()["id"]) == fmt.Sprint(id) {
				break
			}
		}
	}
	request(20, "events.subscribe", `{"enabled":false}`)
	for {
		if string(read()["id"]) == "20" {
			break
		}
	}
	select {
	case value := <-out.lines:
		t.Fatalf("notification after unsubscribe: %s", value)
	case <-time.After(50 * time.Millisecond):
	}
	// Subscribe again, then close stdin while the child is still streaming.
	request(21, "events.subscribe", `{"enabled":true}`)
	for {
		if string(read()["id"]) == "21" {
			break
		}
	}
	_ = send.Close()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("EOF leaked event watcher")
	}
	if out.interleaved.Load() {
		t.Fatal("concurrent output writes")
	}
}

func TestEventGenerationRejectsStaleCacheAndActivity(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	h := New(rex.Ctx{}, config.Default())
	_ = os.MkdirAll(filepath.Dir(h.launcherCachePath()), 0755)
	generation := h.cacheGeneration()
	h.storeLauncher(generation, []catalog.LauncherItem{{Path: "/old"}}, nil)
	h.invalidateActivity()
	if cached, ok := h.readLauncherCache(); !ok || cached.Items[0].Path != "/old" {
		t.Fatal("invalidation removed usable rows")
	}
	h.storeLauncher(generation, []catalog.LauncherItem{{Path: "/late-worker"}}, nil)
	if cached, ok := h.readLauncherCache(); !ok || cached.Items[0].Path != "/old" {
		t.Fatal("old worker replaced usable rows")
	}
	h.storeLauncher(h.cacheGeneration(), []catalog.LauncherItem{{Path: "/fresh"}}, nil)
	cached, ok := h.readLauncherCache()
	if !ok || cached.Items[0].Path != "/fresh" {
		t.Fatalf("fresh cache rejected: %+v", cached)
	}
}
