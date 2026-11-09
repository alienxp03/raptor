package worktree

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestSwitchPRReconcilesRegistration(t *testing.T) {
	for _, kind := range []string{"created", "existing", "malformed", "failure"} {
		t.Run(kind, func(t *testing.T) {
			repo := fixtureRepo(t)
			realWT, err := exec.LookPath("wt")
			if err != nil {
				t.Fatal(err)
			}
			if kind == "existing" {
				if _, _, err := switchWorktree(repo, "--create", "fork/topic", "--base", "main"); err != nil {
					t.Fatal(err)
				}
			} else if _, err := GitOut(repo, "branch", "fork/topic"); err != nil {
				t.Fatal(err)
			}
			bin := filepath.Join(filepath.Dir(repo), "bin")
			if err := os.Mkdir(bin, 0700); err != nil {
				t.Fatal(err)
			}
			script := "#!/bin/sh\n\"" + realWT + "\" switch --no-hooks --no-cd --format=json fork/topic\n"
			if kind == "malformed" {
				script = "#!/bin/sh\n\"" + realWT + "\" switch --no-hooks --no-cd --format=json fork/topic >/dev/null\necho invalid-json\n"
			}
			if kind == "failure" {
				script = "#!/bin/sh\necho unavailable >&2\nexit 7\n"
			}
			if err := os.WriteFile(filepath.Join(bin, "wt"), []byte(script), 0700); err != nil {
				t.Fatal(err)
			}
			t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
			tree, created, err := SwitchPR(repo, "https://github.com/owner/repo/pull/1")
			if kind == "failure" {
				if tree.Path != "" || created || err == nil || len(List(repo)) != 1 {
					t.Fatalf("%+v %v %v", tree, created, err)
				}
				return
			}
			if tree.Path == "" || tree.Branch != "fork/topic" || created != (kind != "existing") {
				t.Fatalf("%+v %v %v", tree, created, err)
			}
			if (err != nil) != (kind == "malformed") {
				t.Fatalf("unexpected error: %v", err)
			}
		})
	}
}
