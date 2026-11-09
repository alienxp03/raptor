package api

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
	"github.com/alienxp03/raptor/internal/worktree"
)

func TestPullRequestURLDoesNotResolveOriginPane(t *testing.T) {
	bin := t.TempDir()
	log := filepath.Join(bin, "rex-called")
	script := "#!/bin/sh\nprintf called > '" + log + "'\nexit 1\n"
	if err := os.WriteFile(filepath.Join(bin, "rex"), []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	h := New(rex.Ctx{Session: "origin", Block: "block"}, config.Default())
	_, err := h.call("pullrequests.resolve", json.RawMessage(`{"input":"https://github.com/demo/example/pull/0"}`))
	if err == nil {
		t.Fatal("invalid PR URL accepted")
	}
	if _, err := os.Stat(log); !os.IsNotExist(err) {
		t.Fatal("URL resolution inspected an unrelated origin pane")
	}
}

func TestPrepareRefusalDoesNotEnterOpenRecovery(t *testing.T) {
	repo := fixtureRepo(t)
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	if _, err := worktree.GitOut(repo, "remote", "add", "origin", "https://github.com/demo/example.git"); err != nil {
		t.Fatal(err)
	}
	project := os.Getenv("WORKTRUNK_PROJECT_CONFIG_PATH")
	if err := os.WriteFile(project, []byte("pre-switch = 'echo guard'\n"), 0600); err != nil {
		t.Fatal(err)
	}
	bin := t.TempDir()
	script := `#!/bin/sh
case "$1" in
api) printf '%s\n' '{"base":{"repo":{"full_name":"demo/example"}}}' ;;
pr) printf '%s\n' '{"number":23,"title":"Example PR","headRefName":"main","url":"https://github.com/demo/example/pull/23"}' ;;
*) exit 1 ;;
esac
`
	if err := os.WriteFile(filepath.Join(bin, "gh"), []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	params, _ := json.Marshal(map[string]string{"repo": repo, "input": "23"})
	result, err := New(rex.Ctx{}, config.Default()).call("pullrequests.prepare", params)
	if err == nil || !strings.Contains(err.Error(), "pre-switch") || result != nil {
		t.Fatalf("must retry Prepare, not Open: result=%+v error=%v", result, err)
	}
}

func TestPullRequestRequestValidation(t *testing.T) {
	h := New(rex.Ctx{}, config.Default())
	for _, tc := range []struct {
		method string
		params string
		want   string
	}{
		{"pullrequests.resolve", `{"input":23}`, "cannot unmarshal"},
		{"pullrequests.resolve", `{}`, "enter a GitHub"},
		{"pullrequests.prepare", `{"input":" "}`, "enter a GitHub"},
		{"pullrequests.open", `{}`, "worktree path is required"},
		{"pullrequests.open", `{"path":"/no-worktree","target":"here"}`, "session or tab"},
		{"pullrequests.open", `{"path":"/no-worktree","target":12}`, "cannot unmarshal"},
	} {
		t.Run(tc.method+tc.params, func(t *testing.T) {
			_, err := h.call(tc.method, json.RawMessage(tc.params))
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error = %v, want %q", err, tc.want)
			}
		})
	}
}
