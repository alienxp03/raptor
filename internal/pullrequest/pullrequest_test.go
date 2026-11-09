package pullrequest

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/rex"
)

func put(t *testing.T, path, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0700); err != nil {
		t.Fatal(err)
	}
}

func git(t *testing.T, path string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = path
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v: %s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

func fixture(t *testing.T) (string, string) {
	t.Helper()
	root, err := canonical(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	repo, path := filepath.Join(root, "base"), filepath.Join(root, "worktree")
	if err := os.Mkdir(repo, 0700); err != nil {
		t.Fatal(err)
	}
	git(t, repo, "init", "-b", "main")
	git(t, repo, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "fixture")
	git(t, repo, "remote", "add", "origin", "git@github.com:acme/project.git")
	t.Setenv("HOME", filepath.Join(root, "home"))
	t.Setenv("XDG_STATE_HOME", filepath.Join(root, "state"))
	t.Setenv("PR_DEST", path)
	t.Setenv("PR_LOG", filepath.Join(root, "calls"))
	t.Setenv("PR_FAIL", filepath.Join(root, "fail"))
	bin := filepath.Join(root, "bin")
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	put(t, filepath.Join(bin, "gh"), `#!/bin/sh
printf 'gh %s\n' "$*" >> "$PR_LOG"
case "$1 $2" in
 'api --hostname') [ "$3" = github.com ] && [ "$4" = repos/acme/project/pulls/42 ] || exit 8; echo '{"base":{"repo":{"full_name":"acme/project"}}}';;
 'pr view') echo '{"number":42,"title":"Fix it","headRefName":"feat/fix","url":"https://github.com/acme/project/pull/42"}';;
 'repo clone') git clone --quiet "$PR_CLONE_SOURCE" "$4" && git -C "$4" remote set-url origin https://github.com/acme/project.git;;
 *) exit 8;;
esac
`)
	put(t, filepath.Join(bin, "zoxide"), "#!/bin/sh\nexit 0\n")
	put(t, filepath.Join(bin, "wt"), `#!/bin/sh
printf 'wt %s\n' "$*" >> "$PR_LOG"
case "$1 $2" in
 'config show')
  project="${WT_PROJECT_CONFIG_PATH:-$PWD/.config/wt.toml}"
  case "$project" in /*) :;; *) project="$PWD/$project";; esac
  printf '{"user":{"path":"%s/user.toml","exists":false},"system":{"path":"%s/system.toml","exists":false},"project":{"path":"%s","exists":false}}\n' "$HOME" "$HOME" "$project";;
 'step eval') printf '{"result":"%s"}\n' "$PR_DEST";;
 'hook show') if [ -n "$PR_PRE_SWITCH" ]; then echo '[{"name":"check"}]'; else echo '[]'; fi;;
 'config approvals') if [ -n "$PR_DENY" ]; then echo '{"commands":[{"phase":"pre-start","approved":false}]}'; else echo '{"commands":[]}'; fi;;
 'hook pre-start') if [ -f "$PR_FAIL" ]; then echo 'install failed' >&2; exit 7; fi;;
 'hook post-start'|'hook post-switch') :;;
 'switch --no-hooks')
  if [ ! -d "$PR_DEST" ]; then git worktree add -q -b feat/fix "$PR_DEST" || exit; fi
  printf '{"path":"%s","branch":"feat/fix"}\n' "$PR_DEST"
  if [ -n "$PR_SWITCH_FAIL" ]; then exit 9; fi;;
 *) echo "unexpected wt: $*" >&2; exit 8;;
esac
`)
	put(t, filepath.Join(bin, "rex"), `#!/bin/sh
printf 'rex %s\n' "$*" >> "$PR_LOG"
case "$1" in
 new) echo '{"session_id":"s1","initial_windows":[{"window_id":"w1","block_ids":["b1"]}]}';;
 window) echo '{"session_id":"s1","window_id":"w1","block_ids":["b1"]}';;
 session) echo '{"windows":[{"window_id":"w1","focused_block_id":"b1","blocks":[{"block_id":"b1"}]}]}';;
 ls) echo '{"sessions":[{"session_id":"s1"}]}';;
 do) printf '%s\n' "$PR_DEST";;
 -C) if [ -f "$PR_FAIL" ]; then exit 5; fi;;
 *) exit 8;;
esac
`)
	return repo, path
}

func TestInputAndIdentity(t *testing.T) {
	for _, input := range []string{"42", "https://gitlab.com/acme/project/pull/42", "https://github.com/acme/project/issues/42", "https://github.com/acme/project/pull/0", "https://github.com/acme/project/pull/42?x=1", "https://github.com/../project/pull/42"} {
		if _, _, err := parse(input, ""); err == nil {
			t.Errorf("accepted %q", input)
		}
	}
	for _, origin := range []string{"git@github.com:acme/project.git", "ssh://git@github.com/acme/project.git", "https://github.com/acme/project"} {
		id, err := identity(origin)
		if err != nil || id != "acme/project" {
			t.Fatalf("%s: %s %v", origin, id, err)
		}
	}
}

func TestResolveReadOnlyAndContext(t *testing.T) {
	repo, path := fixture(t)
	info, err := Resolve(repo, "42")
	if err != nil {
		t.Fatal(err)
	}
	if info.Repo != repo || info.Path != path || info.Number != 42 || info.CloneRequired || info.Existing {
		t.Fatalf("%+v", info)
	}
	calls, _ := os.ReadFile(os.Getenv("PR_LOG"))
	if strings.Contains(string(calls), "switch") || strings.Contains(string(calls), "clone") {
		t.Fatal(string(calls))
	}
	git(t, repo, "remote", "set-url", "origin", "https://github.com/wrong/project.git")
	if _, err := Resolve(repo, "https://github.com/acme/project/pull/42"); err == nil {
		t.Fatal("accepted context mismatch")
	}
}

func TestMissingCloneAndOccupiedDestination(t *testing.T) {
	source, _ := fixture(t)
	t.Setenv("PR_CLONE_SOURCE", source)
	info, err := Resolve("", "https://github.com/acme/project/pull/42")
	if err != nil || !info.CloneRequired || info.Path != "" {
		t.Fatalf("%+v %v", info, err)
	}
	put(t, filepath.Join(info.Repo, "keep"), "do not touch")
	if _, err := Prepare("", info.URL); err == nil {
		t.Fatal("accepted occupied clone path")
	}
	data, _ := os.ReadFile(filepath.Join(info.Repo, "keep"))
	if string(data) != "do not touch" {
		t.Fatal("changed occupied clone")
	}
}

func TestPrepareAndVisibleSetupRetry(t *testing.T) {
	repo, path := fixture(t)
	info, err := Prepare(repo, "42")
	if err != nil || info.Existing || info.Path != path {
		t.Fatalf("%+v %v", info, err)
	}
	s, err := load(path)
	if err != nil || !s.New {
		t.Fatalf("%+v %v", s, err)
	}
	put(t, os.Getenv("PR_FAIL"), "fail")
	result, err := Open(path, "session", rex.Ctx{Client: "client"})
	if err == nil || result.SessionID != "s1" || result.Error == "" {
		t.Fatalf("%+v %v", result, err)
	}
	s, _ = load(path)
	if s.Released {
		t.Fatal("released before selection")
	}
	if err := os.Remove(os.Getenv("PR_FAIL")); err != nil {
		t.Fatal(err)
	}
	result, err = Open(path, "session", rex.Ctx{Client: "client"})
	if err != nil || result.BlockID != "b1" {
		t.Fatalf("%+v %v", result, err)
	}
	calls, _ := os.ReadFile(os.Getenv("PR_LOG"))
	if strings.Count(string(calls), "rex new ") != 1 {
		t.Fatal(string(calls))
	}
	if !strings.Contains(string(calls), "setup --path") || !strings.Contains(string(calls), "exec") {
		t.Fatal("missing usable-shell wrapper")
	}
	put(t, os.Getenv("PR_FAIL"), "fail")
	if err := Setup(path, false); err == nil || !strings.Contains(err.Error(), "exit status 7") {
		t.Fatalf("%v", err)
	}
	s, _ = load(path)
	if s.Stage != 0 || s.Failed == "" {
		t.Fatalf("%+v", s)
	}
	if err := Setup(path, false); err == nil {
		t.Fatal("implicitly retried failed setup")
	}
	_ = os.Remove(os.Getenv("PR_FAIL"))
	if err := Setup(path, true); err != nil {
		t.Fatal(err)
	}
	if err := Setup(path, true); err != nil {
		t.Fatal(err)
	}
	calls, _ = os.ReadFile(os.Getenv("PR_LOG"))
	if strings.Count(string(calls), "wt hook post-start --") != 1 || strings.Count(string(calls), "wt hook post-switch --") != 1 {
		t.Fatal(string(calls))
	}
	s, _ = load(path)
	if !s.Complete {
		t.Fatalf("%+v", s)
	}
}

func TestExistingWorktreeNoCreationSetup(t *testing.T) {
	repo, path := fixture(t)
	git(t, repo, "worktree", "add", "-b", "feat/fix", path)
	info, err := Prepare(repo, "42")
	if err != nil || !info.Existing {
		t.Fatalf("%+v %v", info, err)
	}
	if _, err := Open(path, "tab", rex.Ctx{Session: "s1", Client: "client"}); err != nil {
		t.Fatal(err)
	}
	if err := Setup(path, false); err != nil {
		t.Fatal(err)
	}
	calls, _ := os.ReadFile(os.Getenv("PR_LOG"))
	if strings.Contains(string(calls), "wt hook pre-start --") || strings.Contains(string(calls), "wt hook post-start --") {
		t.Fatal(string(calls))
	}
}

func TestPartialSwitchRetainsRecovery(t *testing.T) {
	repo, path := fixture(t)
	t.Setenv("PR_SWITCH_FAIL", "1")
	info, err := Prepare(repo, "42")
	if err == nil || info.Path != path {
		t.Fatalf("%+v %v", info, err)
	}
	s, err := load(path)
	if err != nil || !s.New {
		t.Fatalf("%+v %v", s, err)
	}
	t.Setenv("PR_SWITCH_FAIL", "")
	if _, err := Prepare(repo, "42"); err != nil {
		t.Fatal(err)
	}
	s, _ = load(path)
	if !s.New {
		t.Fatal("lost pending creation hooks")
	}
}

func TestPreSwitchFailsBeforeMutation(t *testing.T) {
	repo, path := fixture(t)
	t.Setenv("PR_PRE_SWITCH", "1")
	if _, err := Prepare(repo, "42"); err == nil {
		t.Fatal("accepted pre-switch hooks")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("created before pre-switch")
	}
}

func TestLockAndCanonicalIdentity(t *testing.T) {
	root := t.TempDir()
	t.Setenv("XDG_STATE_HOME", filepath.Join(root, "state"))
	alias := filepath.Join(root, "alias")
	if err := os.Symlink(root, alias); err != nil {
		t.Fatal(err)
	}
	a, _ := stateFile(filepath.Join(alias, "future"), ".json")
	if err := os.Mkdir(filepath.Join(root, "future"), 0700); err != nil {
		t.Fatal(err)
	}
	b, _ := stateFile(filepath.Join(root, "future"), ".json")
	if a != b {
		t.Fatalf("state identity changed: %s != %s", a, b)
	}
	unlock, err := lock(filepath.Join(root, "future"), false)
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	if second, err := lock(filepath.Join(alias, "future"), false); err == nil {
		second()
		t.Fatal("double lock")
	}
	data, _ := json.Marshal(Info{})
	for _, field := range []string{"input", "url", "number", "title", "branch", "repo", "path", "clone_required", "existing"} {
		if !strings.Contains(string(data), `"`+field+`":`) {
			t.Fatal(string(data))
		}
	}
}

func TestApprovalAndConfigFailures(t *testing.T) {
	for _, mode := range []string{"approval", "config"} {
		t.Run(mode, func(t *testing.T) {
			repo, path := fixture(t)
			if _, err := Prepare(repo, "42"); err != nil {
				t.Fatal(err)
			}
			if _, err := Open(path, "session", rex.Ctx{Client: "client"}); err != nil {
				t.Fatal(err)
			}
			if mode == "approval" {
				t.Setenv("PR_DENY", "1")
			} else {
				put(t, filepath.Join(path, ".config", "wt.toml"), "pre-start = 'different'\n")
			}
			if err := Setup(path, false); err == nil {
				t.Fatal("marked unsafe/skipped setup successful")
			}
			s, _ := load(path)
			if s.Complete {
				t.Fatal("setup complete")
			}
		})
	}
}
