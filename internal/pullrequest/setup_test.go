package pullrequest

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Files avoid pipe-buffer limits while capturing the same descriptors inherited
// by interactive hooks. These tests, like the fixture's environment, are serial.
func captureSetup(t *testing.T, path string, retry bool) (stdout, stderr string, err error) {
	t.Helper()
	out, e := os.CreateTemp(t.TempDir(), "stdout")
	if e != nil {
		t.Fatal(e)
	}
	defer out.Close()
	errs, e := os.CreateTemp(t.TempDir(), "stderr")
	if e != nil {
		t.Fatal(e)
	}
	defer errs.Close()
	oldOut, oldErr := os.Stdout, os.Stderr
	os.Stdout, os.Stderr = out, errs
	defer func() { os.Stdout, os.Stderr = oldOut, oldErr }()
	err = Setup(path, retry)
	a, e := os.ReadFile(out.Name())
	if e != nil {
		t.Fatal(e)
	}
	b, e := os.ReadFile(errs.Name())
	if e != nil {
		t.Fatal(e)
	}
	return string(a), string(b), err
}

func releasedSetupFixture(t *testing.T, existing bool) string {
	t.Helper()
	repo, path := fixture(t)
	if existing {
		git(t, repo, "worktree", "add", "-b", "feat/fix", path)
	}
	if _, err := Prepare(repo, "42"); err != nil {
		t.Fatal(err)
	}
	s, err := load(path)
	if err != nil {
		t.Fatal(err)
	}
	s.Released = true
	if err := save(path, s); err != nil {
		t.Fatal(err)
	}
	// Only subsequent setup calls matter for execution/inspection assertions.
	put(t, os.Getenv("PR_LOG"), "")
	return path
}

