package task

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
	"github.com/alienxp03/raptor/internal/worktree"
)

func fixture(t *testing.T) (string, config.Config, rex.Ctx, string) {
	t.Helper()
	repo := filepath.Join(t.TempDir(), "repo with spaces")
	if err := os.Mkdir(repo, 0755); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"init", "-b", "main"}, {"config", "user.name", "Test"}, {"config", "user.email", "test@example.com"}, {"-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "init"}} {
		if _, err := worktree.GitOut(repo, args...); err != nil {
			t.Fatal(err)
		}
	}
	bin := t.TempDir()
	log := filepath.Join(t.TempDir(), "calls")
	t.Setenv("TASK_LOG", log)
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	wtRoot := t.TempDir()
	empty := filepath.Join(wtRoot, "empty.toml")
	if err := os.WriteFile(empty, nil, 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WORKTRUNK_CONFIG_PATH", empty)
	t.Setenv("WORKTRUNK_SYSTEM_CONFIG_PATH", empty)
	t.Setenv("WORKTRUNK_PROJECT_CONFIG_PATH", empty)
	t.Setenv("WORKTRUNK_WORKTREE_PATH", filepath.Join(wtRoot, "trees", "{{ repo }}", "{{ branch | sanitize }}"))
	script := `#!/bin/sh
printf 'CALL\n' >> "$TASK_LOG"
printf '%s\n' "$@" >> "$TASK_LOG"
case "$1" in
 window)
  if [ "$TASK_FAIL" = open ]; then echo 'open failed' >&2; exit 1; fi
  echo '{"window_id":"new-window","block_ids":["new-block"]}' ;;
 -C)
  if [ "$TASK_FAIL" = focus ]; then echo 'focus failed' >&2; exit 1; fi ;;
esac
`
	if err := os.WriteFile(filepath.Join(bin, "rex"), []byte(script), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bin, "pi"), []byte("#!/bin/sh\nexit 0\n"), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	return repo, config.Config{WorktreeRoot: filepath.Join(t.TempDir(), "worktree root")}, rex.Ctx{Session: "origin-session", Block: "origin-block", Client: "iphone"}, log
}

func TestTaskCreatesTabWithFreshEmptyPi(t *testing.T) {
	repo, cfg, ctx, log := fixture(t)
	result, err := Start(ctx, cfg, repo, "")
	if err != nil {
		t.Fatal(err)
	}
	if result.WindowID != "new-window" || result.BlockID != "new-block" || result.Path == "" || strings.ContainsAny(result.Branch, "/0123456789") || len(strings.Split(result.Branch, "-")) != 2 {
		t.Fatalf("%+v", result)
	}
	data, _ := os.ReadFile(log)
	calls := string(data)
	want := "window\nnew\n-s\norigin-session\n" + result.Branch + "\n-c\n" + result.Path + "\n--json\n--\n"
	if !strings.Contains(calls, want) {
		t.Fatalf("wrong tab command:\n%s", calls)
	}
	if strings.Contains(calls, "--keep-open\n") {
		t.Fatal("Pi tab must close after Pi exits")
	}
	after := strings.SplitN(calls, "--\n", 2)[1]
	piCall := strings.SplitN(after, "CALL\n", 2)[0]
	if len(strings.Split(strings.TrimSpace(piCall), "\n")) != 1 || !strings.HasSuffix(strings.TrimSpace(piCall), "/pi") {
		t.Fatalf("Pi must receive no prompt/resume arguments: %q", piCall)
	}
	if !strings.Contains(calls, "-C\niphone\ndo\nsession.select\nsession_id=origin-session\nwindow_id=new-window") {
		t.Fatal("requesting app not selected")
	}
}

func TestTaskMissingContextOrPiDoesNotCreate(t *testing.T) {
	repo, cfg, ctx, _ := fixture(t)
	for _, bad := range []rex.Ctx{{Session: ctx.Session}, {Client: ctx.Client}} {
		if _, err := Start(bad, cfg, repo, ""); err == nil {
			t.Fatal("missing context accepted")
		}
	}
	t.Setenv("PATH", t.TempDir())
	if _, err := Start(ctx, cfg, repo, ""); err == nil || !strings.Contains(err.Error(), "pi executable not found") {
		t.Fatal(err)
	}
	if _, err := os.Stat(cfg.WorktreeRoot); !os.IsNotExist(err) {
		t.Fatal("created directories before preflight")
	}
}

func TestTaskOpenFailurePreservesAndResumeReusesWorktree(t *testing.T) {
	repo, cfg, ctx, _ := fixture(t)
	t.Setenv("TASK_FAIL", "open")
	result, err := Start(ctx, cfg, repo, "")
	if err == nil || result.Path == "" || !strings.Contains(err.Error(), "preserved") {
		t.Fatalf("%+v %v", result, err)
	}
	if len(worktree.List(repo)) != 2 {
		t.Fatal("created worktree lost")
	}
	t.Setenv("TASK_FAIL", "")
	resumed, err := Start(ctx, cfg, repo, result.Path)
	if err != nil || canonical(resumed.Path) != canonical(result.Path) || resumed.Branch != result.Branch {
		t.Fatalf("%+v %v", resumed, err)
	}
	if len(worktree.List(repo)) != 2 {
		t.Fatal("retry created a second worktree")
	}
	if _, err := Start(ctx, cfg, repo, t.TempDir()); err == nil {
		t.Fatal("unregistered retry path accepted")
	}
}

func TestTaskFocusFailureIdentifiesExistingTab(t *testing.T) {
	repo, cfg, ctx, _ := fixture(t)
	t.Setenv("TASK_FAIL", "focus")
	result, err := Start(ctx, cfg, repo, "")
	if err == nil || result.WindowID != "new-window" || !strings.Contains(err.Error(), "select that tab") {
		t.Fatalf("%+v %v", result, err)
	}
	if len(worktree.List(repo)) != 2 {
		t.Fatal("worktree removed after focus error")
	}
}

func TestTaskNoRepositoryDoesNotFallBackToBackendCWD(t *testing.T) {
	_, cfg, ctx, _ := fixture(t)
	// The fake rex emits no cwd: backend CWD must never become the origin repo.
	if _, err := Start(ctx, cfg, "", ""); err == nil || !strings.Contains(err.Error(), "current pane") {
		t.Fatal(err)
	}
	if _, err := os.Stat(cfg.WorktreeRoot); !os.IsNotExist(err) {
		t.Fatal("created task without origin repository")
	}
}
