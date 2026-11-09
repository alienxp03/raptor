package api

import (
	"os"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/pullrequest"
	"github.com/alienxp03/raptor/internal/rex"
	"github.com/alienxp03/raptor/internal/worktree"
)

func TestCreateRegistersConfiguredLocalSetup(t *testing.T) {
	repo := fixtureRepo(t)
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	if err := os.WriteFile(os.Getenv("WORKTRUNK_PROJECT_CONFIG_PATH"), []byte("[pre-start]\ninstall = \"true\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	call := client(t, New(rex.Ctx{}, config.Default()))
	var created pathResult
	if err := call("worktrees.create", map[string]any{"repo": repo, "branch": "local-setup", "base": "main"}, &created); err != "" {
		t.Fatal(err)
	}
	pending, err := pullrequest.LocalPending(created.Path)
	if err != nil || !pending {
		t.Fatalf("pending=%v: %v", pending, err)
	}
	if !pullrequest.Ready(created.Path) {
		t.Fatal("local state lacks worktree identity")
	}
	if err := call("dispatch", map[string]any{"target": "here", "path": created.Path}, nil); !strings.Contains(err, "Session or Tab") || !strings.Contains(err, "preserved") {
		t.Fatal(err)
	}
}

func TestCreatePreSwitchRefusesBeforeMutation(t *testing.T) {
	repo := fixtureRepo(t)
	if err := os.WriteFile(os.Getenv("WORKTRUNK_PROJECT_CONFIG_PATH"), []byte("[pre-switch]\ncheck = \"true\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	call := client(t, New(rex.Ctx{}, config.Default()))
	if err := call("worktrees.create", map[string]any{"repo": repo, "branch": "local-setup", "base": "main"}, nil); !strings.Contains(err, "pre-switch") {
		t.Fatal(err)
	}
	if len(worktree.List(repo)) != 1 {
		t.Fatal("pre-switch refusal mutated repository")
	}
}
