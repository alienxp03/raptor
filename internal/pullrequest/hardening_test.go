package pullrequest

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/alienxp03/raptor/internal/rex"
)

func TestRegistrationIdentityAndReady(t *testing.T) {
	repo, path := fixture(t)
	if Ready(path) {
		t.Fatal("ready before Prepare")
	}
	git(t, repo, "worktree", "add", "-b", "feat/fix", path)
	if Ready(path) {
		t.Fatal("registration without journal is ready")
	}
	if _, err := Prepare(repo, "42"); err != nil {
		t.Fatal(err)
	}
	if !Ready(path) {
		t.Fatal("prepared destination is not ready")
	}
	s, _ := load(path)
	old := s.Instance
	s.Complete, s.Stage, s.Released, s.Opening = true, 3, true, true
	s.Result = OpenResult{Path: path, SessionID: "stale", WindowID: "stale", BlockID: "stale"}
	if err := save(path, s); err != nil {
		t.Fatal(err)
	}
	git(t, repo, "worktree", "remove", path)
	if Ready(path) {
		t.Fatal("removed worktree ready")
	}
	git(t, repo, "worktree", "add", path, "feat/fix")
	if Ready(path) {
		t.Fatal("new registration reused old journal")
	}
	result, err := Open(path, "session", rex.Ctx{Client: "client"})
	if err == nil || result.SessionID != "" {
		t.Fatalf("stale open: %+v %v", result, err)
	}
	if err := Setup(path, true); err == nil {
		t.Fatal("stale setup succeeded")
	}
	if _, err := Prepare(repo, "42"); err != nil {
		t.Fatal(err)
	}
	s, _ = load(path)
	if s.Instance == old || s.Complete || s.Stage != 0 || s.Opening || s.Released || s.Result.SessionID != "" {
		t.Fatalf("stale state: %+v", s)
	}
	if !Ready(path) {
		t.Fatal("new journal not ready")
	}
}

func TestUnboundJournalCrashRecovery(t *testing.T) {
	repo, path := fixture(t)
	if _, err := Prepare(repo, "42"); err != nil {
		t.Fatal(err)
	}
	s, _ := load(path)
	s.Instance = "" // crash after switch, before binding registration
	if err := save(path, s); err != nil {
		t.Fatal(err)
	}
	if Ready(path) {
		t.Fatal("unbound journal ready")
	}
	if _, err := Prepare(repo, "42"); err != nil {
		t.Fatal(err)
	}
	s, _ = load(path)
	if !s.New || s.Instance == "" || !Ready(path) {
		t.Fatalf("lost recovery: %+v", s)
	}
}

func TestDefiniteCreateFailureRetriesAfterZeroScan(t *testing.T) {
	repo, path := fixture(t)
	if _, err := Prepare(repo, "42"); err != nil {
		t.Fatal(err)
	}
	bin := strings.Split(os.Getenv("PATH"), string(os.PathListSeparator))[0]
	rexPath := filepath.Join(bin, "rex")
	original, _ := os.ReadFile(rexPath)
	put(t, rexPath, `#!/bin/sh
printf 'rex %s\n' "$*" >> "$PR_LOG"
case "$1" in
 new) exit 7;;
 ls) echo '{"sessions":[]}';;
 *) exit 8;;
esac
`)
	if _, err := Open(path, "session", rex.Ctx{Client: "client"}); err == nil {
		t.Fatal("create succeeded")
	}
	s, _ := load(path)
	if !s.RetryCreate {
		t.Fatal("definite failure not recorded")
	}
	// Zero scan is authoritative, then the normal create succeeds.
	put(t, rexPath, strings.Replace(string(original), `ls) echo '{"sessions":[{"session_id":"s1"}]}';;`, `ls) echo '{"sessions":[]}';;`, 1))
	if _, err := Open(path, "session", rex.Ctx{Client: "client"}); err != nil {
		t.Fatal(err)
	}
	calls, _ := os.ReadFile(os.Getenv("PR_LOG"))
	if strings.Count(string(calls), "rex new ") != 2 {
		t.Fatal(string(calls))
	}
}

func TestUncertainCreateResponsesStayBlockedAfterZeroScan(t *testing.T) {
	for _, response := range []string{
		`printf '{"session_id":'; exit 7`,
		`echo '{}'; exit 0`,
		`echo 'connection closed before response' >&2; exit 7`,
		`echo '{"session_id":"partial"}'; exit 7`,
	} {
		t.Run(response, func(t *testing.T) {
			repo, path := fixture(t)
			if _, err := Prepare(repo, "42"); err != nil {
				t.Fatal(err)
			}
			bin := strings.Split(os.Getenv("PATH"), string(os.PathListSeparator))[0]
			put(t, filepath.Join(bin, "rex"), "#!/bin/sh\nprintf 'rex %s\\n' \"$*\" >> \"$PR_LOG\"\ncase \"$1\" in\nnew) "+response+";;\nls) echo '{\"sessions\":[]}';;\n*) exit 8;;\nesac\n")
			if _, err := Open(path, "session", rex.Ctx{Client: "client"}); err == nil {
				t.Fatal("create succeeded")
			}
			s, _ := load(path)
			if s.RetryCreate {
				t.Fatal("uncertain response permits retry")
			}
			if _, err := Open(path, "session", rex.Ctx{Client: "client"}); err == nil {
				t.Fatal("uncertain response retried")
			}
			calls, _ := os.ReadFile(os.Getenv("PR_LOG"))
			if strings.Count(string(calls), "rex new ") != 1 {
				t.Fatal(string(calls))
			}
		})
	}
}

