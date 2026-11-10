package api

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/launcherupdate"
	"github.com/alienxp03/raptor/internal/rex"
)

func TestCreatedSessionVisibleOnFirstWarmRead(t *testing.T) {
	cache := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", cache)
	// A snapshot whose scan started before the creation cannot know about it.
	h := New(rex.Ctx{Session: "origin"}, config.Default())
	started := time.Now()
	h.commitLauncherAt([]catalog.LauncherItem{{Kind: "session", ID: "origin", SessionID: "origin", Label: "Origin", Local: true}},
		[]hostHeader{{Label: "This Mac", Local: true, Reachable: true}}, started)

	// The mutation records only an authoritative Rex result. It must appear on
	// the very next warm read, without waiting for a fresh multi-host scan.
	launcherupdate.Record(launcherupdate.Session{ID: "new-session", Label: "new-worktree", Host: "This Mac", Local: true, Path: "/wt/new"})
	var output bytes.Buffer
	if err := h.Serve(strings.NewReader(`{"id":1,"method":"sessions","params":{"query":""}}`), &output); err != nil {
		t.Fatal(err)
	}
	var response struct {
		Result struct {
			SelectedID string                 `json:"selected_id"`
			Items      []catalog.LauncherItem `json:"items"`
		} `json:"result"`
	}
	if err := json.Unmarshal(output.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	var created *catalog.LauncherItem
	for i, item := range response.Result.Items {
		if item.SessionID == "new-session" {
			created = &response.Result.Items[i]
		}
	}
	if created == nil || created.Label != "new-worktree" || !created.Local {
		t.Fatalf("first warm read lost the created session: %+v", response.Result.Items)
	}

	// The mutation response carries the same authoritative rows for native
	// clients to publish before hiding.
	output.Reset()
	if err := h.Serve(strings.NewReader(`{"id":2,"method":"sessions.create","params":{"host":"","dir":"/wt/new"}}`), &output); err != nil {
		t.Fatal(err)
	}
	var mutation struct {
		Result struct {
			SessionID     string                 `json:"session_id"`
			LauncherItems []catalog.LauncherItem `json:"launcher_items"`
		} `json:"result"`
	}
	if err := json.Unmarshal(output.Bytes(), &mutation); err != nil {
		t.Fatal(err)
	}
	if mutation.Result.SessionID == "" {
		t.Fatalf("sessions.create result changed shape: %s", output.String())
	}
	found := false
	for _, item := range mutation.Result.LauncherItems {
		if item.SessionID == "new-session" {
			found = true
		}
	}
	if !found {
		t.Fatalf("mutation response must include the created row: %+v", mutation.Result.LauncherItems)
	}
}

func TestOverlayDoesNotResurrectAfterAuthoritativeScan(t *testing.T) {
	cache := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", cache)
	launcherupdate.Record(launcherupdate.Session{ID: "gone", Label: "gone", Host: "This Mac", Local: true, Path: "/wt/gone"})
	created := time.Now()

	// A completed scan started after the creation owns the list. The overlay
	// must not re-add a session that scan no longer reports.
	h := New(rex.Ctx{Session: "origin"}, config.Default())
	h.commitLauncherAt([]catalog.LauncherItem{{Kind: "session", ID: "origin", SessionID: "origin", Label: "Origin", Local: true}},
		[]hostHeader{{Label: "This Mac", Local: true, Reachable: true}}, created.Add(time.Minute))

	var output bytes.Buffer
	if err := h.Serve(strings.NewReader(`{"id":1,"method":"sessions","params":{"query":""}}`), &output); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(output.String(), `"gone"`) {
		t.Fatalf("authoritative scan result was resurrected: %s", output.String())
	}
}

func TestLatePreCreationScanKeepsCreatedRow(t *testing.T) {
	cache := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", cache)
	h := New(rex.Ctx{Session: "origin"}, config.Default())
	started := time.Now()
	// The creation lands while a scan is in flight; the worker then publishes
	// rows that predate it. The warm cache must still expose the session.
	launcherupdate.Record(launcherupdate.Session{ID: "late", Label: "late", Host: "This Mac", Local: true, Path: "/wt/late"})
	h.commitLauncherAt([]catalog.LauncherItem{{Kind: "session", ID: "origin", SessionID: "origin", Label: "Origin", Local: true}},
		[]hostHeader{{Label: "This Mac", Local: true, Reachable: true}}, started)

	var output bytes.Buffer
	if err := h.Serve(strings.NewReader(`{"id":1,"method":"sessions","params":{"query":""}}`), &output); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), `"late"`) {
		t.Fatalf("in-flight pre-creation scan dropped a created session: %s", output.String())
	}
	// The on-disk cache is overlaid too, so a restarted resident host and the
	// standalone CLI see the same rows on their first read.
	data, err := os.ReadFile(filepath.Join(cache, "raptor", "launcher-cache.json"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), `"late"`) {
		t.Fatal("overlay must stay a read-time merge, not mutate the underlying cache")
	}
}
