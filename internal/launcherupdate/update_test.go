package launcherupdate

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestSinceFencesByScanStart(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	Record(Session{ID: "new-session", Label: "new-worktree", Host: "This Mac", Local: true, Path: "/wt/new"})
	after := time.Now()
	entries := Since(after.Add(-time.Minute))
	if len(entries) != 1 || entries[0].ID != "new-session" || entries[0].Label != "new-worktree" {
		t.Fatalf("pre-creation scan must see the creation: %v", entries)
	}
	if entries := Since(after); len(entries) != 0 {
		t.Fatalf("a scan started after the creation is authoritative: %v", entries)
	}
	// A second reader (new resident process) sees the same disk journal.
	if entries := Since(time.Time{}); len(entries) != 1 {
		t.Fatalf("cross-process read lost the creation: %v", entries)
	}
}

func TestRecordIgnoresIncompleteIdentity(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	Record(Session{ID: "", Label: "guess"})
	Record(Session{ID: "sid", Label: ""})
	if entries := Since(time.Time{}); len(entries) != 0 {
		t.Fatalf("incomplete identities must not be recorded: %v", entries)
	}
}

func TestSinceExpiresOldCreations(t *testing.T) {
	cache := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", cache)
	dir := filepath.Join(cache, "raptor", "launcher-creations")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	stale := `{"id":"old","label":"old","created":"2020-01-01T00:00:00Z"}`
	if err := os.WriteFile(filepath.Join(dir, "expired.json"), []byte(stale), 0o644); err != nil {
		t.Fatal(err)
	}
	if entries := Since(time.Time{}); len(entries) != 0 {
		t.Fatalf("expired creations must not surface: %v", entries)
	}
}
