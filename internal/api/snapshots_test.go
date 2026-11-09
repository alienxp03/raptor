package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
)

func waitSnapshot(t *testing.T, h *Handler) {
	t.Helper()
	h.cacheMu.Lock()
	done := h.refreshDone
	h.cacheMu.Unlock()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("snapshot worker did not finish")
	}
}

func warmHandler() *Handler {
	h := New(rex.Ctx{Session: "session:a", Block: "block:a"}, config.Default())
	h.activityLoaded, h.launcherLoaded = true, true
	h.activityAgents = []rex.AgentEntry{{SessionID: "session:a", BlockID: "block:a", Label: "Old agent"}}
	h.launcher.Items = []catalog.LauncherItem{
		{Kind: "session", SessionID: "session:b", Label: "Other", Local: true},
		{Kind: "session", SessionID: "session:a", Label: "Old", Local: true},
	}
	return h
}

func TestWarmQueriesDoNotWaitForLiveRefresh(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	h := warmHandler()
	started, release := make(chan struct{}), make(chan struct{})
	var scans atomic.Int32
	var once sync.Once
	unblock := func() { once.Do(func() { close(release) }) }
	t.Cleanup(func() { unblock(); waitSnapshot(t, h) })
	h.loadSnapshot = func(rex.Ctx, bool) ([]rex.AgentEntry, []catalog.LauncherItem, []hostHeader, error) {
		scans.Add(1)
		close(started)
		<-release
		return []rex.AgentEntry{{Label: "New agent"}}, []catalog.LauncherItem{{Label: "New"}}, nil, nil
	}
	notifications := make(chan string, 4)
	h.notify = func() error { notifications <- h.launcher.Items[0].Label; return nil }
	h.requestRefresh()
	<-started
	queriesDone := make(chan error, 1)
	go func() {
		for range 100 {
			for _, method := range []string{"sessions", "agents"} {
				if _, err := h.call(method, json.RawMessage(`{"query":"Old"}`)); err != nil {
					queriesDone <- err
					return
				}
			}
		}
		queriesDone <- nil
	}()
	select {
	case err := <-queriesDone:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("warm filtering blocked behind native snapshot")
	}
	select {
	case <-notifications:
		t.Fatal("notification before cache commit")
	default:
	}
	if scans.Load() != 1 {
		t.Fatalf("scans=%d", scans.Load())
	}
	unblock()
	waitSnapshot(t, h)
	if got := <-notifications; got != "New" {
		t.Fatalf("notified before publication: %s", got)
	}
	for range 100 {
		if _, err := h.call("sessions", json.RawMessage(`{}`)); err != nil {
			t.Fatal(err)
		}
	}
	if scans.Load() != 1 || len(notifications) != 0 {
		t.Fatal("query triggered another scan/notification")
	}
}

func TestRefreshCoalescesEventsAndDeliversFinalGeneration(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	h := warmHandler()
	started, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	unblock := func() { once.Do(func() { close(release) }) }
	t.Cleanup(func() { unblock(); waitSnapshot(t, h) })
	var scans atomic.Int32
	h.loadSnapshot = func(rex.Ctx, bool) ([]rex.AgentEntry, []catalog.LauncherItem, []hostHeader, error) {
		n := scans.Add(1)
		if n == 1 {
			close(started)
			<-release
		}
		return nil, []catalog.LauncherItem{{Label: fmt.Sprint(n)}}, nil, nil
	}
	var notifications atomic.Int32
	h.notify = func() error { notifications.Add(1); return nil }
	h.requestRefresh()
	<-started
	for range 100 {
		h.requestRefresh()
	}
	unblock()
	waitSnapshot(t, h)
	if scans.Load() != 2 || notifications.Load() != 2 {
		t.Fatalf("scans=%d notifications=%d", scans.Load(), notifications.Load())
	}
	cached, _ := h.readLauncherCache()
	if cached.Items[0].Label != "2" {
		t.Fatal("final event was lost")
	}
	if !h.activityLoaded || len(h.activityAgents) != 0 {
		t.Fatal("empty success not cached")
	}
}

