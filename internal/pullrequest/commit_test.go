package pullrequest

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/rex"
)

func commitFixture(t *testing.T, state string, deleted bool) (string, string, string, string) {
	t.Helper()
	repo, path := fixture(t)
	oid := git(t, repo, "rev-parse", "HEAD")
	remote := filepath.Join(filepath.Dir(repo), "remote.git")
	git(t, repo, "clone", "--bare", repo, remote)
	git(t, remote, "update-ref", "refs/pull/42/head", oid)
	git(t, repo, "config", "url."+remote+".insteadOf", "https://github.com/acme/project.git")
	t.Setenv("GIT_ALLOW_PROTOCOL", "file") // Tests can never fetch over the network.
	metadata, _ := json.Marshal(map[string]any{"number": 42, "title": "Fix", "headRefName": "feat/fix", "state": state, "headRefOid": oid})
	ref := `{"name":"feat/fix"}`
	if deleted {
		ref = "null"
	}
	response := `{"data":{"repository":{"pullRequest":{"state":"` + state + `","headRefOid":"` + oid + `","headRef":` + ref + `}}}}`
	t.Setenv("PR_METADATA", string(metadata))
	t.Setenv("PR_GRAPHQL", response)
	bin := filepath.Join(filepath.Dir(repo), "bin")
	put(t, filepath.Join(bin, "gh"), `#!/bin/sh
printf 'gh %s\n' "$*" >> "$PR_LOG"
case "$1 $2" in
 'api --hostname')
  if [ "$4" = graphql ]; then
   [ -z "$PR_API_FAIL" ] || exit 9
   printf '%s\n' "$PR_GRAPHQL"
  else echo '{"base":{"repo":{"full_name":"acme/project"}}}'; fi;;
 'pr view') printf '%s\n' "$PR_METADATA";;
 *) exit 8;;
esac
`)
	wtPath := filepath.Join(bin, "wt")
	data, err := os.ReadFile(wtPath)
	if err != nil {
		t.Fatal(err)
	}
	text := strings.Replace(string(data), `git worktree add -q -b feat/fix "$PR_DEST"`, `git worktree add -q "$PR_DEST" pr/42`, 1)
	text = strings.Replace(text, `"branch":"feat/fix"`, `"branch":"pr/42"`, 1)
	put(t, wtPath, text)
	return repo, path, remote, oid
}

func TestHeadMetadata(t *testing.T) {
	for _, state := range []string{"OPEN", "CLOSED", "MERGED"} {
		for _, deleted := range []bool{false, true} {
			t.Run(state+"/"+map[bool]string{true: "deleted", false: "present"}[deleted], func(t *testing.T) {
				repo, _, _, oid := commitFixture(t, state, deleted)
				info, err := Resolve(repo, "42")
				if err != nil || info.State != state || info.HeadDeleted != deleted || info.HeadOID != oid || info.Branch != "feat/fix" {
					t.Fatalf("%+v %v", info, err)
				}
			})
		}
	}
}

func TestNormalPrepareWithHeadMetadata(t *testing.T) {
	for _, state := range []string{"OPEN", "CLOSED", "MERGED"} {
		t.Run(state, func(t *testing.T) {
			repo, path, _, _ := commitFixture(t, state, false)
			wtPath := filepath.Join(filepath.Dir(repo), "bin", "wt")
			data, err := os.ReadFile(wtPath)
			if err != nil {
				t.Fatal(err)
			}
			text := strings.Replace(string(data), `git worktree add -q "$PR_DEST" pr/42`, `git worktree add -q -b feat/fix "$PR_DEST"`, 1)
			text = strings.Replace(text, `"branch":"pr/42"`, `"branch":"feat/fix"`, 1)
			put(t, wtPath, text)
			info, err := Prepare(repo, "42")
			if err != nil || info.HeadDeleted || info.Branch != "feat/fix" || !Ready(path) {
				t.Fatalf("%+v %v", info, err)
			}
			calls, _ := os.ReadFile(os.Getenv("PR_LOG"))
			if !strings.Contains(string(calls), "switch --no-hooks --no-cd --format=json https://github.com/acme/project/pull/42") {
				t.Fatal(string(calls))
			}
		})
	}
}

func TestHeadMetadataFailureIsNotDeletion(t *testing.T) {
	for _, mode := range []string{"network", "missing", "errors"} {
		t.Run(mode, func(t *testing.T) {
			repo, _, _, _ := commitFixture(t, "CLOSED", false)
			switch mode {
			case "network":
				t.Setenv("PR_API_FAIL", "1")
			case "missing":
				t.Setenv("PR_GRAPHQL", `{}`)
			case "errors":
				t.Setenv("PR_GRAPHQL", `{"errors":[{"message":"denied"}]}`)
			}
			info, err := Resolve(repo, "42")
			if err == nil || info.HeadDeleted {
				t.Fatalf("%+v %v", info, err)
			}
		})
	}
}

