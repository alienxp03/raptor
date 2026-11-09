package pullrequest

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/rex"
)

func TestCloneBaseLocally(t *testing.T) {
	source, path := fixture(t)
	t.Setenv("PR_CLONE_SOURCE", source)
	info, err := Prepare("", "https://github.com/acme/project/pull/42")
	if err != nil {
		t.Fatal(err)
	}
	expected := filepath.Join(os.Getenv("HOME"), "workspace", "acme", "project")
	if info.Repo != expected || info.Path != path || info.CloneRequired {
		t.Fatalf("%+v", info)
	}
	if got := git(t, expected, "remote", "get-url", "origin"); got != "https://github.com/acme/project.git" {
		t.Fatal(got)
	}
}

func TestSourceWorktreeContext(t *testing.T) {
	repo, path := fixture(t)
	source := filepath.Join(filepath.Dir(repo), "source")
	git(t, repo, "worktree", "add", "-b", "source-branch", source)
	info, err := Prepare(source, "42")
	if err != nil || info.Repo != repo {
		t.Fatalf("%+v %v", info, err)
	}
	s, err := load(path)
	if err != nil || s.Source != source || s.Base != "source-branch" {
		t.Fatalf("%+v %v", s, err)
	}
}

func TestZoxideOriginDiscovery(t *testing.T) {
	repo, _ := fixture(t)
	bin := strings.Split(os.Getenv("PATH"), string(os.PathListSeparator))[0]
	put(t, filepath.Join(bin, "zoxide"), "#!/bin/sh\nprintf '%s\\n' "+quote(repo)+"\n")
	info, err := Resolve("", "https://github.com/acme/project/pull/42")
	if err != nil || info.Repo != repo || info.CloneRequired {
		t.Fatalf("%+v %v", info, err)
	}
}

func TestUncertainOpenReconcilesByCanonicalPath(t *testing.T) {
	repo, path := fixture(t)
	if _, err := Prepare(repo, "42"); err != nil {
		t.Fatal(err)
	}
	s, _ := load(path)
	s.Opening, s.Target = true, "session"
	if err := save(path, s); err != nil {
		t.Fatal(err)
	}
	result, err := Open(path, "session", rex.Ctx{Client: "client"})
	if err != nil || result.SessionID != "s1" || result.BlockID != "b1" {
		t.Fatalf("%+v %v", result, err)
	}
	calls, _ := os.ReadFile(os.Getenv("PR_LOG"))
	if strings.Contains(string(calls), "rex new ") {
		t.Fatal("duplicated uncertain session")
	}
}

func TestOpenBusyReturnsRecoveryIDs(t *testing.T) {
	repo, path := fixture(t)
	if _, err := Prepare(repo, "42"); err != nil {
		t.Fatal(err)
	}
	ctx := rex.Ctx{Client: "client"}
	if _, err := Open(path, "session", ctx); err != nil {
		t.Fatal(err)
	}
	unlock, err := lock(path, false)
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	result, err := Open(path, "session", ctx)
	if err == nil || result.SessionID != "s1" || result.Error == "" {
		t.Fatalf("%+v %v", result, err)
	}
}

func TestInterruptedBackgroundNotReplayed(t *testing.T) {
	repo, path := fixture(t)
	if _, err := Prepare(repo, "42"); err != nil {
		t.Fatal(err)
	}
	s, _ := load(path)
	s.Released, s.Stage, s.Failed = true, 1, "post-start interrupted"
	if err := save(path, s); err != nil {
		t.Fatal(err)
	}
	if err := Setup(path, true); err == nil || !strings.Contains(err.Error(), "not replayed") {
		t.Fatal(err)
	}
	calls, _ := os.ReadFile(os.Getenv("PR_LOG"))
	if strings.Contains(string(calls), "wt hook post-start --") {
		t.Fatal("replayed uncertain background hook")
	}
}
