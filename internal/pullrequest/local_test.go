package pullrequest

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/rex"
)

func localFixture(t *testing.T) (string, string) {
	t.Helper()
	repo, path := fixture(t)
	t.Setenv("PR_HOOK_PHASES", "")
	return repo, path
}

func TestLocalPreflightAndRegistration(t *testing.T) {
	for _, phase := range []string{"", "pre-start", "post-start", "post-switch"} {
		t.Run(phase, func(t *testing.T) {
			repo, path := localFixture(t)
			t.Setenv("LOCAL_PHASE", phase)
			plan, err := PreflightLocal(repo)
			if err != nil {
				t.Fatal(err)
			}
			if plan.hooks != (phase != "") {
				t.Fatalf("hooks=%v", plan.hooks)
			}
			git(t, repo, "worktree", "add", "-b", "local", path)
			if err := plan.Register(path, "local", "main"); err != nil {
				t.Fatal(err)
			}
			pending, err := LocalPending(path)
			if err != nil || pending != plan.hooks {
				t.Fatalf("pending=%v: %v", pending, err)
			}
			s, err := load(path)
			if err != nil {
				t.Fatal(err)
			}
			if phase == "" {
				if s.Path != "" {
					t.Fatal("no-hook creation wrote setup state")
				}
				return
			}
			if !s.New || s.Source != repo || s.Base != "main" || s.URL != "" || s.Released || !validState(path, s) {
				t.Fatalf("%+v", s)
			}
			s.Stage = 1
			if err := save(path, s); err != nil {
				t.Fatal(err)
			}
			if err := plan.Register(path, "local", "main"); err != nil {
				t.Fatal(err)
			}
			again, _ := load(path)
			if again.Stage != 1 {
				t.Fatal("registration reset setup")
			}
		})
	}
}

func TestLocalStateSupportsSessionAndTabOpen(t *testing.T) {
	for _, target := range []string{"session", "tab"} {
		t.Run(target, func(t *testing.T) {
			repo, path := localFixture(t)
			t.Setenv("LOCAL_PHASE", "pre-start")
			plan, err := PreflightLocal(repo)
			if err != nil {
				t.Fatal(err)
			}
			git(t, repo, "worktree", "add", "-b", "local", path)
			if err := plan.Register(path, "local", "main"); err != nil {
				t.Fatal(err)
			}
			result, err := Open(path, target, rex.Ctx{Client: "client", Session: "s1"})
			if err != nil || result.BlockID != "b1" {
				t.Fatalf("%+v: %v", result, err)
			}
			s, _ := load(path)
			if !s.Released {
				t.Fatal("successful selection did not release setup")
			}
		})
	}
}

func TestLocalPreSwitchRefusesBeforeMutation(t *testing.T) {
	repo, path := localFixture(t)
	t.Setenv("PR_PRE_SWITCH", "1")
	if _, err := PreflightLocal(repo); err == nil || !strings.Contains(err.Error(), "pre-switch") {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("preflight created worktree")
	}
}

func TestLocalStartupFailureKeepsShellAndSkipsPi(t *testing.T) {
	for _, status := range []string{"0", "7"} {
		t.Run(status, func(t *testing.T) {
			repo, path := localFixture(t)
			t.Setenv("LOCAL_PHASE", "pre-start")
			plan, err := PreflightLocal(repo)
			if err != nil {
				t.Fatal(err)
			}
			git(t, repo, "worktree", "add", "-b", "local", path)
			if err := plan.Register(path, "local", "main"); err != nil {
				t.Fatal(err)
			}
			log := filepath.Join(t.TempDir(), "startup")
			t.Setenv("LOCAL_START_LOG", log)
			bin := t.TempDir()
			runner, pi, shell := filepath.Join(bin, "raptor"), filepath.Join(bin, "pi"), filepath.Join(bin, "shell")
			put(t, runner, "#!/bin/sh\necho setup >> \"$LOCAL_START_LOG\"\nexit "+status+"\n")
			put(t, pi, "#!/bin/sh\necho pi >> \"$LOCAL_START_LOG\"\n")
			put(t, shell, "#!/bin/sh\necho shell >> \"$LOCAL_START_LOG\"\n")
			t.Setenv("SHELL", shell)
			args, err := LocalStartup(path, "task", pi)
			if err != nil {
				t.Fatal(err)
			}
			s, _ := load(path)
			if s.Released {
				t.Fatal("runner released before selection")
			}
			if _, err := LocalStartup(path, "task", pi); err == nil {
				t.Fatal("duplicate runner accepted")
			}
			exe, _ := os.Executable()
			args[2] = strings.Replace(args[2], quote(exe), quote(runner), 1)
			if out, err := exec.Command(args[0], args[1:]...).CombinedOutput(); err != nil {
				t.Fatalf("%v: %s", err, out)
			}
			data, _ := os.ReadFile(log)
			want := "setup\npi\n"
			if status != "0" {
				want = "setup\nshell\n"
			}
			if string(data) != want {
				t.Fatalf("%q, want %q", data, want)
			}
		})
	}
}
