package rex

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alienxp03/raptor/internal/paths"
)

func TestAgentRecordsSameTabAndFallbacks(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	data := []byte(`{"sessions":[{"session_id":"s","label":"Project","active_window_id":"w","windows":[{"window_id":"w","label":"Build","focused_block_id":"b","blocks":[{"block_id":"b","title":"terminal","records":[{"id":"z","app":"Claude-Code","state":"blocked","msg":"Permission"},{"id":"a","effective_app":"codex","state":"working","title":"Task"},{"app":"pi","state":"idle"},{"id":"done","app":"pi","state":"done"},{"id":"error","app":"pi","state":"error"},{"id":"other","app":"cargo","state":"working"}]},{"block_id":"c","records":[{"app":"@openai/codex","state":"unknown"}]}]}]}]}`)
	entries, err := decodeAgentEntries(data, "s", time.Now())
	if err != nil || len(entries) != 6 {
		t.Fatalf("entries=%+v err=%v", entries, err)
	}
	for i, want := range []struct{ path, app, label, state string }{{"b#z", "claude", "terminal", "blocked"}, {"b#a", "codex", "Task", "working"}, {"b#", "pi", "terminal", "idle"}, {"b#done", "pi", "terminal", "idle"}, {"b#error", "pi", "terminal", "idle"}, {"c#", "codex", "codex", "idle"}} {
		e := entries[i]
		if e.Path != want.path || e.App != want.app || e.Label != want.label || e.State != want.state || e.Kind != "agent" || e.Active != (i < 5) || e.WindowLabel != "Build" || e.SessionLabel != "Project" {
			t.Fatalf("row %d=%+v", i, e)
		}
	}
	for _, data := range []string{`{}`, `{"sessions":[]}`, `{"sessions":[{"windows":[]}]}`} {
		got, err := decodeAgentEntries([]byte(data), "", time.Now())
		if err != nil || got == nil || len(got) != 0 {
			t.Fatalf("empty=%+v err=%v", got, err)
		}
	}
	if _, err := decodeAgentEntries([]byte(`{`), "", time.Now()); err == nil {
		t.Fatal("expected parse error")
	}
}

func TestAgentWindowContextUsesFocusedTitleForGeneratedLabels(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	for _, tt := range []struct{ label, focused, want string }{
		{"Window b0439b58", "b", "castty"},
		{"", "b", "castty"},
		{"My work", "b", "My work"},
		{"Window custom", "b", "Window custom"},
		{"Window b0439b58", "other", "Window b0439b58"},
	} {
		data, err := json.Marshal(map[string]any{"sessions": []any{map[string]any{
			"session_id": "s", "windows": []any{map[string]any{
				"window_id": "window:b0439b58", "label": tt.label, "focused_block_id": tt.focused,
				"blocks": []any{map[string]any{"block_id": "b", "title": "castty", "records": []any{map[string]any{"app": "pi", "state": "idle"}}}},
			}},
		}}})
		if err != nil {
			t.Fatal(err)
		}
		entries, err := decodeAgentEntries(data, "s", time.Now())
		if err != nil || len(entries) != 1 || entries[0].WindowLabel != tt.want {
			t.Fatalf("label=%q focused=%q entries=%+v err=%v", tt.label, tt.focused, entries, err)
		}
	}
}

func TestPiAgentNameValidation(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	dir := filepath.Join(paths.CacheDir(), "agents")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(dir, "pi-42.json")
	now := time.Now().UTC()
	for _, tt := range []struct {
		name   string
		change func(map[string]any)
		valid  bool
	}{
		{"valid", func(m map[string]any) {}, true},
		{"pid", func(m map[string]any) { m["pid"] = 43 }, false},
		{"block", func(m map[string]any) { m["block_id"] = "other" }, false},
		{"session", func(m map[string]any) { m["session_id"] = "other" }, false},
		{"app", func(m map[string]any) { m["app"] = "codex" }, false},
		{"stale", func(m map[string]any) { m["updated_at"] = now.Add(-16 * time.Second) }, false},
		{"future", func(m map[string]any) { m["updated_at"] = now.Add(time.Minute) }, false},
		{"missing timestamp", func(m map[string]any) { delete(m, "updated_at") }, false},
		{"invalid timestamp", func(m map[string]any) { m["updated_at"] = "bad" }, false},
		{"empty name", func(m map[string]any) { m["name"] = " " }, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			m := map[string]any{"pid": 42, "app": "pi", "name": " Named task ", "block_id": "b", "session_id": "s", "updated_at": now}
			tt.change(m)
			data, _ := json.Marshal(m)
			if err := os.WriteFile(file, data, 0o600); err != nil {
				t.Fatal(err)
			}
			got := piAgentName(42, "b", "s", now)
			if (got == "Named task") != tt.valid || (!tt.valid && got != "") {
				t.Fatalf("name=%q", got)
			}
		})
	}
	if err := os.WriteFile(file, []byte(`{`), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := piAgentName(42, "b", "s", now); got != "" {
		t.Fatalf("malformed name=%q", got)
	}
	// Metadata changes only the matching Pi record's name, not Codex or a
	// different process. It does not create any entries itself.
	m := `{"pid":42,"app":"pi","name":"Named task","block_id":"b","session_id":"s","updated_at":"` + now.Format(time.RFC3339Nano) + `"}`
	if err := os.WriteFile(file, []byte(m), 0o600); err != nil {
		t.Fatal(err)
	}
	snapshot := `{"sessions":[{"session_id":"s","windows":[{"window_id":"w","blocks":[{"block_id":"b","title":"terminal","records":[{"app":"pi","owner":{"pid":42},"state":"idle"},{"id":"other","app":"pi","owner":{"pid":43},"state":"idle"},{"id":"codex","app":"codex","owner":{"pid":42},"state":"idle"}]}]}]}]}`
	entries, err := decodeAgentEntries([]byte(snapshot), "s", now)
	if err != nil || len(entries) != 3 || entries[0].Label != "Named task" || entries[1].Label != "terminal" || entries[2].Label != "terminal" {
		t.Fatalf("entries=%+v err=%v", entries, err)
	}
}

