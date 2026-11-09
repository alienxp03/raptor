package task

import (
	"os"
	"os/exec"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/pullrequest"
	"github.com/alienxp03/raptor/internal/worktree"
)

func TestTaskConfiguredSetupRunsBeforePi(t *testing.T) {
	repo, cfg, ctx, log := fixture(t)
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	config := os.Getenv("WORKTRUNK_PROJECT_CONFIG_PATH")
	if err := os.WriteFile(config, []byte("[pre-start]\ninstall = \"true\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	result, err := Start(ctx, cfg, repo, "")
	if err != nil {
		t.Fatal(err)
	}
	pending, err := pullrequest.LocalPending(result.Path)
	if err != nil || !pending {
		t.Fatalf("pending=%v: %v", pending, err)
	}
	data, _ := os.ReadFile(log)
	calls := string(data)
	if !strings.Contains(calls, "--\n/bin/sh\n-c\n") || !strings.Contains(calls, " setup --path ") || !strings.Contains(calls, " && { ") || !strings.Contains(calls, `exec "${SHELL:-/bin/sh}" -l`) {
		t.Fatalf("missing visible setup/Pi wrapper: %s", calls)
	}
	if strings.Contains(calls, "--yes") {
		t.Fatal("approval bypassed")
	}
	if len(worktree.List(repo)) != 2 {
		t.Fatal("wrong worktree count")
	}
}

func TestTaskConfiguredSelectionRetryReusesTab(t *testing.T) {
	repo, cfg, ctx, log := fixture(t)
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	if err := os.WriteFile(os.Getenv("WORKTRUNK_PROJECT_CONFIG_PATH"), []byte("[pre-start]\ninstall = \"true\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	rexPath, err := exec.LookPath("rex")
	if err != nil {
		t.Fatal(err)
	}
	script, _ := os.ReadFile(rexPath)
	text := strings.Replace(string(script), `case "$1" in`, `case "$1" in
 session) echo '{"windows":[{"window_id":"new-window"}]}' ;;
 do) echo "$LOCAL_TASK_PATH" ;;`, 1)
	if err := os.WriteFile(rexPath, []byte(text), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TASK_FAIL", "focus")
	first, err := Start(ctx, cfg, repo, "")
	if err == nil || first.WindowID != "new-window" {
		t.Fatalf("%+v: %v", first, err)
	}
	t.Setenv("LOCAL_TASK_PATH", first.Path)
	t.Setenv("TASK_FAIL", "")
	second, err := Start(ctx, cfg, repo, first.Path)
	if err != nil || second.WindowID != first.WindowID || second.Path != first.Path {
		t.Fatalf("%+v: %v", second, err)
	}
	calls, _ := os.ReadFile(log)
	if strings.Count(string(calls), "window\nnew\n") != 1 {
		t.Fatalf("retry duplicated tab: %s", calls)
	}
}

func TestTaskPreSwitchStopsBeforeCreation(t *testing.T) {
	repo, cfg, ctx, log := fixture(t)
	if err := os.WriteFile(os.Getenv("WORKTRUNK_PROJECT_CONFIG_PATH"), []byte("[pre-switch]\ncheck = \"true\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Start(ctx, cfg, repo, ""); err == nil || !strings.Contains(err.Error(), "pre-switch") {
		t.Fatal(err)
	}
	if len(worktree.List(repo)) != 1 {
		t.Fatal("pre-switch refusal created a worktree")
	}
	if data, _ := os.ReadFile(log); strings.Contains(string(data), "window\nnew") {
		t.Fatal("opened a tab before refusal")
	}
}
