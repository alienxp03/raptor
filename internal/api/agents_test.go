package api

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
)

func TestAgentsListSearchAndJump(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, "calls")
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("REX_TEST_LOG", log)
	script := `#!/bin/sh
if [ "$1" = do ]; then
 printf '%s' '{"sessions":[{"session_id":"s","label":"Project","windows":[{"window_id":"w","label":"Build","blocks":[{"block_id":"b","records":[{"app":"pi","state":"idle","title":"Fix login"},{"id":"review","app":"codex","state":"blocked","title":"Review"}]}]}]}]}'
 exit 0
fi
printf '%s\n' "$*" >> "$REX_TEST_LOG"
case "$*" in
 'api call -s s session.list_blocks '*) echo '{"blocks":[{"block_id":"b","window_id":"w","creator_name":"com.superlogical.terminal"}]}' ;;
esac
`
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	h := New(rex.Ctx{Session: "s", Client: "origin-client"}, config.Default())
	for _, tt := range []struct {
		query string
		count int
	}{{"", 2}, {"login", 1}, {"codex", 1}, {"zzzzzz", 0}} {
		params, _ := json.Marshal(map[string]string{"query": tt.query})
		raw, err := h.call("agents", params)
		if err != nil {
			t.Fatal(err)
		}
		result := raw.(agentsResult)
		if len(result.Items) != tt.count || result.Items == nil || result.Targets == nil || len(result.Targets) != 0 || result.Target != config.Default().Enter {
			t.Fatalf("result=%+v", result)
		}
	}
	if _, err := h.call("agents.jump", json.RawMessage(`{"session_id":"s","window_id":"w","block_id":"b"}`)); err != nil {
		t.Fatal(err)
	}
	calls, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	want := "api call -s s session.list_blocks {\"session_id\":\"s\"}\napi call -s s session.focus_block {\"block_id\":\"b\",\"session_id\":\"s\"}\n-C origin-client do session.select session_id=s window_id=w\n"
	if string(calls) != want {
		t.Fatalf("calls=%s want=%s", calls, want)
	}
}

func TestAgentsInvalidParams(t *testing.T) {
	h := New(rex.Ctx{}, config.Default())
	for _, tt := range []struct{ method, params string }{
		{"agents", `{"query":5}`},
		{"agents.jump", `{}`},
		{"agents.jump", `{"session_id":"s"}`},
		{"agents.jump", `{"session_id":"s","window_id":"w"}`},
		{"agents.jump", `{"session_id":"s","window_id":"w","block_id":5}`},
		{"agents.jump", `{"session_id":" ","window_id":"w","block_id":"b"}`},
	} {
		if _, err := h.call(tt.method, json.RawMessage(tt.params)); err == nil {
			t.Fatalf("accepted %s %s", tt.method, tt.params)
		}
	}
}

func TestAgentsEmptyWireShape(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte("#!/bin/sh\nprintf '%s' '{}'\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	h := New(rex.Ctx{}, config.Default())
	raw, err := h.call("agents", json.RawMessage(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(raw)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"items":[]`) || !strings.Contains(string(data), `"targets":[]`) {
		t.Fatalf("result=%s", data)
	}
}
