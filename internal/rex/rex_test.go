package rex

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func fakeRex(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	log := filepath.Join(dir, "calls")
	t.Setenv("REX_TEST_LOG", log)
	script := `#!/bin/sh
printf '%s\n' "$*" >> "$REX_TEST_LOG"
case "$*" in
  *session.describe_block*)
    if [ "$REX_TEST_FAIL" = describe ]; then echo 'missing pane' >&2; exit 1; fi
    printf '%s\n' '{"block":{"window_id":"moved-window"}}';;
  *session.focus_block*)
    if [ "$REX_TEST_FAIL" = focus ]; then echo 'focus failed' >&2; exit 1; fi
    printf '%s\n' '{"revision":1}';;
  *session.select*)
    if [ "$REX_TEST_FAIL" = select ]; then echo 'selection failed' >&2; exit 1; fi;;
  'ls --json') printf '%s\n' '{"sessions":[{"session_id":"previous-session"}]}';;
esac
`
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return log
}

func TestSelectSessionRemembersOnlyOnSuccess(t *testing.T) {
	fakeRex(t)
	ctx := Ctx{Session: "current-session", Block: "current-pane", Client: "client"}
	WriteLast("previous-session")
	t.Setenv("REX_TEST_FAIL", "select")
	if err := SelectSession(ctx, "previous-session"); err == nil {
		t.Fatal("expected selection failure")
	}
	if got := readLastForTest(t); got != "previous-session" {
		t.Fatalf("state after failed selection = %q", got)
	}
	if _, err := LastPane(); err == nil {
		t.Fatal("failed selection wrote pane history")
	}
	t.Setenv("REX_TEST_FAIL", "")
	if err := SelectSession(ctx, "previous-session"); err != nil {
		t.Fatal(err)
	}
	if got := readLastForTest(t); got != ctx.Session {
		t.Fatalf("state after successful selection = %q", got)
	}
	if pane, err := LastPane(); err != nil || pane != (Pane{ctx.Session, ctx.Block}) {
		t.Fatalf("pane = %+v, err = %v", pane, err)
	}
}

func TestSelectLastRequiresClientContext(t *testing.T) {
	if _, err := SelectLast(Ctx{Session: "current-session"}); err == nil {
		t.Fatal("expected missing-client error")
	}
}

func TestSelectLastPane(t *testing.T) {
	for _, sameSession := range []bool{false, true} {
		t.Run(map[bool]string{false: "cross-session", true: "same-session"}[sameSession], func(t *testing.T) {
			log := fakeRex(t)
			ctx := Ctx{Session: "current-session", Block: "current-pane", Client: "client"}
			target := Ctx{Session: "previous-session", Block: "previous-pane"}
			if sameSession {
				target.Session = ctx.Session
			}
			WriteLast("unchanged-session")
			WriteLastPane(target)
			pane, err := SelectLastPane(ctx)
			if err != nil || pane != (Pane{target.Session, target.Block}) {
				t.Fatalf("pane = %+v, err = %v", pane, err)
			}
			if saved, err := LastPane(); err != nil || saved != (Pane{ctx.Session, ctx.Block}) {
				t.Fatalf("saved pane = %+v, err = %v", saved, err)
			}
			wantSession := ctx.Session
			if sameSession {
				wantSession = "unchanged-session"
			}
			if got := readLastForTest(t); got != wantSession {
				t.Fatalf("saved session = %q", got)
			}
			calls, _ := os.ReadFile(log)
			if !strings.Contains(string(calls), "window_id=moved-window") {
				t.Fatalf("did not select the pane's current window: %s", calls)
			}
		})
	}
}

func TestSelectLastPaneFailurePreservesHistory(t *testing.T) {
	for _, failure := range []string{"describe", "focus", "select"} {
		t.Run(failure, func(t *testing.T) {
			fakeRex(t)
			t.Setenv("REX_TEST_FAIL", failure)
			target := Ctx{Session: "previous-session", Block: "previous-pane"}
			WriteLastPane(target)
			WriteLast("previous-session")
			if _, err := SelectLastPane(Ctx{Session: "current-session", Block: "current-pane", Client: "client"}); err == nil {
				t.Fatal("expected failure")
			}
			if saved, _ := LastPane(); saved != (Pane{target.Session, target.Block}) {
				t.Fatalf("failure changed history: %+v", saved)
			}
			if got := readLastForTest(t); got != target.Session {
				t.Fatalf("failure changed session history: %q", got)
			}
		})
	}
}

func TestPaneHistoryRejectsMissingInvalidAndCurrentPane(t *testing.T) {
	fakeRex(t)
	ctx := Ctx{Session: "current-session", Block: "current-pane", Client: "client"}
	if _, err := SelectLastPane(ctx); err == nil {
		t.Fatal("accepted missing history")
	}
	WriteLastPane(ctx)
	if _, err := SelectLastPane(ctx); err == nil {
		t.Fatal("accepted already-focused pane")
	}
	if err := os.WriteFile(paneStatePath(), []byte(`{}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := LastPane(); err == nil {
		t.Fatal("accepted invalid history")
	}
}

func readLastForTest(t *testing.T) string {
	t.Helper()
	data, err := os.ReadFile(statePath())
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(data))
}