func setupCalls(t *testing.T) string {
	t.Helper()
	data, err := os.ReadFile(os.Getenv("PR_LOG"))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func assertNoHookExecution(t *testing.T, calls string) {
	t.Helper()
	for _, forbidden := range []string{"wt hook pre-start --", "wt hook post-start --", "wt hook post-switch --", "wt config approvals"} {
		if strings.Contains(calls, forbidden) {
			t.Fatalf("unexpected %s: %s", forbidden, calls)
		}
	}
}

func TestSetupEmptyPhasesSilentAndDurable(t *testing.T) {
	for _, existing := range []bool{false, true} {
		t.Run(map[bool]string{false: "new", true: "existing"}[existing], func(t *testing.T) {
			path := releasedSetupFixture(t, existing)
			t.Setenv("PR_HOOK_PHASES", "")
			// Empty phases do not even consult approval state.
			t.Setenv("PR_DENY", "1")
			for i := 0; i < 2; i++ {
				out, stderr, err := captureSetup(t, path, false)
				if err != nil || out != "" || stderr != "" {
					t.Fatalf("stdout=%q stderr=%q err=%v", out, stderr, err)
				}
			}
			s, err := load(path)
			wantStage := 3
			if existing {
				wantStage = 1
			}
			if err != nil || !s.Complete || s.Stage != wantStage || s.Failed != "" {
				t.Fatalf("%+v: %v", s, err)
			}
			calls := setupCalls(t)
			assertNoHookExecution(t, calls)
			for _, phase := range []string{"pre-start", "post-start", "post-switch"} {
				want := 1
				if existing && phase != "post-switch" {
					want = 0
				}
				if strings.Count(calls, "wt hook show "+phase+" --format=json") != want {
					t.Fatal(calls)
				}
			}
		})
	}
}

func TestSetupConfiguredHooksVisibleOnce(t *testing.T) {
	path := releasedSetupFixture(t, false)
	t.Setenv("PR_VISIBLE", "1")
	out, stderr, err := captureSetup(t, path, false)
	if err != nil {
		t.Fatal(err)
	}
	if out != "pre-start stdout\npost-start stdout\npost-switch stdout\n" || stderr != "pre-start stderr\npost-start stderr\npost-switch stderr\n" {
		t.Fatalf("stdout=%q stderr=%q", out, stderr)
	}
	out, stderr, err = captureSetup(t, path, false)
	if err != nil || out != "" || stderr != "" {
		t.Fatalf("stdout=%q stderr=%q err=%v", out, stderr, err)
	}
	calls := setupCalls(t)
	for _, phase := range []string{"pre-start", "post-start", "post-switch"} {
		if strings.Count(calls, "wt hook "+phase+" --") != 1 {
			t.Fatal(calls)
		}
	}
	if strings.Count(calls, "wt config approvals list --format=json") != 3 {
		t.Fatal(calls)
	}
}

func TestSetupInvalidHookInspectionDoesNotMutate(t *testing.T) {
	for _, raw := range []string{"{", "null", "{}", "false", "42", `"hooks"`} {
		t.Run(raw, func(t *testing.T) {
			path := releasedSetupFixture(t, false)
			t.Setenv("PR_HOOK_JSON", raw)
			before, err := load(path)
			if err != nil {
				t.Fatal(err)
			}
			put(t, filepath.Join(path, "keep"), "user data")
			for _, retry := range []bool{false, true} {
				out, stderr, err := captureSetup(t, path, retry)
				if err == nil || !strings.Contains(err.Error(), "valid JSON array") || out != "" || !strings.Contains(stderr, "Worktree setup failed:") || !strings.Contains(stderr, "--retry") {
					t.Fatalf("stdout=%q stderr=%q err=%v", out, stderr, err)
				}
				after, err := load(path)
				if err != nil || after != before {
					t.Fatalf("state changed: before=%+v after=%+v: %v", before, after, err)
				}
			}
			assertNoHookExecution(t, setupCalls(t))
			data, err := os.ReadFile(filepath.Join(path, "keep"))
			if err != nil || string(data) != "user data" {
				t.Fatal("partial resources changed")
			}
			t.Setenv("PR_HOOK_JSON", "[]")
			if _, _, err := captureSetup(t, path, true); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestSetupEmptyPhasesAdvanceBeforeFailure(t *testing.T) {
	path := releasedSetupFixture(t, false)
	t.Setenv("PR_HOOK_PHASES", "post-switch")
	t.Setenv("PR_HOOK_JSON", "")
	// Reuse the declined-approval fixture for the only configured phase.
	wt := filepath.Join(strings.Split(os.Getenv("PATH"), string(os.PathListSeparator))[0], "wt")
	data, err := os.ReadFile(wt)
	if err != nil {
		t.Fatal(err)
	}
	put(t, wt, strings.Replace(string(data), `"phase":"pre-start","approved":false`, `"phase":"post-switch","approved":false`, 1))
	t.Setenv("PR_DENY", "1")
	_, stderr, err := captureSetup(t, path, false)
	if err == nil || !strings.Contains(stderr, "approval declined") {
		t.Fatalf("%v: %s", err, stderr)
	}
	s, err := load(path)
	if err != nil || s.Stage != 2 || !strings.HasPrefix(s.Failed, "post-switch:") {
		t.Fatalf("%+v: %v", s, err)
	}
	calls := setupCalls(t)
	if strings.Contains(calls, "wt hook pre-start --") || strings.Contains(calls, "wt hook post-start --") || strings.Count(calls, "wt config approvals") != 1 {
		t.Fatal(calls)
	}
	t.Setenv("PR_DENY", "")
	if _, _, err := captureSetup(t, path, true); err != nil {
		t.Fatal(err)
	}
	calls = setupCalls(t)
	if strings.Count(calls, "wt hook show pre-start --") != 1 || strings.Count(calls, "wt hook show post-start --") != 1 {
		t.Fatal("reinspected completed empty phases: " + calls)
	}
}

func TestSetupEmptyInspectionCannotReplayInterruptedBackground(t *testing.T) {
	for _, phase := range []string{"post-start", "post-switch", "existing post-switch"} {
		t.Run(phase, func(t *testing.T) {
			path := releasedSetupFixture(t, strings.HasPrefix(phase, "existing"))
			t.Setenv("PR_HOOK_PHASES", "")
			s, _ := load(path)
			s.Stage, s.Failed = 1, "post-start interrupted"
			if phase == "post-switch" {
				s.Stage, s.Failed = 2, "post-switch interrupted"
			}
			if !s.New {
				s.Stage, s.Failed = 0, "post-switch interrupted"
			}
			if err := save(path, s); err != nil {
				t.Fatal(err)
			}
			_, stderr, err := captureSetup(t, path, true)
			if err == nil || !strings.Contains(stderr, "not replayed") {
				t.Fatalf("%v: %s", err, stderr)
			}
			after, err := load(path)
			if err != nil || after != s {
				t.Fatalf("%+v: %v", after, err)
			}
			calls := setupCalls(t)
			assertNoHookExecution(t, calls)
			if strings.Contains(calls, "wt hook show") {
				t.Fatal("inspection bypassed interrupted launch guard: " + calls)
			}
		})
	}
}