func TestDiskSnapshotAnswersWhileFirstRefreshBlocked(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	h := New(rex.Ctx{}, config.Default())
	h.writeLauncherCache([]catalog.LauncherItem{{Label: "Disk"}}, nil)
	started, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	unblock := func() { once.Do(func() { close(release) }) }
	t.Cleanup(func() { unblock(); waitSnapshot(t, h) })
	var scans atomic.Int32
	h.loadSnapshot = func(rex.Ctx, bool) ([]rex.AgentEntry, []catalog.LauncherItem, []hostHeader, error) {
		scans.Add(1)
		close(started)
		<-release
		return nil, nil, nil, errors.New("offline")
	}
	result, err := h.call("sessions", json.RawMessage(`{}`))
	if err != nil || result.(sessionsResult).Items[0].Label != "Disk" {
		t.Fatalf("disk result=%v err=%v", result, err)
	}
	<-started
	for range 100 {
		if _, err := h.call("sessions", json.RawMessage(`{}`)); err != nil {
			t.Fatal(err)
		}
	}
	unblock()
	waitSnapshot(t, h)
	result, err = h.call("sessions", json.RawMessage(`{}`))
	if err != nil || result.(sessionsResult).Items[0].Label != "Disk" || scans.Load() != 1 {
		t.Fatalf("failed refresh lost disk rows: %v %v", result, err)
	}
}

func TestContextRecomputesOriginWithoutMutatingSnapshot(t *testing.T) {
	h := warmHandler()
	base := append([]catalog.LauncherItem(nil), h.launcher.Items...)
	for _, session := range []string{"session:a", "session:b", "session:a"} {
		_, err := h.call("context", json.RawMessage(fmt.Sprintf(`{"session":%q,"block":"block:a"}`, session)))
		if err != nil {
			t.Fatal(err)
		}
		result, err := h.call("sessions", json.RawMessage(`{}`))
		if err != nil {
			t.Fatal(err)
		}
		items := result.(sessionsResult).Items
		if items[0].SessionID != session || !items[0].Active || items[1].Active {
			t.Fatalf("origin=%s rows=%+v", session, items)
		}
		agents, err := h.call("agents", json.RawMessage(`{}`))
		if err != nil || agents.(agentsResult).Items[0].Active != (session == "session:a") {
			t.Fatalf("agents=%v err=%v", agents, err)
		}
	}
	for i, item := range h.launcher.Items {
		if item != base[i] {
			t.Fatal("filter mutated base snapshot")
		}
	}
	if h.activityAgents[0].Active {
		t.Fatal("agent filtering mutated base")
	}
}

func TestServeCancellationDoesNotWaitForBackgroundSnapshot(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	for _, eof := range []bool{false, true} {
		t.Run(fmt.Sprint(eof), func(t *testing.T) {
			h := warmHandler()
			started, release := make(chan struct{}), make(chan struct{})
			var once sync.Once
			unblock := func() { once.Do(func() { close(release) }) }
			t.Cleanup(func() { unblock(); waitSnapshot(t, h) })
			h.loadSnapshot = func(rex.Ctx, bool) ([]rex.AgentEntry, []catalog.LauncherItem, []hostHeader, error) {
				close(started)
				<-release
				return nil, nil, nil, nil
			}
			var notifications atomic.Int32
			h.notify = func() error { notifications.Add(1); return nil }
			h.requestRefresh()
			<-started
			input, writer := io.Pipe()
			defer input.Close()
			defer writer.Close()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan error, 1)
			go func() { done <- h.ServeContext(ctx, input, io.Discard) }()
			if eof {
				_ = writer.Close()
			} else {
				cancel()
			}
			select {
			case err := <-done:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(time.Second):
				t.Fatal("shutdown waited for snapshot")
			}
			unblock()
			waitSnapshot(t, h)
			if notifications.Load() != 0 {
				t.Fatal("old worker notified after shutdown")
			}
			if h.launcher.Items[0].Label != "Other" {
				t.Fatal("old worker published after shutdown")
			}
		})
	}
}

func TestColdSuccessfulEmptySnapshotOnlyScansOnce(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	h := New(rex.Ctx{}, config.Default())
	var scans int
	h.loadSnapshot = func(rex.Ctx, bool) ([]rex.AgentEntry, []catalog.LauncherItem, []hostHeader, error) {
		scans++
		return nil, nil, nil, nil
	}
	for range 100 {
		for _, method := range []string{"sessions", "agents"} {
			if _, err := h.call(method, json.RawMessage(`{}`)); err != nil {
				t.Fatal(err)
			}
		}
	}
	if scans != 1 {
		t.Fatalf("empty snapshot scans=%d", scans)
	}
}

