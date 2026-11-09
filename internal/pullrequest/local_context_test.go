package pullrequest

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLocalCreationUsesSelectedBaseWorktreeContext(t *testing.T) {
	repo, source := localFixture(t)
	t.Setenv("LOCAL_PHASE", "pre-start")
	git(t, repo, "worktree", "add", "-b", "source", source)
	plan, err := PreflightLocal(source)
	if err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(filepath.Dir(source), "local-target")
	git(t, repo, "worktree", "add", "-b", "local", target, "main")
	if err := plan.Register(target, "local", "main"); err != nil {
		t.Fatal(err)
	}
	s, err := load(target)
	if err != nil || s.Source != source || s.BasePath != repo || s.Base != "main" {
		t.Fatalf("wrong base context: %+v: %v", s, err)
	}
	s.Released = true
	if err := save(target, s); err != nil {
		t.Fatal(err)
	}
	if err := Setup(target, false); err != nil {
		t.Fatal(err)
	}
	log, _ := os.ReadFile(os.Getenv("PR_LOG"))
	if !strings.Contains(string(log), "--var base_worktree_path="+repo) || strings.Contains(string(log), "--var pr_url=") || strings.Contains(string(log), "--var pr_number=") {
		t.Fatalf("incorrect local hook variables: %s", log)
	}
}

func TestFinishedLocalSetupDoesNotBlockOrdinaryNavigation(t *testing.T) {
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
	s, _ := load(path)
	s.Instance, s.Complete = "old-registration", true
	if err := save(path, s); err != nil {
		t.Fatal(err)
	}
	if pending, err := LocalPending(path); err != nil || pending {
		t.Fatalf("completed setup blocked navigation: %v %v", pending, err)
	}
	s.Complete = false
	if err := save(path, s); err != nil {
		t.Fatal(err)
	}
	if _, err := LocalPending(path); err == nil {
		t.Fatal("stale pending setup silently skipped")
	}
}

func TestLocalTaskUsesCommittedHEADBase(t *testing.T) {
	repo, path := localFixture(t)
	t.Setenv("LOCAL_PHASE", "pre-start")
	head := git(t, repo, "rev-parse", "HEAD")
	plan, err := PreflightLocal(repo)
	if err != nil {
		t.Fatal(err)
	}
	git(t, repo, "worktree", "add", "-b", "task", path, head)
	if err := plan.Register(path, "task", ""); err != nil {
		t.Fatal(err)
	}
	s, err := load(path)
	if err != nil || s.Base != head || s.BasePath != "" {
		t.Fatalf("wrong committed HEAD context: %+v: %v", s, err)
	}
}
