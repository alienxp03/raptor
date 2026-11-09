package worktree

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/alienxp03/raptor/internal/execx"
)

// CommandError preserves Worktrunk diagnostics, including a failed command's
// JSON output. Callers must retain any returned worktree when this is non-nil.
type CommandError struct {
	Args   []string
	Code   int
	Stderr string
	Stdout string
	Err    error
}

func (e *CommandError) Error() string {
	detail := strings.TrimSpace(e.Stderr)
	if detail == "" && e.Err != nil {
		detail = e.Err.Error()
	}
	return fmt.Sprintf("wt %s (exit %d): %s", strings.Join(e.Args, " "), e.Code, detail)
}
func (e *CommandError) Unwrap() error { return e.Err }

func wtOut(repo string, args ...string) (string, error) {
	return wtRun(repo, nil, args...)
}

func wtRun(repo string, env []string, args ...string) (string, error) {
	name, command := "wt", args
	if len(env) > 0 {
		name = "env"
		command = append(append(env, "wt"), args...)
	}
	r, err := execx.Run(repo, 2*time.Minute, name, command...)
	if err != nil || r.Code != 0 {
		code := r.Code
		if err != nil && code == 0 {
			code = -1 // No process exit status (start failure or timeout).
		}
		return r.Stdout, &CommandError{Args: args, Code: code, Stderr: r.Stderr, Stdout: r.Stdout, Err: err}
	}
	return r.Stdout, nil
}

// PreviewPath evaluates Worktrunk's configured template without creating refs,
// directories, or running hooks. Existing worktrees keep their current paths.
func PreviewPath(repo, branch string) (string, error) {
	if branch == "" {
		return "", fmt.Errorf("enter a branch name")
	}
	for _, tree := range List(repo) {
		if tree.Branch == branch {
			return tree.Path, nil
		}
	}
	out, err := wtOut(repo, "config", "show", "--format=json")
	if err != nil {
		return "", err
	}
	type settings struct {
		Path     string `json:"worktree-path"`
		Projects map[string]struct {
			Path string `json:"worktree-path"`
		} `json:"projects"`
	}
	var info struct {
		User struct {
			Config settings `json:"config"`
		} `json:"user"`
		System struct {
			Config settings `json:"config"`
		} `json:"system"`
		Project struct {
			Identifier string `json:"identifier"`
		} `json:"project"`
	}
	if err := json.Unmarshal([]byte(out), &info); err != nil {
		return "", fmt.Errorf("parse wt config: %w", err)
	}
	template := "{{ repo_path }}/../{{ repo }}.{{ branch | sanitize }}"
	for _, source := range []settings{info.System.Config, info.User.Config} {
		if source.Path != "" {
			template = source.Path
		}
		keys := make([]string, 0, len(source.Projects))
		for key := range source.Projects {
			keys = append(keys, key)
		}
		sort.Slice(keys, func(i, j int) bool {
			a, b := keys[i], keys[j]
			if strings.Contains(a, "*") != strings.Contains(b, "*") {
				return strings.Contains(a, "*")
			}
			na, nb := len(strings.ReplaceAll(a, "*", "")), len(strings.ReplaceAll(b, "*", ""))
			if na != nb {
				return na < nb
			}
			return a < b
		})
		for _, key := range keys {
			pattern := "^" + strings.ReplaceAll(regexp.QuoteMeta(key), `\*`, ".*") + "$"
			if ok, _ := regexp.MatchString(pattern, info.Project.Identifier); ok && source.Projects[key].Path != "" {
				template = source.Projects[key].Path
			}
		}
	}
	if override, ok := os.LookupEnv("WORKTRUNK_WORKTREE_PATH"); ok {
		template = override
	}
	// Let Worktrunk evaluate its own variables and filters, not a Raptor clone
	// of MiniJinja. JSON quotes are also valid MiniJinja string literals.
	expression := "{% set branch = " + strconv.Quote(branch) + " %}" + template
	// step eval also builds hook context and caches default-branch detection
	// in .git/config. Path templates do not use that variable. Supply a valid
	// branch through Git's command environment to keep previews read-only.
	var env []string
	if branches := LocalBranches(repo); len(branches) > 0 {
		n, err := strconv.Atoi(os.Getenv("GIT_CONFIG_COUNT"))
		if err != nil && os.Getenv("GIT_CONFIG_COUNT") != "" {
			return "", fmt.Errorf("invalid GIT_CONFIG_COUNT: %w", err)
		}
		env = []string{
			fmt.Sprintf("GIT_CONFIG_COUNT=%d", n+1),
			fmt.Sprintf("GIT_CONFIG_KEY_%d=worktrunk.default-branch", n),
			fmt.Sprintf("GIT_CONFIG_VALUE_%d=%s", n, branches[0]),
		}
	}
	out, err = wtRun(repo, env, "step", "eval", "--format=json", expression)
	if err != nil {
		return "", err
	}
	var result struct {
		Result string `json:"result"`
	}
	if err := json.Unmarshal([]byte(out), &result); err != nil {
		return "", fmt.Errorf("parse wt preview: %w", err)
	}
	path := result.Result
	if path == "" {
		return "", fmt.Errorf("wt returned an empty destination")
	}
	if path == "~" || strings.HasPrefix(path, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		path = filepath.Join(home, strings.TrimPrefix(path, "~"))
	}
	if !filepath.IsAbs(path) {
		trees := List(repo)
		if len(trees) == 0 {
			return "", fmt.Errorf("cannot find primary worktree for relative wt destination")
		}
		path = filepath.Join(trees[0].Path, path)
	}
	return filepath.Clean(path), nil
}

