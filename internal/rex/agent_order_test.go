package rex

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/alienxp03/raptor/internal/paths"
)

func TestAgentGroupTimeOrder(t *testing.T) {
	now := time.Now().UTC()
	old := now.Add(-time.Hour)
	zero := time.Time{}
	entries := []AgentEntry{
		{Label: "idle", State: "idle", UpdatedAt: &now},
		{Label: "missing", State: "blocked"},
		{Label: "old", State: "blocked", UpdatedAt: &old},
		{Label: "work", State: "working", UpdatedAt: &now},
		{Label: "z-tie", State: "blocked", UpdatedAt: &now},
		{Label: "a-tie", State: "blocked", UpdatedAt: &now},
		{Label: "zero", State: "blocked", UpdatedAt: &zero},
	}
	SortGroups(entries)
	var labels []string
	for _, e := range entries {
		labels = append(labels, e.Label)
	}
	if want := []string{"z-tie", "a-tie", "old", "missing", "zero", "work", "idle"}; !reflect.DeepEqual(labels, want) {
		t.Fatalf("labels=%v", labels)
	}
}

func TestAgentNativeTimeAndCwd(t *testing.T) {
	for _, raw := range []string{"null", `"bad"`, `42`, `{}`, `"0001-01-01T00:00:00Z"`, `""`, ""} {
		if got := agentUpdatedAt(json.RawMessage(raw)); got != nil {
			t.Fatalf("raw=%s got=%v", raw, got)
		}
	}
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	now := time.Now().UTC()
	dir := filepath.Join(paths.CacheDir(), "agents")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	data := `{"pid":42,"app":"pi","name":"Named","block_id":"b","session_id":"s","updated_at":"` + now.Format(time.RFC3339Nano) + `"}`
	if err := os.WriteFile(filepath.Join(dir, "pi-42.json"), []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
	snapshot := `{"sessions":[{"session_id":"s","windows":[{"window_id":"w","blocks":[{"block_id":"b","process":{"foreground":{"pid":42,"name":"node","cwd":"/repo/sub"}},"records":[{"id":"z","app":"pi","owner":{"pid":42,"name":"node"},"state":"working","updated_at":"bad"},{"id":"a","app":"codex","state":"working","updated_at":"2025-01-01T00:00:00Z"},{"id":"b","app":"pi","state":"working"}]}]}]}]}`
	entries, err := decodeAgentEntries([]byte(snapshot), "s", now)
	if err != nil || len(entries) != 3 {
		t.Fatalf("entries=%v err=%v", entries, err)
	}
	if entries[0].AgentID != "a" || entries[1].AgentID != "z" || entries[2].AgentID != "b" || entries[1].Label != "Named" || entries[1].UpdatedAt != nil || entries[2].UpdatedAt != nil {
		t.Fatalf("entries=%+v", entries)
	}
	for _, e := range entries {
		if e.Cwd != "/repo/sub" {
			t.Fatalf("cwd=%q", e.Cwd)
		}
	}
}

func TestApplySessionActivity(t *testing.T) {
	entries := []SessionEntry{
		{Kind: "session", SessionID: "s"},
		{Kind: "window", SessionID: "s", ID: "w"},
		{Kind: "window", SessionID: "s", ID: "idle"},
		{Kind: "window", SessionID: "other", ID: "w"},
		{Kind: "session", SessionID: "empty", State: "blocked", Working: true},
	}
	agents := []AgentEntry{{SessionID: "s", WindowID: "w", State: "blocked"}, {SessionID: "s", WindowID: "w", State: "working"}, {SessionID: "s", WindowID: "idle", State: "idle"}}
	ApplySessionActivity(entries, agents)
	for i, want := range []struct {
		state   string
		working bool
	}{{"blocked", true}, {"blocked", true}, {"idle", false}, {"", false}, {"", false}} {
		if entries[i].State != want.state || entries[i].Working != want.working {
			t.Fatalf("row %d=%+v", i, entries[i])
		}
	}
	ApplySessionActivity(entries, nil)
	for _, e := range entries {
		if e.State != "" || e.Working {
			t.Fatalf("stale=%+v", e)
		}
	}
}