func TestWarmQueriesMakeNoNativeCalls(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, "calls")
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("SNAPSHOT_CALLS", log)
	for _, name := range []string{"rex", "ssh", "zoxide"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\necho called >> \"$SNAPSHOT_CALLS\"\nexit 1\n"), 0755); err != nil {
			t.Fatal(err)
		}
	}
	h := warmHandler()
	// Short, unresolved origin must not cause per-row target.resolve calls.
	h.ctx.Session = "a"
	h.launcher.Items[0].Active = true // stale origin flags must be ignored
	for range 100 {
		for _, method := range []string{"sessions", "agents"} {
			if _, err := h.call(method, json.RawMessage(`{"query":"O"}`)); err != nil {
				t.Fatal(err)
			}
		}
	}
	if data, err := os.ReadFile(log); !os.IsNotExist(err) {
		t.Fatalf("warm query invoked native helper: %s (%v)", data, err)
	}
}

func TestContextChangeDuringRefreshRejectsOldPublication(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	h := warmHandler()
	started, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	unblock := func() { once.Do(func() { close(release) }) }
	t.Cleanup(func() { unblock(); waitSnapshot(t, h) })
	var scans atomic.Int32
	h.loadSnapshot = func(origin rex.Ctx, launcher bool) ([]rex.AgentEntry, []catalog.LauncherItem, []hostHeader, error) {
		n := scans.Add(1)
		if origin.Session != "" {
			return nil, nil, nil, errors.New("origin leaked into base snapshot")
		}
		if n == 1 {
			close(started)
			<-release
		}
		return []rex.AgentEntry{{SessionID: "session:b", BlockID: "block:b"}}, []catalog.LauncherItem{{Kind: "session", SessionID: "session:b", Local: true, Label: fmt.Sprint(n)}}, nil, nil
	}
	notifications := make(chan string, 4)
	h.notify = func() error { notifications <- h.launcher.Items[0].Label; return nil }
	h.requestRefresh()
	<-started
	if _, err := h.call("context", json.RawMessage(`{"session":"session:b","block":"block:b"}`)); err != nil {
		t.Fatal(err)
	}
	unblock()
	waitSnapshot(t, h)
	if scans.Load() != 2 || len(notifications) != 1 || <-notifications != "2" {
		t.Fatal("old presentation published or final update lost")
	}
	result, err := h.call("agents", json.RawMessage(`{}`))
	if err != nil || !result.(agentsResult).Items[0].Active {
		t.Fatalf("new origin=%v err=%v", result, err)
	}
}

func TestFailedHostRetainsRowsButSuccessfulEmptyHostClearsRows(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	h := warmHandler()
	h.launcher.Items[0].Host = "remote"
	h.launcher.Items[1].Host = "local"
	h.storeLauncher(h.cacheGeneration(), nil, []hostHeader{{Label: "remote", Reachable: false}, {Label: "local", Local: true, Reachable: true}})
	cached, _ := h.readLauncherCache()
	if len(cached.Items) != 1 || cached.Items[0].Host != "remote" {
		t.Fatalf("rows=%+v", cached.Items)
	}
	h.storeLauncher(h.cacheGeneration(), nil, []hostHeader{{Label: "remote", Reachable: true}})
	cached, _ = h.readLauncherCache()
	if len(cached.Items) != 0 || !h.launcherLoaded {
		t.Fatalf("successful empty snapshot=%+v", cached)
	}
}

func BenchmarkWarmSnapshotQueries(b *testing.B) {
	h := warmHandler()
	for i := range 100 {
		h.launcher.Items = append(h.launcher.Items, catalog.LauncherItem{Kind: "session", Label: fmt.Sprintf("Project %d", i), SessionID: fmt.Sprintf("session:%d", i), Local: true})
		h.activityAgents = append(h.activityAgents, rex.AgentEntry{Label: fmt.Sprintf("Project %d", i), SessionID: fmt.Sprintf("session:%d", i)})
	}
	h.loadSnapshot = func(rex.Ctx, bool) ([]rex.AgentEntry, []catalog.LauncherItem, []hostHeader, error) {
		panic("warm query called backend")
	}
	for _, method := range []string{"sessions", "agents"} {
		b.Run(method, func(b *testing.B) {
			b.ReportAllocs()
			for b.Loop() {
				if _, err := h.call(method, json.RawMessage(`{"query":"Pro"}`)); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}