// SwitchPR switches to a PR through Worktrunk. The bool reports a newly
// registered worktree, not a newly created branch. Setup hooks are deferred:
// callers must run visible setup only for newly created worktrees.
// On failure a non-empty worktree and true must be preserved for recovery.
func SwitchPR(repo, url string) (Worktree, bool, error) {
	if strings.TrimSpace(url) == "" || strings.HasPrefix(url, "-") {
		return Worktree{}, false, fmt.Errorf("enter a PR URL")
	}
	return switchWorktree(repo, url)
}

func switchWorktree(repo string, args ...string) (Worktree, bool, error) {
	before, err := listWorktrees(repo)
	if err != nil {
		return Worktree{}, false, err
	}
	known := map[string]bool{}
	for _, tree := range before {
		known[tree.Path] = true
	}
	command := append([]string{"switch", "--no-hooks", "--no-cd", "--format=json"}, args...)
	out, runErr := wtOut(repo, command...)
	var result struct {
		Path   string `json:"path"`
		Branch string `json:"branch"`
	}
	parseErr := json.Unmarshal([]byte(out), &result)
	if parseErr != nil {
		runErr = errors.Join(runErr, fmt.Errorf("parse wt switch: %w", parseErr))
	} else if result.Path == "" {
		runErr = errors.Join(runErr, fmt.Errorf("wt returned no worktree destination"))
	}
	after, listErr := listWorktrees(repo)
	if listErr != nil {
		return Worktree{Path: result.Path, Branch: result.Branch}, false, errors.Join(runErr, listErr)
	}
	if resolved, err := filepath.EvalSymlinks(result.Path); result.Path != "" && err == nil {
		result.Path = resolved
	}
	for _, tree := range after {
		if result.Path != "" && tree.Path == result.Path {
			return tree, !known[tree.Path], runErr
		}
	}
	// wt can fail after registration but before printing JSON. Recover only an
	// unambiguous addition; never guess among concurrent worktree creations.
	var added []Worktree
	for _, tree := range after {
		if !known[tree.Path] {
			added = append(added, tree)
		}
	}
	if len(added) == 1 {
		if runErr == nil {
			runErr = fmt.Errorf("wt result did not identify registered destination: %s", added[0].Path)
		}
		return added[0], true, runErr
	}
	if result.Path != "" {
		return Worktree{Path: result.Path, Branch: result.Branch}, false, errors.Join(runErr, fmt.Errorf("wt destination not registered: %s", result.Path))
	}
	return Worktree{}, false, runErr
}
