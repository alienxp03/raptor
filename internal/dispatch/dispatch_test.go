package dispatch

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
)

func TestShellCDTreatsPathAsData(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "demo's $(touch SENTINEL); project")
	if err := os.Mkdir(path, 0o755); err != nil {
		t.Fatal(err)
	}
	command, err := shellCD("sh", path)
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("sh", "-c", command+"pwd")
	cmd.Dir = root
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("cd failed: %v: %s", err, out)
	}
	got, _ := filepath.EvalSymlinks(strings.TrimSpace(string(out)))
	want, _ := filepath.EvalSymlinks(path)
	if got != want {
		t.Fatalf("changed to %q, want %q", got, want)
	}
	if _, err := os.Stat(filepath.Join(root, "SENTINEL")); !os.IsNotExist(err) {
		t.Fatal("path executed as a shell command")
	}
	for _, path := range []string{"demo\ncommand", "demo\x1bcommand", "demo\x03command"} {
		if _, err := shellCD("sh", path); err == nil {
			t.Fatal("accepted terminal control input")
		}
	}
	for _, shell := range []string{"nu", "elvish"} {
		if _, err := shellCD(shell, "demo's project"); err == nil {
			t.Fatal("accepted an unescaped quote for " + shell)
		}
	}
}

func TestMissingClientDoesNotCreateSession(t *testing.T) {
	// No Rex binary exists here: validation must fail before any Rex command.
	t.Setenv("PATH", t.TempDir())
	err := Dispatch("session", "/demo/project", rex.Ctx{}, config.Default())
	if err == nil || err.Error() != "no client context" {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestDispatchNavigation(t *testing.T) {
	for _, target := range []string{"tab", "pane_right", "pane_below", "session"} {
		for _, fail := range []bool{false, true} {
			name := target
			if fail {
				name += "-failure"
			}
			t.Run(name, func(t *testing.T) {
				dir := t.TempDir()
				t.Setenv("XDG_CACHE_HOME", t.TempDir())
				t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
				if fail {
					t.Setenv("REX_TEST_FAIL", "1")
				} else {
					t.Setenv("REX_TEST_FAIL", "")
				}
				script := `#!/bin/sh
case "$*" in
  'ls --json') echo '{"sessions":[{"session_id":"target-session","label":"project"}]}' ;;
  'window new '*) echo '{"window_id":"new-window"}' ;;
  'split '*) echo '{"block_ids":["new-pane","origin-pane"]}' ;;
  'api call '*session.describe_block*) echo '{"block":{"window_id":"new-window"}}' ;;
  'focus '*)
    if [ "$REX_TEST_FAIL" = 1 ]; then exit 1; fi
    case "$*" in *' -b '*) echo 'invalid focus flag' >&2; exit 1;; esac ;;
  *session.select*) if [ "$REX_TEST_FAIL" = 1 ]; then exit 1; fi ;;
esac
`
				if err := os.WriteFile(filepath.Join(dir, "rex"), []byte(script), 0o755); err != nil {
					t.Fatal(err)
				}
				ctx := rex.Ctx{Session: "origin-session", Block: "origin-pane", Client: "client"}
				err := Dispatch(target, "/tmp/project", ctx, config.Default())
				if (err != nil) != fail {
					t.Fatalf("error = %v, want failure %v", err, fail)
				}
			})
		}
	}
}