func TestAgentStaleOwner(t *testing.T) {
	for _, tt := range []struct {
		process string
		live    bool
	}{
		{`null`, true},
		{`{"last_exit":{"exit_code":0}}`, false},
		{`{"foreground":{"pid":42,"name":"node"}}`, true},
		{`{"foreground":{"pid":42,"name":"zsh"}}`, false},
		{`{"foreground":{"pid":7,"name":"zsh"},"child":{"pid":7,"name":"zsh"}}`, false},
		{`{"foreground":{"pid":7,"name":"tool"},"child":{"pid":1,"name":"login"},"ancestors":[{"pid":42,"name":"node"},{"pid":1,"name":"login"}]}`, true},
		{`{"foreground":{"pid":7,"name":"tool"},"child":{"pid":1,"name":"login"}}`, true},
	} {
		var b agentBlock
		if err := json.Unmarshal([]byte(`{"process":`+tt.process+`}`), &b); err != nil {
			t.Fatal(err)
		}
		if got := liveAgentRecord(b, agentRecord{Owner: &agentProcess{PID: 42, Name: "node"}}); got != tt.live {
			t.Fatalf("process=%s live=%v", tt.process, got)
		}
	}
}

func TestJumpAgentExactPane(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, "calls")
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("REX_TEST_LOG", log)
	script := `#!/bin/sh
printf '%s\n' "$*" >> "$REX_TEST_LOG"
case "$*" in
 'api call -s s session.list_blocks '*) echo '{"blocks":[{"block_id":"b","window_id":"w","creator_name":"com.superlogical.terminal"},{"block_id":"other","window_id":"w","creator_name":"com.superlogical.onboarding"}]}' ;;
esac
`
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, client := range []string{"client-a", ""} {
		if err := JumpAgent(AgentEntry{SessionID: "s", WindowID: "w", BlockID: "b"}, client); err != nil {
			t.Fatal(err)
		}
	}
	for _, e := range []AgentEntry{{}, {SessionID: "s", WindowID: "wrong", BlockID: "b"}, {SessionID: "s", WindowID: "w", BlockID: "gone"}, {SessionID: "s", WindowID: "w", BlockID: "other"}} {
		if err := JumpAgent(e, "client-a"); err == nil {
			t.Fatalf("accepted %+v", e)
		}
	}
	calls, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(calls), "session.focus_block") != 2 || strings.Count(string(calls), "-C client-a do session.select session_id=s window_id=w") != 1 || !strings.Contains(string(calls), `session.focus_block {"block_id":"b","session_id":"s"}`) {
		t.Fatalf("calls=%s", calls)
	}
}

func TestAgentApps(t *testing.T) {
	for _, tt := range []struct{ app, want string }{
		{" Pi ", "pi"}, {"pi-coding-agent", "pi"}, {"@earendil-works/pi-coding-agent", "pi"},
		{"Codex", "codex"}, {"codex-cli", "codex"}, {"@openai/codex", "codex"},
		{"Claude", "claude"}, {"claude-code", "claude"}, {"@anthropic-ai/claude-code", "claude"},
		{"cargo", ""}, {"", ""},
	} {
		if got := normalizeAgentApp(tt.app); got != tt.want {
			t.Fatalf("app=%q got=%q", tt.app, got)
		}
	}
}

func TestAgentEntriesUsesOneBatch(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte("#!/bin/sh\n[ \"$1\" = do ] && [ \"$2\" = -e ] && [ \"$4\" = --json ] || exit 1\nprintf '%s' '{}'\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	entries, err := AgentEntries("s")
	if err != nil || entries == nil || len(entries) != 0 {
		t.Fatalf("entries=%v err=%v", entries, err)
	}
}
