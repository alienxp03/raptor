package api

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
)

func TestContinuousEventsPublishProgressAndUnblockColdSearch(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	h := New(rex.Ctx{}, config.Default())
	started, release := make(chan int, 4), make(chan struct{})
	var scans atomic.Int32
	h.loadSnapshot = func(rex.Ctx, bool) ([]rex.AgentEntry, []catalog.LauncherItem, []hostHeader, error) {
		n := int(scans.Add(1))
		started <- n
		<-release
		return nil, []catalog.LauncherItem{{Label: fmt.Sprint(n)}}, nil, nil
	}
	t.Cleanup(func() { close(release); waitSnapshot(t, h) })
	rows := make(chan sessionsResult, 1)
	failure := make(chan error, 1)
	go func() {
		result, err := h.call("sessions", json.RawMessage(`{}`))
		if err != nil {
			failure <- err
			return
		}
		rows <- result.(sessionsResult)
	}()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("cold scan did not start")
	}
	for range 100 {
		h.requestRefresh()
	}
	release <- struct{}{}
	select {
	case <-started: // The dirty follow-up is still blocked.
	case <-time.After(time.Second):
		t.Fatal("follow-up scan did not start")
	}
	select {
	case result := <-rows:
		if result.Items[0].Label != "1" {
			t.Fatalf("cold request lost first complete snapshot: %+v", result)
		}
	case err := <-failure:
		t.Fatal(err)
	case <-time.After(time.Second):
		t.Fatal("cold request waited for continuous events to stop")
	}
	// More events must not suppress the next complete snapshot either.
	h.requestRefresh()
	release <- struct{}{}
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("second follow-up scan did not start")
	}
	cached, _ := h.readLauncherCache()
	if cached.Items[0].Label != "2" {
		t.Fatalf("continuous activity starved publication: %+v", cached)
	}
	release <- struct{}{}
	waitSnapshot(t, h)
	cached, _ = h.readLauncherCache()
	if scans.Load() != 3 || cached.Items[0].Label != "3" {
		t.Fatal("final coalesced refresh was lost")
	}
}

func TestPinMutationPatchesWarmSnapshotBeforeBackgroundRefresh(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	h := warmHandler()
	a, b := filepath.Join(t.TempDir(), "a"), filepath.Join(t.TempDir(), "b")
	h.launcher.Items = []catalog.LauncherItem{
		{Kind: "dir", Path: a, Local: true},
		{Kind: "dir", Path: b, Local: true},
	}
	started, release := make(chan int, 2), make(chan struct{})
	var scans atomic.Int32
	h.loadSnapshot = func(rex.Ctx, bool) ([]rex.AgentEntry, []catalog.LauncherItem, []hostHeader, error) {
		n := int(scans.Add(1))
		started <- n
		<-release
		return nil, []catalog.LauncherItem{{Kind: "dir", Path: a, Local: true}, {Kind: "dir", Path: b, Local: true, Pinned: n == 1}}, nil, nil
	}
	t.Cleanup(func() { close(release); waitSnapshot(t, h) })
	params, _ := json.Marshal(map[string]string{"path": b})
	if _, err := h.call("pins.toggle", params); err != nil {
		t.Fatal(err)
	}
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("pin refresh did not start")
	}
	result, err := h.call("sessions", json.RawMessage(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	rows := result.(sessionsResult).Items
	if rows[0].Path != b || !rows[0].Pinned {
		t.Fatalf("pin waited for Rex instead of patching cached rows: %+v", rows)
	}
	if _, err := h.call("pins.toggle", params); err != nil {
		t.Fatal(err)
	}
	release <- struct{}{}
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("unpin follow-up did not start")
	}
	cached, _ := h.readLauncherCache()
	for _, row := range cached.Items {
		if row.Pinned {
			t.Fatal("an older scan undid the unpin mutation")
		}
	}
	release <- struct{}{}
	waitSnapshot(t, h)
}
