package pullrequest

import (
	"os"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/rex"
)

func TestDestinationLabel(t *testing.T) {
	for _, tc := range []struct {
		state setupState
		want  string
	}{
		{setupState{URL: "https://github.com/loveholidays/aurora/pull/10990", Branch: "fix/cancellation-page-back-navigation"}, "aurora-pr-10990-fix-cancellation-page-back-navigation"},
		{setupState{URL: "https://github.com/acme/project/pull/42", Branch: "feat/nested/topic"}, "project-pr-42-feat-nested-topic"},
		{setupState{Path: "/worktrees/project/feat-login", Branch: "feat/login"}, "feat-login"},
	} {
		if got := destinationLabel(tc.state); got != tc.want {
			t.Fatalf("label = %q, want %q", got, tc.want)
		}
	}
}

func TestRepeatedPROpenReusesNamedDestinationAndSetup(t *testing.T) {
	for _, target := range []string{"session", "tab"} {
		t.Run(target, func(t *testing.T) {
			repo, _ := fixture(t)
			ctx := rex.Ctx{Session: "origin", Block: "source", Client: "client"}
			first, err := Prepare(repo, "42")
			if err != nil {
				t.Fatal(err)
			}
			opened, err := Open(first.Path, target, ctx)
			if err != nil {
				t.Fatal(err)
			}
			if err := Setup(first.Path, false); err != nil {
				t.Fatal(err)
			}
			second, err := Prepare(repo, "https://github.com/acme/project/pull/42")
			if err != nil || !second.Existing || second.Path != first.Path {
				t.Fatalf("second preparation: %+v: %v", second, err)
			}
			reused, err := Open(second.Path, target, ctx)
			if err != nil || reused != opened {
				t.Fatalf("second open: %+v, first %+v: %v", reused, opened, err)
			}
			if err := Setup(second.Path, false); err != nil {
				t.Fatal(err)
			}
			data, _ := os.ReadFile(os.Getenv("PR_LOG"))
			calls := string(data)
			create := "rex new project-pr-42-feat-fix "
			if target == "tab" {
				create = "rex window new -s origin project-pr-42-feat-fix "
			}
			if strings.Count(calls, create) != 1 || strings.Count(calls, "wt hook pre-start ") != 1 {
				t.Fatalf("repeated open duplicated creation/setup: %s", calls)
			}
		})
	}
}
