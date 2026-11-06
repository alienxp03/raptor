package api

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
)

func TestSessionsGroupedListingAndSearch(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	script := `#!/bin/sh
case "$*" in
  'ls --json') echo '{"sessions":[{"session_id":"a","label":"Project"},{"session_id":"b","label":"Tools"}]}' ;;
  'api call -s a session.view '*) echo '{"active_window_id":"a2","windows":[{"window_id":"a1","label":"build server"},{"window_id":"a2","label":"shell"}]}' ;;
  'api call -s b session.view '*) echo '{"windows":[{"window_id":"b1","label":"build"}]}' ;;
  *) exit 1 ;;
esac
`
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	h := New(rex.Ctx{Session: "a"}, config.Default())
	for _, tt := range []struct {
		query string
		ids   []string
	}{
		{"", []string{"a", "a1", "a2", "b", "b1"}},
		{"build", []string{"a", "a1", "b", "b1"}},
		{"Project", []string{"a"}},
		{"zzzz", []string{}},
	} {
		t.Run("query="+tt.query, func(t *testing.T) {
			params, err := json.Marshal(map[string]string{"query": tt.query})
			if err != nil {
				t.Fatal(err)
			}
			var output bytes.Buffer
			input := `{"id":1,"method":"sessions","params":` + string(params) + `}`
			if err := h.Serve(strings.NewReader(input), &output); err != nil {
				t.Fatal(err)
			}
			var res wireResponse
			if err := json.Unmarshal(output.Bytes(), &res); err != nil || res.Error != "" {
				t.Fatalf("response = %s, error = %v", output.Bytes(), err)
			}
			var result sessionsResult
			if err := json.Unmarshal(res.Result, &result); err != nil {
				t.Fatal(err)
			}
			ids := make([]string, 0, len(result.Items))
			for _, item := range result.Items {
				ids = append(ids, item.ID)
				if item.Path != item.ID || item.SessionID == "" || item.SessionLabel == "" {
					t.Fatalf("incomplete row shape: %+v", item)
				}
			}
			if !reflect.DeepEqual(ids, tt.ids) || result.Items == nil || result.Targets == nil || len(result.Targets) != 0 || result.Target != config.Default().Enter {
				t.Fatalf("result = %+v, want IDs %v", result, tt.ids)
			}
		})
	}
}

func TestSessionsJumpRoutesRowKinds(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, "calls")
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("REX_TEST_LOG", log)
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$REX_TEST_LOG\"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	h := New(rex.Ctx{Client: "client"}, config.Default())
	for _, params := range []string{
		`{"kind":"session","session_id":"a"}`,
		`{"kind":"window","session_id":"a","window_id":"a2"}`,
	} {
		if _, err := h.call("sessions.jump", json.RawMessage(params)); err != nil {
			t.Fatal(err)
		}
	}
	got, err := os.ReadFile(log)
	want := "-C client do session.select session_id=a\n-C client do session.select session_id=a window_id=a2\n"
	if err != nil || string(got) != want {
		t.Fatalf("calls = %s, want %s; error = %v", got, want, err)
	}
}