func TestReconciliationRetainsIDsOnIncompleteScan(t *testing.T) {
	repo, path := fixture(t)
	if _, err := Prepare(repo, "42"); err != nil {
		t.Fatal(err)
	}
	s, _ := load(path)
	s.Opening, s.RetryCreate = true, true
	s.Result = OpenResult{Path: path, SessionID: "preserve"}
	if err := save(path, s); err != nil {
		t.Fatal(err)
	}
	bin := strings.Split(os.Getenv("PATH"), string(os.PathListSeparator))[0]
	put(t, filepath.Join(bin, "rex"), "#!/bin/sh\necho '{}'\n")
	result, err := Open(path, "session", rex.Ctx{Client: "client"})
	if err == nil || result.SessionID != "preserve" {
		t.Fatalf("lost IDs: %+v %v", result, err)
	}
}

func TestAmbiguousZeroScanDoesNotRetry(t *testing.T) {
	repo, path := fixture(t)
	if _, err := Prepare(repo, "42"); err != nil {
		t.Fatal(err)
	}
	s, _ := load(path)
	s.Opening = true // a crash or lost response, not a definite failure
	if err := save(path, s); err != nil {
		t.Fatal(err)
	}
	bin := strings.Split(os.Getenv("PATH"), string(os.PathListSeparator))[0]
	put(t, filepath.Join(bin, "rex"), "#!/bin/sh\n[ \"$1\" = ls ] || exit 9\necho '{\"sessions\":[]}'\n")
	if _, err := Open(path, "session", rex.Ctx{Client: "client"}); err == nil {
		t.Fatal("ambiguous creation retried")
	}
}

func TestOwnedEmptyCloneRetry(t *testing.T) {
	source, _ := fixture(t)
	t.Setenv("PR_CLONE_SOURCE", source)
	bin := strings.Split(os.Getenv("PATH"), string(os.PathListSeparator))[0]
	ghPath := filepath.Join(bin, "gh")
	original, _ := os.ReadFile(ghPath)
	put(t, ghPath, strings.Replace(string(original), "'repo clone')", "'repo clone') mkdir \"$4/.git\"; rmdir \"$4/.git\"; exit 7;", 1))
	if _, err := Prepare("", "https://github.com/acme/project/pull/42"); err == nil {
		t.Fatal("clone succeeded")
	}
	put(t, ghPath, string(original))
	if _, err := Prepare("", "https://github.com/acme/project/pull/42"); err != nil {
		t.Fatal(err)
	}
}

func TestCloneCompletedBeforeErrorResumesWithoutClone(t *testing.T) {
	source, _ := fixture(t)
	t.Setenv("PR_CLONE_SOURCE", source)
	bin := strings.Split(os.Getenv("PATH"), string(os.PathListSeparator))[0]
	ghPath := filepath.Join(bin, "gh")
	original, _ := os.ReadFile(ghPath)
	put(t, ghPath, strings.Replace(string(original), "remote set-url origin https://github.com/acme/project.git;;", "remote set-url origin https://github.com/acme/project.git; exit 7;;", 1))
	if _, err := Prepare("", "https://github.com/acme/project/pull/42"); err == nil {
		t.Fatal("clone succeeded")
	}
	put(t, ghPath, string(original))
	if _, err := Prepare("", "https://github.com/acme/project/pull/42"); err != nil {
		t.Fatal(err)
	}
	calls, _ := os.ReadFile(os.Getenv("PR_LOG"))
	if strings.Count(string(calls), "gh repo clone ") != 1 {
		t.Fatal(string(calls))
	}
}

func TestCloneOwnershipProtectsDataAndReplacement(t *testing.T) {
	for _, mode := range []string{"data", "replacement", "unowned"} {
		t.Run(mode, func(t *testing.T) {
			fixture(t)
			path := filepath.Join(os.Getenv("HOME"), "clone")
			if mode == "unowned" {
				if err := os.MkdirAll(path, 0700); err != nil {
					t.Fatal(err)
				}
			} else if err := claimClone(path); err != nil {
				t.Fatal(err)
			}
			if mode == "replacement" {
				if err := os.Rename(path, path+"-old"); err != nil {
					t.Fatal(err)
				}
				if err := os.Mkdir(path, 0700); err != nil {
					t.Fatal(err)
				}
			}
			if mode == "data" {
				put(t, filepath.Join(path, "keep"), "user data")
			}
			if err := claimClone(path); err == nil {
				t.Fatal("accepted unverified clone destination")
			}
			if mode == "data" {
				data, _ := os.ReadFile(filepath.Join(path, "keep"))
				if string(data) != "user data" {
					t.Fatal("data changed")
				}
			}
		})
	}
}

