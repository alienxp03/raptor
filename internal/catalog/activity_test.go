package catalog

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/alienxp03/raptor/internal/rex"
)

func TestDirectoryActivityExactCanonicalMatch(t *testing.T) {
	root := t.TempDir()
	repo := filepath.Join(root, "repo")
	sub := filepath.Join(repo, "sub")
	if err := os.MkdirAll(sub, 0700); err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(root, "alias")
	if err := os.Symlink(repo, alias); err != nil {
		t.Fatal(err)
	}
	items := []Directory{{Path: repo}, {Path: alias}, {Path: sub}, {Path: repo + "-other"}, {Path: "", State: "blocked", Working: true}, {Path: root}, {Path: filepath.Join(root, "idle")}}
	agents := []rex.AgentEntry{
		{Cwd: filepath.Join(alias, "sub"), State: "working"},
		{Cwd: repo, State: "blocked"},
		{Cwd: filepath.Join(root, "idle"), State: "idle"},
		{Cwd: "", State: "blocked"},
	}
	ApplyDirectoryActivity(items, agents)
	for i, want := range []struct {
		state   string
		working bool
	}{{"blocked", false}, {"blocked", false}, {"working", true}, {"", false}, {"", false}, {"", false}, {"idle", false}} {
		if items[i].State != want.state || items[i].Working != want.working {
			t.Fatalf("row %d=%+v", i, items[i])
		}
	}
	ApplyDirectoryActivity(items, nil)
	for _, item := range items {
		if item.State != "" || item.Working {
			t.Fatalf("stale=%+v", item)
		}
	}
}

func TestRemoteActivityDoesNotResolveLocalSymlinks(t *testing.T) {
	root := t.TempDir()
	repo, alias := filepath.Join(root, "repo"), filepath.Join(root, "alias")
	if err := os.MkdirAll(filepath.Join(repo, "sub"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(repo, alias); err != nil {
		t.Fatal(err)
	}
	agents := []rex.AgentEntry{{Cwd: repo, State: "working"}}
	items := []Directory{{Path: alias}, {Path: repo}}
	ApplyDirectoryActivityOn("remote", items, agents)
	if items[0].Working || !items[1].Working {
		t.Fatalf("remote paths used local symlinks: %+v", items)
	}
	ApplyDirectoryActivityOn(rex.LocalHostLabel, items, agents)
	if !items[0].Working || !items[1].Working {
		t.Fatalf("local symlink projection lost: %+v", items)
	}
}

func TestFilterAgentsKeepsGroupAndTimeOrder(t *testing.T) {
	entries := []rex.AgentEntry{
		{Label: "a long review task", State: "blocked"},
		{Label: "review", State: "working"},
		{Label: "review", State: "idle"},
	}
	if got := FilterAgents(entries, "review"); !reflect.DeepEqual(got, []int{0, 1, 2}) {
		t.Fatalf("indices=%v", got)
	}
}
