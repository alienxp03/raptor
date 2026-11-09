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
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	dir := t.TempDir()
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	ssh := "#!/bin/sh\ncase \"$*\" in\n  *'zoxide query -l'*) printf '%s\\n' /home/azuan/workspace/hnhiring ;;\nesac\n"
	if err := os.WriteFile(filepath.Join(dir, "ssh"), []byte(ssh), 0o755); err != nil {
		t.Fatal(err)
	}
	script := `#!/bin/sh
case "$*" in
  'api call hosts.list') echo '{"hosts":[{"id":"host:1","label":"hades"}]}' ;;
  '-S hades --timeout 3s ls --json') echo '{"sessions":[{"session_id":"r1","label":"wispy-brook"}]}' ;;
  'ls --json') echo '{"sessions":[{"session_id":"a","label":"Project"},{"session_id":"b","label":"Tools"}]}' ;;
  'do'*) echo '{"sessions":[]}' ;;
  '-S hades --timeout 4s do'*) echo '{"sessions":[]}' ;;
esac
`
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	zoxide := "#!/bin/sh\nprintf '%s\\n' /Users/azuan/Workspace/Projects\nprintf '%s\\n' /Users/azuan/.dotfiles\n"
	if err := os.WriteFile(filepath.Join(dir, "zoxide"), []byte(zoxide), 0o755); err != nil {
		t.Fatal(err)
	}
	h := New(rex.Ctx{Session: "a"}, config.Default())
	for _, tt := range []struct {
		query string
		kinds []string
		ids   []string
	}{
		{"", []string{"session", "session", "session", "dir", "dir", "dir"},
			[]string{"a", "b", "r1", "/Users/azuan/Workspace/Projects", "/Users/azuan/.dotfiles", "/home/azuan/workspace/hnhiring"}},
		{"project", []string{"session", "dir"}, []string{"a", "/Users/azuan/Workspace/Projects"}},
		{"wispy", []string{"session"}, []string{"r1"}},
		{"zzzz", []string{}, []string{}},
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
			kinds := make([]string, 0, len(result.Items))
			for _, item := range result.Items {
				ids = append(ids, item.ID)
				kinds = append(kinds, item.Kind)
				if item.Kind == "session" {
					if item.Path != item.ID || item.SessionID == "" || item.SessionLabel == "" || item.Host == "" {
						t.Fatalf("incomplete session row shape: %+v", item)
					}
				} else {
					if item.Kind != "dir" || item.Path == "" || item.Label == "" || item.Host == "" {
						t.Fatalf("incomplete directory row shape: %+v", item)
					}
				}
			}
			labels := make([]string, 0, len(result.Hosts))
			for _, host := range result.Hosts {
				labels = append(labels, host.Label)
			}
			if !reflect.DeepEqual(ids, tt.ids) || !reflect.DeepEqual(kinds, tt.kinds) ||
				len(labels) != 2 || result.Items == nil || result.Targets == nil || result.Target != "session" {
				t.Fatalf("result ids = %v kinds = %v hosts = %v, want ids %v", ids, kinds, labels, tt.ids)
			}
		})
	}
}