func TestDeletedHeadDefaultRefusal(t *testing.T) {
	repo, path, _, _ := commitFixture(t, "CLOSED", true)
	before := git(t, repo, "show-ref")
	info, err := Prepare(repo, "42")
	if err == nil || !strings.Contains(err.Error(), "Check out PR commit") || !info.HeadDeleted {
		t.Fatalf("%+v %v", info, err)
	}
	if git(t, repo, "show-ref") != before {
		t.Fatal("refs changed")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("created worktree")
	}
	if _, err := os.Stat(filepath.Join(os.Getenv("XDG_STATE_HOME"), "raptor", "pullrequest")); !os.IsNotExist(err) {
		t.Fatal("created state before refusal")
	}
	calls, _ := os.ReadFile(os.Getenv("PR_LOG"))
	if strings.Contains(string(calls), "switch --") || strings.Contains(string(calls), "clone") {
		t.Fatal(string(calls))
	}
}

func TestExplicitCommitCheckout(t *testing.T) {
	repo, path, _, oid := commitFixture(t, "CLOSED", true)
	preview, err := ResolveWithOptions(repo, "42", true)
	if err != nil || preview.Branch != "pr/42" || preview.Path != path {
		t.Fatalf("%+v %v", preview, err)
	}
	// The original local branch, if present, is unrelated and must remain untouched.
	git(t, repo, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "unrelated")
	original := git(t, repo, "rev-parse", "HEAD")
	git(t, repo, "branch", "feat/fix")
	for i := 0; i < 2; i++ {
		info, err := PrepareWithOptions(repo, "42", true)
		if err != nil || info.Branch != "pr/42" || info.Path != path || info.Existing != (i == 1) {
			t.Fatalf("%+v %v", info, err)
		}
		if !Ready(path) {
			t.Fatal("missing bound setup journal")
		}
	}
	if got := git(t, path, "rev-parse", "HEAD"); got != oid {
		t.Fatal(got)
	}
	if got := git(t, repo, "rev-parse", "feat/fix"); got != original {
		t.Fatal("original branch changed")
	}
	if got := git(t, repo, "for-each-ref", "refs/raptor/"); got != "" {
		t.Fatal("temporary refs leaked: " + got)
	}
	if _, err := os.Stat(filepath.Join(repo, ".git", "FETCH_HEAD")); !os.IsNotExist(err) {
		t.Fatal("wrote FETCH_HEAD")
	}
	s, err := load(path)
	if err != nil || !s.New || s.Branch != "pr/42" {
		t.Fatalf("%+v %v", s, err)
	}
	if _, err := Open(path, "session", rex.Ctx{Client: "client"}); err != nil {
		t.Fatal(err)
	}
	if err := Setup(path, false); err != nil {
		t.Fatal(err)
	}
	calls, _ := os.ReadFile(os.Getenv("PR_LOG"))
	if strings.Count(string(calls), "wt hook pre-start --") != 1 || strings.Count(string(calls), "wt hook post-start --") != 1 || !strings.Contains(string(calls), "switch --no-hooks --no-cd --format=json pr/42") {
		t.Fatal(string(calls))
	}
}

func TestCommitCheckoutRefSafety(t *testing.T) {
	for _, mode := range []string{"missing", "mismatch", "collision", "symbolic", "dangling-symbolic", "same-oid", "pre-switch", "partial-switch"} {
		t.Run(mode, func(t *testing.T) {
			repo, path, remote, oid := commitFixture(t, "MERGED", true)
			git(t, repo, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "other")
			other := git(t, repo, "rev-parse", "HEAD")
			switch mode {
			case "missing":
				git(t, remote, "update-ref", "-d", "refs/pull/42/head")
			case "mismatch":
				git(t, repo, "push", remote, "HEAD:refs/pull/42/head") // Local fixture only.
			case "collision":
				git(t, repo, "branch", "pr/42", other)
			case "symbolic":
				git(t, repo, "symbolic-ref", "refs/heads/pr/42", "refs/heads/main")
			case "dangling-symbolic":
				git(t, repo, "symbolic-ref", "refs/heads/pr/42", "refs/heads/missing")
			case "same-oid":
				git(t, repo, "branch", "pr/42", oid)
			case "pre-switch":
				t.Setenv("PR_PRE_SWITCH", "1")
			case "partial-switch":
				t.Setenv("PR_SWITCH_FAIL", "1")
			}
			info, err := PrepareWithOptions(repo, "42", true)
			if mode == "same-oid" {
				if err != nil || !Ready(path) {
					t.Fatalf("%+v %v", info, err)
				}
			} else if mode == "partial-switch" {
				if err == nil || !Ready(path) {
					t.Fatalf("%+v %v", info, err)
				}
			} else {
				if err == nil {
					t.Fatal("expected refusal")
				}
				if _, err := os.Stat(path); !os.IsNotExist(err) {
					t.Fatal("worktree created")
				}
			}
			if mode == "symbolic" && git(t, repo, "symbolic-ref", "refs/heads/pr/42") != "refs/heads/main" {
				t.Fatal("symbolic ref changed")
			}
			if mode == "dangling-symbolic" && git(t, repo, "symbolic-ref", "refs/heads/pr/42") != "refs/heads/missing" {
				t.Fatal("dangling symbolic ref changed")
			}
			if mode == "collision" && git(t, repo, "rev-parse", "pr/42") != other {
				t.Fatal("collision overwritten")
			}
			if git(t, repo, "rev-parse", "HEAD") != other {
				t.Fatal("source HEAD changed")
			}
			if got := git(t, repo, "for-each-ref", "refs/raptor/"); got != "" {
				t.Fatal("temporary ref leaked: " + got)
			}
		})
	}
}
