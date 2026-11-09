package dispatch

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/pullrequest"
	"github.com/alienxp03/raptor/internal/rex"
)

func setupFixture(t *testing.T) (string, string, rex.Ctx) {
	t.Helper()
	root := t.TempDir()
	repo, path := filepath.Join(root, "repo"), filepath.Join(root, "tree")
	if err := os.Mkdir(repo, 0700); err != nil {
		t.Fatal(err)
	}
	git := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = repo
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%v: %s", err, out)
		}
	}
	git("init", "-b", "main")
	git("-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "fixture")
	cfg := filepath.Join(root, "wt.toml")
	if err := os.WriteFile(cfg, []byte("[pre-start]\ninstall = \"true\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WORKTRUNK_CONFIG_PATH", filepath.Join(root, "empty.toml"))
	t.Setenv("WORKTRUNK_SYSTEM_CONFIG_PATH", filepath.Join(root, "empty.toml"))
	t.Setenv("WORKTRUNK_PROJECT_CONFIG_PATH", cfg)
	t.Setenv("XDG_STATE_HOME", filepath.Join(root, "state"))
	t.Setenv("XDG_CACHE_HOME", filepath.Join(root, "cache"))
	plan, err := pullrequest.PreflightLocal(repo)
	if err != nil {
		t.Fatal(err)
	}
	git("worktree", "add", "-b", "local", path)
	if err := plan.Register(path, "local", "main"); err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(root, "calls")
	t.Setenv("LOCAL_REX_LOG", log)
	t.Setenv("LOCAL_CWD", path)
	script := `#!/bin/sh
printf '%s\n' "$*" >> "$LOCAL_REX_LOG"
case "$1" in
 split) echo '{"block_ids":["new-pane"]}';;
 focus) :;;
 api) echo '{"block":{"window_id":"new-window"}}';;
 session) echo '{"windows":[{"window_id":"new-window"}]}';;
 do) echo "$LOCAL_CWD";;
 -C) [ -z "$LOCAL_SELECT_FAIL" ];;
 *) exit 8;;
esac
`
	bin := filepath.Join(root, "bin")
	if err := os.Mkdir(bin, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bin, "rex"), []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	return path, log, rex.Ctx{Session: "origin", Block: "active-agent", Client: "client"}
}

func TestConfiguredHereNeverInjects(t *testing.T) {
	path, log, ctx := setupFixture(t)
	err := Dispatch("here", path, ctx, config.Default())
	if err == nil || !strings.Contains(err.Error(), "Session or Tab") || !strings.Contains(err.Error(), "preserved") {
		t.Fatal(err)
	}
	if _, err := os.Stat(log); !os.IsNotExist(err) {
		t.Fatal("Here called Rex")
	}
}

func TestConfiguredPaneStartupAndSelectionGate(t *testing.T) {
	for _, failure := range []string{"", "selection"} {
		t.Run(failure, func(t *testing.T) {
			path, log, ctx := setupFixture(t)
			t.Setenv("LOCAL_SELECT_FAIL", failure)
			err := Dispatch("pane_right", path, ctx, config.Default())
			if (err != nil) != (failure != "") {
				t.Fatal(err)
			}
			calls, _ := os.ReadFile(log)
			if !strings.Contains(string(calls), "--json -- /bin/sh -c") || !strings.Contains(string(calls), " setup --path ") || strings.Contains(string(calls), "send ") {
				t.Fatalf("wrong commands: %s", calls)
			}
			files, _ := filepath.Glob(filepath.Join(os.Getenv("XDG_STATE_HOME"), "raptor", "pullrequest", "*.json"))
			if len(files) != 1 {
				t.Fatal(files)
			}
			data, _ := os.ReadFile(files[0])
			var state struct {
				Released bool `json:"released"`
			}
			if err := json.Unmarshal(data, &state); err != nil {
				t.Fatal(err)
			}
			if state.Released != (failure == "") {
				t.Fatalf("released=%v", state.Released)
			}
			t.Setenv("LOCAL_SELECT_FAIL", "")
			if err := Dispatch("pane_right", path, ctx, config.Default()); err != nil {
				t.Fatal(err)
			}
			calls, _ = os.ReadFile(log)
			if strings.Count(string(calls), "split -s") != 1 {
				t.Fatalf("retry duplicated pane: %s", calls)
			}
		})
	}
}