func TestSessionsKeepUnreachableHostHeaderWithoutRows(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	dir := t.TempDir()
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	script := `#!/bin/sh
case "$*" in
  'api call hosts.list') echo '{"hosts":[{"id":"host:1","label":"gone"}]}' ;;
  '-S gone --timeout 3s ls --json') echo 'ssh: connect failed' >&2; exit 255 ;;
  'ls --json') echo '{"sessions":[{"session_id":"a","label":"Project"}]}' ;;
  'do'*) echo '{}' ;;
  *) exit 1 ;;
esac
`
	zoxide := "#!/bin/sh\nexit 0\n"
	if err := os.WriteFile(filepath.Join(dir, "zoxide"), []byte(zoxide), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	h := New(rex.Ctx{Session: "a"}, config.Default())
	var output bytes.Buffer
	input := `{"id":1,"method":"sessions","params":{"query":""}}`
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
	if len(result.Items) != 1 || result.Items[0].ID != "a" {
		t.Fatalf("items = %+v, want only the local session", result.Items)
	}
	if len(result.Hosts) != 2 {
		t.Fatalf("hosts = %+v, want local and unreachable headers", result.Hosts)
	}
	unreachable := result.Hosts[1]
	if unreachable.Label != "gone" || unreachable.Reachable || unreachable.Error == "" {
		t.Fatalf("unreachable header = %+v", unreachable)
	}
}

func TestSessionsJumpRoutesRowKinds(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
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

func TestSessionsJumpOnHostSelectsThroughRemoteAppClient(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	dir := t.TempDir()
	log := filepath.Join(dir, "calls")
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("REX_TEST_LOG", log)
	script := `#!/bin/sh
printf '%s\n' "$*" >> "$REX_TEST_LOG"
case "$*" in
  'api call client.inspect '*)
    echo '{"client":{"client_id":"client","info":{"kind":"app","label":"azuanz"}}}' ;;
  '-S hades api call client.list')
    echo '{"clients":[{"client_id":"remote-cli","info":{"kind":"cli","label":"other"}},{"client_id":"remote-app","info":{"kind":"app","label":"azuanz"}}]}' ;;
esac
`
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	h := New(rex.Ctx{Client: "client"}, config.Default())
	params := `{"kind":"session","session_id":"r1","host":"hades"}`
	if _, err := h.call("sessions.jump", json.RawMessage(params)); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(log)
	want := "api call client.inspect {\"client_id\":\"client\"}\n" +
		"-S hades api call client.list\n" +
		"-S hades -C remote-app do session.select session_id=r1\n"
	if err != nil || string(got) != want {
		t.Fatalf("calls = %q, want %q; error = %v", got, want, err)
	}
}

func TestSessionsCreateReusesLabelAndSelects(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	dir := t.TempDir()
	log := filepath.Join(dir, "calls")
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("REX_TEST_LOG", log)
	script := `#!/bin/sh
printf '%s\n' "$*" >> "$REX_TEST_LOG"
case "$*" in
  'ls --json') echo '{"sessions":[{"session_id":"existing","label":"raptor"}]}' ;;
esac
`
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	h := New(rex.Ctx{Client: "client"}, config.Default())
	params := `{"host":"","dir":"/Users/x/Workspace/raptor"}`
	result, err := h.call("sessions.create", json.RawMessage(params))
	if err != nil {
		t.Fatal(err)
	}
	payload, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	var created struct {
		SessionID string `json:"session_id"`
		Existing  bool   `json:"existing"`
	}
	if json.Unmarshal(payload, &created) != nil || created.SessionID != "existing" || !created.Existing {
		t.Fatalf("result = %s", payload)
	}
	got, err := os.ReadFile(log)
	want := "ls --json\n-C client do session.select session_id=existing\n"
	if err != nil || string(got) != want {
		t.Fatalf("calls = %q, want %q; error = %v", got, want, err)
	}
}

func TestSessionsCreateOnRemoteHost(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	dir := t.TempDir()
	log := filepath.Join(dir, "calls")
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("REX_TEST_LOG", log)
	script := `#!/bin/sh
printf '%s\n' "$*" >> "$REX_TEST_LOG"
case "$*" in
  '-S hades --timeout 3s ls --json') echo '{"sessions":[]}' ;;
  '-S hades new --json -c /home/azuan/workspace/hnhiring hnhiring')
    echo '{"session_id":"remote-1"}' ;;
  '-S hades api call client.list')
    echo '{"clients":[{"client_id":"remote-app","info":{"kind":"app","label":"azuanz"}}]}' ;;
  'api call client.inspect '*)
    echo '{"client":{"client_id":"client","info":{"kind":"app","label":"azuanz"}}}' ;;
esac
`
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	h := New(rex.Ctx{Client: "client"}, config.Default())
	params := `{"host":"hades","dir":"/home/azuan/workspace/hnhiring"}`
	if _, err := h.call("sessions.create", json.RawMessage(params)); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(log)
	want := "-S hades ls --json\n" +
		"-S hades new --json -c /home/azuan/workspace/hnhiring hnhiring\n" +
		"api call client.inspect {\"client_id\":\"client\"}\n" +
		"-S hades api call client.list\n" +
		"-S hades -C remote-app do session.select session_id=remote-1\n"
	if err != nil || string(got) != want {
		t.Fatalf("calls = %q, want %q; error = %v", got, want, err)
	}
}

func TestSessionsCreateRefusesToCloseOriginUnchanged(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	h := New(rex.Ctx{Session: "origin"}, config.Default())
	if _, err := h.call("sessions.create", json.RawMessage(`{"host":"","dir":""}`)); err == nil {
		t.Fatal("create without a directory must fail")
	}
}
