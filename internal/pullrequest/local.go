package pullrequest

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/alienxp03/raptor/internal/rex"
	"github.com/alienxp03/raptor/internal/worktree"
)

// LocalCreation captures hook context before a caller creates a worktree with
// --no-hooks. Register must be called only for an actually new worktree.
type LocalCreation struct {
	source, config string
	hooks          bool
}

// PreflightLocal refuses true pre-switch hooks before mutation: there is no safe
// interactive terminal yet. Deferred creation hooks must not bypass approval.
func PreflightLocal(source string) (*LocalCreation, error) {
	source, err := canonical(source)
	if err != nil {
		return nil, err
	}
	if err := checkPreSwitch(source); err != nil {
		return nil, err
	}
	p := &LocalCreation{source: source}
	for _, phase := range []string{"pre-start", "post-start", "post-switch"} {
		out, err := command(source, "wt", "hook", "show", phase, "--format=json")
		if err != nil {
			return nil, fmt.Errorf("inspect %s hooks: %w", phase, err)
		}
		var hooks []json.RawMessage
		if err := json.Unmarshal([]byte(out), &hooks); err != nil {
			return nil, fmt.Errorf("inspect %s hooks: %w", phase, err)
		}
		if hooks == nil {
			return nil, fmt.Errorf("inspect %s hooks: expected a JSON array", phase)
		}
		p.hooks = p.hooks || len(hooks) > 0
	}
	if p.hooks {
		p.config, err = configStamp(source)
		if err != nil {
			return nil, err
		}
	}
	return p, nil
}

// Register records only configured creation setup, never an existing worktree.
// base is the explicit creation base; empty uses the created worktree's commit,
// matching instant-task creation's --base commit argument without a HEAD race.
func (p *LocalCreation) Register(path, branch, base string) error {
	if p == nil || !p.hooks {
		return nil
	}
	path, err := canonical(path)
	if err != nil {
		return err
	}
	unlock, err := lock(path, false)
	if err != nil {
		return err
	}
	defer unlock()
	old, err := load(path)
	if err != nil {
		return err
	}
	if validState(path, old) {
		return nil
	}
	id, err := instance(path)
	if err != nil {
		return err
	}
	if base == "" {
		base, err = command(path, "git", "rev-parse", "--verify", "HEAD^{commit}")
		if err != nil {
			return err
		}
	}
	var basePath string
	for _, tree := range worktree.List(p.source) {
		if tree.Branch == base {
			basePath = tree.Path
			break
		}
	}
	return save(path, setupState{Instance: id, Config: p.config, Path: path,
		Source: p.source, Branch: branch, Base: base, BasePath: basePath, New: true})
}

// LocalPending reports durable setup, including failed or unreleased setup.
// A stale journal is an error, not permission to skip setup silently.
func LocalPending(path string) (bool, error) {
	// Ordinary dispatch also accepts paths which Rex will resolve/create. Do
	// not change that contract when no setup journal exists.
	path = prospectivePath(path)
	unlock, err := lock(path, false)
	if err != nil {
		return false, err
	}
	defer unlock()
	s, err := load(path)
	if err != nil {
		return false, err
	}
	if s.Path == "" || s.Complete {
		// Finished setup must not block ordinary navigation after a manual
		// branch change or replacement. Prepare/Register validate new instances.
		return false, nil
	}
	if !validState(path, s) {
		return false, fmt.Errorf("setup journal does not match this worktree instance: %s; inspect preserved worktree", path)
	}
	return !s.Complete, nil
}

// LocalStartup claims one NEW terminal runner. after runs only after successful
// Setup (for example Pi); any failure leaves a usable login shell. Never send
// this command to an existing terminal. Open owns session/tab recovery instead.
func LocalStartup(path, target string, after ...string) ([]string, error) {
	path, err := canonical(path)
	if err != nil {
		return nil, err
	}
	exe, err := os.Executable()
	if err != nil {
		return nil, err
	}
	unlock, err := lock(path, false)
	if err != nil {
		return nil, err
	}
	defer unlock()
	s, err := load(path)
	if err != nil {
		return nil, err
	}
	if !validState(path, s) {
		return nil, fmt.Errorf("no valid local setup journal: %s", path)
	}
	if s.Opening || s.Result.SessionID != "" {
		return nil, fmt.Errorf("worktree preserved at %s; setup destination already requested (%s, session %s, tab %s, pane %s); inspect/select that destination, then run raptor setup --path %s --retry", path, s.Target, s.Result.SessionID, s.Result.WindowID, s.Result.BlockID, quote(path))
	}
	wrapper := `trap ':' INT; ` + quote(exe) + " setup --path " + quote(path)
	if len(after) > 0 {
		parts := make([]string, len(after))
		for i, arg := range after {
			parts[i] = quote(arg)
		}
		wrapper += " && { " + strings.Join(parts, " ") + "; exit $?; }"
	}
	wrapper += `; exec "${SHELL:-/bin/sh}" -l`
	s.Opening, s.Target = true, target
	if err := save(path, s); err != nil {
		return nil, err
	}
	return []string{"/bin/sh", "-c", wrapper}, nil
}

// ResumeLocal selects a previously requested generic destination without
// starting another runner. Unknown create results require manual inspection.
func ResumeLocal(path, target string, ctx rex.Ctx) (OpenResult, bool, error) {
	path, err := canonical(path)
	if err != nil {
		return OpenResult{}, false, err
	}
	unlock, err := lock(path, false)
	if err != nil {
		return OpenResult{}, false, err
	}
	defer unlock()
	s, err := load(path)
	if err != nil {
		return OpenResult{}, false, err
	}
	if !validState(path, s) {
		return OpenResult{}, false, fmt.Errorf("invalid setup journal: %s", path)
	}
	if !s.Opening {
		return OpenResult{}, false, nil
	}
	result := s.Result
	if s.Target != target {
		return result, true, fmt.Errorf("worktree preserved at %s; retry original %s destination", path, s.Target)
	}
	if err := verifyDestination(result); err != nil {
		return result, true, fmt.Errorf("worktree preserved at %s; inspect existing setup destination: %w", path, err)
	}
	if ctx.Client != "" {
		err = rex.Do(ctx.Client, "session.select", "session_id="+result.SessionID, "window_id="+result.WindowID)
	} else {
		_, err = rex.Run("focus", "-s", result.SessionID, result.BlockID)
	}
	if err != nil {
		return result, true, err
	}
	s.Released = true
	return result, true, save(path, s)
}

// LocalDestination saves IDs even on selection failure. released must be true
// only after the Rex selection request succeeds (not proof of visual focus).
func LocalDestination(path string, result OpenResult, released bool) error {
	path, err := canonical(path)
	if err != nil {
		return err
	}
	unlock, err := lock(path, false)
	if err != nil {
		return err
	}
	defer unlock()
	s, err := load(path)
	if err != nil {
		return err
	}
	if !validState(path, s) {
		return fmt.Errorf("worktree instance changed: %s", path)
	}
	result.Path = path
	s.Result, s.Released = result, released
	return save(path, s)
}