func TestEffectiveProjectConfig(t *testing.T) {
	for _, mode := range []string{"source drift", "destination drift", "equal"} {
		t.Run(mode, func(t *testing.T) {
			repo, path := fixture(t)
			t.Setenv("WT_PROJECT_CONFIG_PATH", "hooks.toml")
			put(t, filepath.Join(repo, "hooks.toml"), "# approved config\n")
			if _, err := Prepare(repo, "42"); err != nil {
				t.Fatal(err)
			}
			put(t, filepath.Join(path, "hooks.toml"), "# approved config\n")
			if mode == "source drift" {
				put(t, filepath.Join(repo, "hooks.toml"), "# changed source\n")
			}
			if mode == "destination drift" {
				put(t, filepath.Join(path, "hooks.toml"), "# changed destination\n")
			}
			if _, err := Open(path, "session", rex.Ctx{Client: "client"}); err != nil {
				t.Fatal(err)
			}
			err := Setup(path, false)
			if (err == nil) != (mode == "equal") {
				t.Fatalf("%s: %v", mode, err)
			}
		})
	}
}

func TestConfigStampIncludesUserFileContent(t *testing.T) {
	repo, _ := fixture(t)
	path := filepath.Join(os.Getenv("HOME"), "user.toml")
	put(t, path, "# original\n")
	before, err := configStamp(repo)
	if err != nil {
		t.Fatal(err)
	}
	put(t, path, "# changed comment\n")
	after, err := configStamp(repo)
	if err != nil || before == after {
		t.Fatalf("user config content not tracked: %v", err)
	}
}

func TestCommandTimeoutKillsDescendants(t *testing.T) {
	fixture(t)
	root := filepath.Dir(os.Getenv("PR_LOG"))
	marker := filepath.Join(root, "late-mutation")
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := commandContext(ctx, "", "/bin/sh", "-c", "(sleep 1; printf bad > "+quote(marker)+") & wait")
	if err == nil {
		t.Fatal("timeout succeeded")
	}
	if time.Since(start) > 2*time.Second {
		t.Fatal("unbounded pipe drain")
	}
	time.Sleep(1100 * time.Millisecond)
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("descendant survived cancellation")
	}
}

func TestCommandBoundsDrainAfterParentExit(t *testing.T) {
	fixture(t)
	marker := filepath.Join(filepath.Dir(os.Getenv("PR_LOG")), "orphan-mutation")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	start := time.Now()
	_, err := commandContext(ctx, "", "/bin/sh", "-c", "(sleep 2; printf bad > "+quote(marker)+") & exit 0")
	if err == nil || time.Since(start) > 2*time.Second {
		t.Fatalf("pipe drain: %v", err)
	}
	time.Sleep(1200 * time.Millisecond)
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("orphan survived bounded drain")
	}
}

func TestSetupWrapperSurvivesInterrupt(t *testing.T) {
	fixture(t)
	root := filepath.Dir(os.Getenv("PR_LOG"))
	started := filepath.Join(root, "started")
	runner := filepath.Join(root, "fake-raptor")
	login := filepath.Join(root, "login-shell")
	put(t, runner, "#!/bin/sh\nprintf ready > "+quote(started)+"\nsleep 30\n")
	put(t, login, "#!/bin/sh\nprintf 'usable shell'\n")
	t.Setenv("SHELL", login)
	cmd := exec.Command("/bin/sh", "-c", setupWrapper(runner, "path with 'quotes"))
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	var output strings.Builder
	cmd.Stdout, cmd.Stderr = &output, &output
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(started); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("runner did not start")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err := syscall.Kill(-cmd.Process.Pid, syscall.SIGINT); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		if err != nil || !strings.Contains(output.String(), "usable shell") {
			t.Fatalf("wrapper: %v %s", err, output.String())
		}
	case <-time.After(5 * time.Second):
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		<-done
		t.Fatal("wrapper did not return to shell")
	}
}

func TestExplicitGitHubHost(t *testing.T) {
	repo, _ := fixture(t)
	t.Setenv("GH_HOST", "example.invalid")
	if _, err := Resolve(repo, "42"); err != nil {
		t.Fatal(err)
	}
	calls, _ := os.ReadFile(os.Getenv("PR_LOG"))
	if !strings.Contains(string(calls), "gh api --hostname github.com repos/acme/project/pulls/42") {
		t.Fatal(string(calls))
	}
}
