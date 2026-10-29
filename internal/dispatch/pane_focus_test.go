package dispatch

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
)

func TestPaneSelectsRequestingClientWindow(t *testing.T) {
	for _, target := range []string{"pane", "pane_left", "pane_above", "pane_below"} {
		for _, failure := range []string{"", "describe", "missing-window", "select", "no-client"} {
			t.Run(target+"/"+failure, func(t *testing.T) {
				dir := t.TempDir()
				logPath := filepath.Join(dir, "calls")
				t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
				t.Setenv("XDG_CACHE_HOME", t.TempDir())
				t.Setenv("REX_TEST_LOG", logPath)
				t.Setenv("REX_TEST_FAIL_AT", failure)
				script := `#!/bin/sh
printf '%s\n' "$*" >> "$REX_TEST_LOG"
case "$1" in
  split) echo '{"block_ids":["new-pane","origin-pane"]}' ;;
  focus) ;;
  api)
    if [ "$REX_TEST_FAIL_AT" = describe ]; then echo 'description failed' >&2; exit 1; fi
    if [ "$REX_TEST_FAIL_AT" = missing-window ]; then echo '{"block":{}}'; else echo '{"block":{"window_id":"actual-window"}}'; fi ;;
  -C) if [ "$REX_TEST_FAIL_AT" = select ]; then echo 'client selection failed' >&2; exit 1; fi ;;
  *) echo 'unexpected command' >&2; exit 1 ;;
esac
`
				if err := os.WriteFile(filepath.Join(dir, "rex"), []byte(script), 0o755); err != nil {
					t.Fatal(err)
				}
				previous := rex.Ctx{Session: "previous-session", Block: "previous-pane"}
				rex.WriteLastPane(previous)
				ctx := rex.Ctx{Session: "origin-session", Block: "origin-pane", Client: "requested-client"}
				if failure == "no-client" {
					ctx.Client = ""
				}
				err := Dispatch(target, "/demo/project", ctx, config.Default())
				wantFailure := failure != "" && failure != "no-client"
				if (err != nil) != wantFailure {
					t.Fatalf("error = %v, want failure %v", err, wantFailure)
				}
				log, err := os.ReadFile(logPath)
				if err != nil {
					t.Fatal(err)
				}
				calls := strings.Split(strings.TrimSpace(string(log)), "\n")
				want := []string{
					"split -s origin-session -b origin-pane --split=" + SplitDirection(target) + " -c /demo/project --json",
					"focus -s origin-session new-pane",
				}
				if ctx.Client != "" {
					want = append(want, `api call -s origin-session session.describe_block {"block_id":"new-pane"}`)
					if failure != "describe" && failure != "missing-window" {
						want = append(want, "-C requested-client do session.select session_id=origin-session window_id=actual-window")
					}
				}
				if strings.Join(calls, "\n") != strings.Join(want, "\n") {
					t.Fatalf("commands = %q, want %q", calls, want)
				}
				history, err := rex.LastPane()
				wantHistory := rex.Pane{Session: ctx.Session, Block: ctx.Block}
				if wantFailure {
					wantHistory = rex.Pane{Session: previous.Session, Block: previous.Block}
				}
				if err != nil || history != wantHistory {
					t.Fatalf("history = %+v, error = %v, want %+v", history, err, wantHistory)
				}
			})
		}
	}
}
