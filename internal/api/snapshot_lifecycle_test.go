package api

import (
	"bytes"
	"context"
	"fmt"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
)

func TestServeContextCancellationUnblocksColdRequests(t *testing.T) {
	for _, method := range []string{"sessions", "agents"} {
		t.Run(method, func(t *testing.T) {
			t.Setenv("XDG_CACHE_HOME", t.TempDir())
			h := New(rex.Ctx{}, config.Default())
			started, release := make(chan struct{}), make(chan struct{})
			var scans atomic.Int32
			h.loadSnapshot = func(_ rex.Ctx, launcher bool) ([]rex.AgentEntry, []catalog.LauncherItem, []hostHeader, error) {
				if scans.Add(1) == 1 {
					close(started)
				}
				<-release
				return []rex.AgentEntry{{Label: "Late agent"}}, []catalog.LauncherItem{{Kind: "session", Label: "Late session"}}, nil, nil
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			var output bytes.Buffer
			done := make(chan error, 1)
			input := strings.NewReader(fmt.Sprintf("{\"id\":1,\"method\":%q,\"params\":{}}\n", method))
			go func() { done <- h.ServeContext(ctx, input, &output) }()
			t.Cleanup(func() {
				cancel()
				close(release)
				h.cacheMu.Lock()
				started := h.refreshDone != nil
				h.cacheMu.Unlock()
				if started {
					waitSnapshot(t, h)
				}
			})
			select {
			case <-started:
			case <-time.After(time.Second):
				t.Fatal("cold request did not start discovery")
			}
			cancel()
			select {
			case err := <-done:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(time.Second):
				t.Fatal("shutdown waited for first snapshot loader")
			}
			if output.Len() != 0 {
				t.Fatalf("canceled request wrote a response: %s", output.String())
			}
			if scans.Load() != 1 {
				t.Fatalf("scans = %d, want one bounded worker", scans.Load())
			}
		})
	}
}

func TestFailedHostMergeKeepsSessionsBeforeStableFolders(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	h := New(rex.Ctx{}, config.Default())
	h.launcherLoaded = true
	h.launcher.Items = []catalog.LauncherItem{
		{Kind: "session", ID: "session:remote", SessionID: "session:remote", Host: "remote"},
		{Kind: "dir", ID: "/remote", Path: "/remote", Host: "remote"},
	}
	fresh := []catalog.LauncherItem{
		{Kind: "session", ID: "session:local", SessionID: "session:local", Host: rex.LocalHostLabel, Local: true},
		{Kind: "dir", ID: "/local-one", Path: "/local-one", Host: rex.LocalHostLabel, Local: true},
		{Kind: "dir", ID: "/local-two", Path: "/local-two", Host: rex.LocalHostLabel, Local: true},
	}
	h.storeLauncher(h.cacheGeneration(), fresh, []hostHeader{
		{Label: rex.LocalHostLabel, Local: true, Reachable: true},
		{Label: "remote", Reachable: false},
	})
	ids := func(items []catalog.LauncherItem) []string {
		var result []string
		for _, item := range items {
			result = append(result, item.ID)
		}
		return result
	}
	want := []string{"session:local", "session:remote", "/local-one", "/local-two", "/remote"}
	cached, _ := h.readLauncherCache()
	if got := ids(cached.Items); !reflect.DeepEqual(got, want) {
		t.Fatalf("merged order = %v, want %v", got, want)
	}
	// MRU can reorder the merged sessions, but cannot move the folders.
	h.ranks = rex.SessionRecency{"remote\x00session:remote": 0}
	result, err := h.call("sessions", []byte(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	want[0], want[1] = want[1], want[0]
	if got := ids(result.(sessionsResult).Items); !reflect.DeepEqual(got, want) {
		t.Fatalf("MRU order = %v, want %v", got, want)
	}
	if got := ids(fresh); !reflect.DeepEqual(got, []string{"session:local", "/local-one", "/local-two"}) {
		t.Fatalf("merge changed fresh rows: %v", got)
	}
}
