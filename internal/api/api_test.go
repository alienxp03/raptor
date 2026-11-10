package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
	"github.com/alienxp03/raptor/internal/worktree"
)

type wireResponse struct {
	ID     int64           `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  string          `json:"error"`
}

func TestStreamRecovery(t *testing.T) {
	h := New(rex.Ctx{}, config.Default())
	lines := []string{
		`{`,
		`{"id":2,"method":"missing","params":{}}`,
		`{"id":3,"method":"directories","params":[]}`,
		`{"id":4,"method":"directories","params":{"query":42}}`,
		`{"method":"directories","params":{}}`,
		`{"id":1.5,"method":"directories","params":{}}`,
		`{"id":7,"method":"directories","params":null}`,
		`{"id":8,"method":"directories"}`,
		`{"id":9,"method":"worktrees.list","params":{}}`,
	}
	var output bytes.Buffer
	// No final newline: the final request must still be processed.
	if err := h.Serve(strings.NewReader(strings.Join(lines, "\n")), &output); err != nil {
		t.Fatal(err)
	}
	decoder := json.NewDecoder(&output)
	for i := range lines {
		var res wireResponse
		if err := decoder.Decode(&res); err != nil {
			t.Fatal(err)
		}
		if i < len(lines)-1 {
			if res.Error == "" || res.Result != nil {
				t.Fatalf("expected error at %d: %+v", i, res)
			}
		} else {
			var result treeResult
			if err := json.Unmarshal(res.Result, &result); err != nil {
				t.Fatal(err)
			}
			if res.ID != 9 || res.Error != "" || !result.NeedsRepo || result.Repo != "" || result.Items == nil || result.Branches == nil {
				t.Fatalf("unexpected final response: %+v %s", res, res.Result)
			}
		}
		if i == 1 && res.ID != 2 {
			t.Fatal("request id not preserved")
		}
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		t.Fatalf("extra stdout: %v", err)
	}
}

func TestBoundedRequests(t *testing.T) {
	h := New(rex.Ctx{}, config.Default())
	valid := `{"id":12,"method":"worktrees.list","params":{}}`
	for _, input := range []string{
		strings.Repeat("x", MaxRequestSize+1) + "\n" + valid,
		strings.Repeat("x", MaxRequestSize+1),
	} {
		var out bytes.Buffer
		if err := h.Serve(strings.NewReader(input), &out); err != nil {
			t.Fatal(err)
		}
		decoder := json.NewDecoder(&out)
		var res wireResponse
		if err := decoder.Decode(&res); err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(res.Error, "maximum size") {
			t.Fatalf("unexpected response: %+v", res)
		}
		if strings.HasSuffix(input, valid) {
			res = wireResponse{}
			if err := decoder.Decode(&res); err != nil {
				t.Fatal(err)
			}
			if res.ID != 12 || res.Error != "" {
				t.Fatalf("stream did not recover: %+v", res)
			}
		}
	}
	// Exactly the limit is accepted, including when the newline is a separate read.
	var out bytes.Buffer
	input := valid + strings.Repeat(" ", MaxRequestSize-len(valid)) + "\n"
	if err := h.Serve(strings.NewReader(input), &out); err != nil {
		t.Fatal(err)
	}
	var res wireResponse
	if err := json.Unmarshal(out.Bytes(), &res); err != nil || res.Error != "" {
		t.Fatalf("boundary rejected: %s, %v", out.Bytes(), err)
	}
}

type brokenIO struct{}

func (brokenIO) Read([]byte) (int, error)  { return 0, io.ErrUnexpectedEOF }
func (brokenIO) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }

func TestStreamIOErrors(t *testing.T) {
	h := New(rex.Ctx{}, config.Default())
	if err := h.Serve(brokenIO{}, io.Discard); !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatal(err)
	}
	if err := h.Serve(strings.NewReader("{}\n"), brokenIO{}); !errors.Is(err, io.ErrClosedPipe) {
		t.Fatal(err)
	}
}

// A pipe client proves responses arrive before EOF and one backend survives all
// calls, including validation and Git failures.
func client(t *testing.T, h *Handler) func(string, any, any) string {
	t.Helper()
	input, requests := io.Pipe()
	responses, output := io.Pipe()
	done := make(chan error, 1)
	go func() { done <- h.Serve(input, output); _ = output.Close() }()
	t.Cleanup(func() {
		_ = requests.Close()
		if err := <-done; err != nil {
			t.Error(err)
		}
		_ = responses.Close()
	})
	encoder, decoder := json.NewEncoder(requests), json.NewDecoder(responses)
	var id int64
	return func(method string, params any, result any) string {
		t.Helper()
		id++
		if err := encoder.Encode(map[string]any{"id": id, "method": method, "params": params}); err != nil {
			t.Fatal(err)
		}
		var res wireResponse
		if err := decoder.Decode(&res); err != nil {
			t.Fatal(err)
		}
		if res.ID != id {
			t.Fatalf("id: got %d want %d", res.ID, id)
		}
		if res.Error != "" {
			if res.Result != nil {
				t.Fatal("error response includes result")
			}
			return res.Error
		}
		if len(res.Result) == 0 || res.Result[0] != '{' {
			t.Fatalf("result must be object: %s", res.Result)
		}
		if result != nil {
			if err := json.Unmarshal(res.Result, result); err != nil {
				t.Fatal(err)
			}
		}
		return ""
	}
}

func fixtureRepo(t *testing.T) string {
	t.Helper()
	isolateWorktrunk(t)
	repo := filepath.Join(t.TempDir(), ".sample")
	if err := os.Mkdir(repo, 0755); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{
		{"init", "-b", "main"}, {"config", "user.name", "Test"}, {"config", "user.email", "test@example.com"},
		{"-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "initial"},
	} {
		if _, err := worktree.GitOut(repo, args...); err != nil {
			t.Fatal(err)
		}
	}
	return worktree.RepoRoot(repo)
}

func TestWorktreeListSuggestedBranch(t *testing.T) {
	repo := fixtureRepo(t)
	root := t.TempDir()
	cfg := config.Default()
	cfg.WorktreeRoot = filepath.Join(root, "not-created")
	call := client(t, New(rex.Ctx{}, cfg))
	beforeBranches, beforeTrees := worktree.LocalBranches(repo), worktree.List(repo)
	var wire map[string]json.RawMessage
	if err := call("worktrees.list", map[string]any{"repo": repo, "query": "no-matching-worktree"}, &wire); err != "" {
		t.Fatal(err)
	}
	var name string
	if err := json.Unmarshal(wire["suggested_branch"], &name); err != nil || name == "" {
		t.Fatalf("missing suggested_branch: %v %v", wire, err)
	}
	parts := strings.Split(name, "-")
	if len(parts) != 2 || parts[0] == parts[1] {
		t.Fatalf("not two distinct words: %q", name)
	}
	if err := worktree.Validate(repo, name, "main", worktree.Path(repo, name, cfg)); err != nil {
		t.Fatalf("unavailable suggestion: %v", err)
	}
	if !reflect.DeepEqual(beforeBranches, worktree.LocalBranches(repo)) || !reflect.DeepEqual(beforeTrees, worktree.List(repo)) {
		t.Fatal("list claimed a name or created a worktree")
	}
	if _, err := os.Lstat(cfg.WorktreeRoot); !os.IsNotExist(err) {
		t.Fatalf("list created destination: %v", err)
	}
	// The suggestion is not reserved; create still rejects a later collision.
	if _, err := worktree.GitOut(repo, "branch", name); err != nil {
		t.Fatal(err)
	}
	if err := call("worktrees.create", map[string]any{"repo": repo, "branch": name, "base": "main"}, nil); !strings.Contains(err, "already exists") {
		t.Fatalf("stale suggestion bypassed validation: %s", err)
	}
}

func TestWorktreeListOmitsUnavailableSuggestion(t *testing.T) {
	for _, scenario := range []string{"no-repo", "unborn", "destination-error"} {
		t.Run(scenario, func(t *testing.T) {
			cfg := config.Default()
			cfg.WorktreeRoot = t.TempDir()
			params := map[string]any{}
			if scenario == "unborn" {
				repo := t.TempDir()
				if _, err := worktree.GitOut(repo, "init", "-b", "main"); err != nil {
					t.Fatal(err)
				}
				params["repo"] = repo
			} else if scenario == "destination-error" {
				params["repo"] = fixtureRepo(t)
				cfg.WorktreeRoot = filepath.Join(cfg.WorktreeRoot, "loop")
				if err := os.Symlink(cfg.WorktreeRoot, cfg.WorktreeRoot); err != nil {
					t.Fatal(err)
				}
				t.Setenv("WORKTRUNK_WORKTREE_PATH", filepath.Join(cfg.WorktreeRoot, "{{ repo }}", "{{ branch | sanitize }}"))
			}
			call := client(t, New(rex.Ctx{}, cfg))
			var result map[string]json.RawMessage
			if err := call("worktrees.list", params, &result); err != "" {
				t.Fatal(err)
			}
			if _, exists := result["suggested_branch"]; exists {
				t.Fatalf("empty suggestion must be omitted: %v", result)
			}
			if result["items"] == nil || result["branches"] == nil || result["destination_root"] == nil {
				t.Fatalf("normal metadata lost: %v", result)
			}
		})
	}
}

func TestWorktreeLifecycle(t *testing.T) {
	repo := fixtureRepo(t)
	cfg := config.Default()
	cfg.WorktreeRoot = t.TempDir()
	call := client(t, New(rex.Ctx{}, cfg))
	params := map[string]any{"repo": repo, "branch": "feat/native", "base": "main"}
	var preview previewResult
	if err := call("worktrees.preview", params, &preview); err != "" {
		t.Fatal(err)
	}
	want, pathErr := worktree.PreviewPath(repo, "feat/native")
	if pathErr != nil {
		t.Fatal(pathErr)
	}
	if preview.Path != want || preview.ValidationError != "" {
		t.Fatalf("preview: %+v", preview)
	}
	bad := map[string]any{"repo": repo, "branch": "invalid branch", "base": "main"}
	if err := call("worktrees.preview", bad, &preview); err != "" || preview.ValidationError == "" {
		t.Fatalf("validation must be result: %+v %s", preview, err)
	}
	if err := call("worktrees.create", bad, nil); err == "" {
		t.Fatal("invalid branch accepted")
	}
	bad["branch"], bad["base"] = "feat/valid", "missing"
	if err := call("worktrees.preview", bad, &preview); err != "" || !strings.Contains(preview.ValidationError, "base branch not found") {
		t.Fatalf("base validation: %+v %s", preview, err)
	}
	var created pathResult
	if err := call("worktrees.create", params, &created); err != "" {
		t.Fatal(err)
	}
	if created.Path != want {
		t.Fatalf("path %s", created.Path)
	}
	if err := call("worktrees.create", params, nil); err == "" {
		t.Fatal("duplicate create accepted")
	}
	if err := call("worktrees.preview", params, &preview); err != "" || !strings.Contains(preview.ValidationError, "already exists") {
		t.Fatalf("duplicate preview: %+v %s", preview, err)
	}
	var listed treeResult
	if err := call("worktrees.list", map[string]any{"repo": repo}, &listed); err != "" {
		t.Fatal(err)
	}
	if listed.DestinationRoot != filepath.Dir(want) || listed.Repo != repo || listed.NeedsRepo || len(listed.Items) != 2 || !listed.Items[0].IsMain || listed.BaseBranch != "main" {
		t.Fatalf("list: %+v", listed)
	}
	if !reflect.DeepEqual(listed.Branches, []string{"feat/native", "main"}) || !reflect.DeepEqual(listed.Targets, cfg.AvailableTargets(false)) || listed.Target != cfg.Enter {
		t.Fatalf("metadata: %+v", listed)
	}
	for _, query := range []string{"fnt", "sample", "does-not-match"} {
		if err := call("worktrees.list", map[string]any{"repo": repo, "query": query}, &listed); err != "" {
			t.Fatal(err)
		}
		trees := worktree.List(repo)
		indices := catalog.FilterWorktrees(trees, query)
		if len(listed.Items) != len(indices) {
			t.Fatalf("query %q differs from shared matcher", query)
		}
		for i, index := range indices {
			if listed.Items[i].Path != trees[index].Path {
				t.Fatal("query order differs")
			}
		}
	}
	for _, path := range []string{repo, filepath.Join(cfg.WorktreeRoot, "unknown"), ""} {
		if err := call("worktrees.remove", map[string]any{"repo": repo, "path": path}, nil); err == "" {
			t.Fatalf("unsafe removal allowed: %q", path)
		}
	}
	dirty := filepath.Join(want, "untracked.txt")
	if err := os.WriteFile(dirty, []byte("keep"), 0644); err != nil {
		t.Fatal(err)
	}
	remove := map[string]any{"repo": repo, "path": want}
	if err := call("worktrees.remove", remove, nil); err == "" {
		t.Fatal("dirty tree removed")
	}
	if _, err := os.Stat(dirty); err != nil {
		t.Fatal("dirty content lost", err)
	}
	if err := os.Remove(dirty); err != nil {
		t.Fatal(err)
	}
	if _, err := worktree.GitOut(repo, "worktree", "lock", want); err != nil {
		t.Fatal(err)
	}
	if err := call("worktrees.remove", remove, nil); err == "" {
		t.Fatal("locked tree removed")
	}
	if _, err := worktree.GitOut(repo, "worktree", "unlock", want); err != nil {
		t.Fatal(err)
	}
	if err := call("worktrees.remove", remove, nil); err != "" {
		t.Fatal(err)
	}
	if _, err := os.Stat(want); !os.IsNotExist(err) {
		t.Fatalf("tree still exists: %v", err)
	}
	if err := call("worktrees.remove", remove, nil); err == "" {
		t.Fatal("stale removal accepted")
	}
	if _, err := worktree.GitOut(repo, "show-ref", "--verify", "refs/heads/feat/native"); err != nil {
		t.Fatal("branch removed", err)
	}
	if err := call("worktrees.list", map[string]any{"repo": repo}, &listed); err != "" || len(listed.Items) != 1 {
		t.Fatalf("final list: %+v %s", listed, err)
	}
}

func fakeTool(t *testing.T, name, script string) {
	t.Helper()
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, name), []byte("#!/bin/sh\n"+script), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func TestDirectoryQueries(t *testing.T) {
	repo := fixtureRepo(t)
	sub := filepath.Join(repo, "subdir")
	if err := os.Mkdir(sub, 0755); err != nil {
		t.Fatal(err)
	}
	other := t.TempDir()
	dirs := []string{other, sub, repo, other}
	t.Setenv("RAPTOR_TEST_DIRS", strings.Join(dirs, "\n"))
	fakeTool(t, "zoxide", "printf '%s\\n' \"$RAPTOR_TEST_DIRS\"\n")
	cfg := config.Default()
	cfg.Enter = "session"
	call := client(t, New(rex.Ctx{}, cfg))
	for _, reposOnly := range []bool{false, true} {
		for _, query := range []string{"", "sbd", "sample", "no-such-match"} {
			var result directoryResult
			if err := call("directories", map[string]any{"query": query, "repos_only": reposOnly}, &result); err != "" {
				t.Fatal(err)
			}
			items := catalog.DirectoryItems(dirs, reposOnly)
			want := []catalog.Directory{}
			for _, index := range catalog.FilterDirectories(items, query) {
				want = append(want, items[index])
			}
			if !reflect.DeepEqual(result.Items, want) || result.Target != cfg.Enter || !reflect.DeepEqual(result.Targets, cfg.AvailableTargets(false)) {
				t.Fatalf("directory query: %+v want %+v", result, want)
			}
		}
	}
}

func TestDirectoryListFollowsZoxide(t *testing.T) {
	repo := fixtureRepo(t)
	t.Setenv("RAPTOR_TEST_CWD", repo)
	fakeTool(t, "rex", "printf '%s\\n' \"$RAPTOR_TEST_CWD\"\n")
	fakeTool(t, "zoxide", "printf '%s\\n' /other \"$RAPTOR_TEST_CWD\"\n")
	call := client(t, New(rex.Ctx{Block: "origin"}, config.Default()))
	cases := []struct {
		query string
		paths []string
	}{
		{"", []string{"/other", repo}},
		{"no-such-match", nil},
		{"other", []string{"/other"}},
	}
	for _, c := range cases {
		var result directoryResult
		if err := call("directories", map[string]any{"query": c.query}, &result); err != "" {
			t.Fatal(err)
		}
		paths := []string(nil)
		for _, item := range result.Items {
			paths = append(paths, item.Path)
		}
		if !reflect.DeepEqual(paths, c.paths) {
			t.Fatalf("query %q: got %v want %v", c.query, paths, c.paths)
		}
	}
}

func TestRepoResolutionAndErrors(t *testing.T) {
	repo := fixtureRepo(t)
	t.Setenv("RAPTOR_TEST_CWD", repo)
	fakeTool(t, "rex", "printf '%s\\n' \"$RAPTOR_TEST_CWD\"\n")
	call := client(t, New(rex.Ctx{Block: "origin"}, config.Default()))
	var result treeResult
	if err := call("worktrees.list", map[string]any{}, &result); err != "" || result.Repo != repo || result.NeedsRepo {
		t.Fatalf("inference: %+v %s", result, err)
	}
	for _, method := range []string{"worktrees.list", "worktrees.preview", "worktrees.create", "worktrees.remove"} {
		if err := call(method, map[string]any{"repo": t.TempDir()}, nil); !strings.Contains(err, "not a git repository") {
			t.Fatalf("invalid repo %s: %s", method, err)
		}
	}
	noOrigin := client(t, New(rex.Ctx{}, config.Default()))
	for _, method := range []string{"worktrees.preview", "worktrees.create", "worktrees.remove"} {
		if err := noOrigin(method, map[string]any{}, nil); err != "choose a repository" {
			t.Fatalf("missing repo %s: %s", method, err)
		}
	}
	for _, target := range []string{"tab", "pane_right", "here", "unknown"} {
		if err := noOrigin("dispatch", map[string]any{"target": target, "path": repo}, nil); err == "" {
			t.Fatalf("dispatch %s should fail", target)
		}
	}
	if err := noOrigin("dispatch", map[string]any{"target": "tab"}, nil); err != "path is required" {
		t.Fatal(err)
	}
}

func TestDispatchUsesOrigin(t *testing.T) {
	cache := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", cache)
	log := filepath.Join(t.TempDir(), "rex.log")
	t.Setenv("RAPTOR_TEST_LOG", log)
	fakeTool(t, "rex", `printf '%s\n' "$*" >> "$RAPTOR_TEST_LOG"
case "$1" in
window) printf '{"window_id":"new-window"}\n' ;;
focus) ;;
*) exit 1 ;;
esac
`)
	cfg := config.Default()
	ctx := rex.Ctx{Session: "origin-session", Block: "origin-block"}
	call := client(t, New(ctx, cfg))
	var result map[string]any
	if err := call("dispatch", map[string]any{"target": "tab", "path": "/tmp/project"}, &result); err != "" {
		t.Fatal(err)
	}
	// Dispatch reports its outcome (path/session IDs) and, when a launcher
	// snapshot already exists, authoritative rows covering any new session.
	if _, ok := result["error"]; ok {
		t.Fatalf("successful dispatch must not carry an error: %v", result)
	}
	data, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	want := "window new -s origin-session project -c /tmp/project --json\nfocus -s origin-session new-window\n"
	if string(data) != want {
		t.Fatalf("origin not forwarded: %s", data)
	}
	if _, err := os.Stat(filepath.Join(cache, "rex", "raptor-last-pane")); !os.IsNotExist(err) {
		t.Fatalf("tab dispatch must not write Last Pane history: %v", err)
	}
}
