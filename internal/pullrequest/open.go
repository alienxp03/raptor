package pullrequest

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/alienxp03/raptor/internal/rex"
)

type OpenResult struct {
	Path      string `json:"path"`
	SessionID string `json:"session_id,omitempty"`
	WindowID  string `json:"window_id,omitempty"`
	BlockID   string `json:"block_id,omitempty"`
	Error     string `json:"error,omitempty"`
}

func quote(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'" }

func setupWrapper(executable, path string) string {
	return `trap ':' INT; ` + quote(executable) + " setup --path " + quote(path) + `; exec "${SHELL:-/bin/sh}" -l`
}

// destinationLabel is presentation only: Worktrunk still owns branch names and
// worktree paths. Durable Rex IDs, not this label, identify an existing open.
func destinationLabel(s setupState) string {
	if id, number, err := parse(s.URL, ""); err == nil {
		_, repo, _ := strings.Cut(id, "/")
		return repo + "-pr-" + number + "-" + strings.ReplaceAll(s.Branch, "/", "-")
	}
	return filepath.Base(s.Path)
}

// Open accepts only session or tab. Selection is queued, not visual confirmation.
// A failed create is reconciled by canonical cwd; labels are never identities.
func Open(path, target string, ctx rex.Ctx) (result OpenResult, err error) {
	result.Path = path
	defer func() {
		if err != nil {
			result.Error = err.Error()
		}
	}()
	path, err = canonical(path)
	if err != nil {
		return result, err
	}
	result.Path = path
	if prior, readErr := load(path); readErr == nil && validState(path, prior) && prior.Result.SessionID != "" {
		result = prior.Result
		result.Path, result.Error = path, ""
	}
	if target != "session" && target != "tab" {
		return result, fmt.Errorf("PR setup requires session or tab")
	}
	if target == "tab" && ctx.Session == "" {
		return result, fmt.Errorf("tab requires a session ID")
	}
	if ctx.Client == "" {
		return result, fmt.Errorf("a Rex client ID is required for selection")
	}
	unlock, err := lock(path, false)
	if err != nil {
		return result, err
	}
	defer unlock()
	s, err := load(path)
	if err != nil {
		return result, err
	}
	if !validState(path, s) {
		return result, fmt.Errorf("no PR setup state for %s; call Prepare first", path)
	}
	result = s.Result
	result.Path, result.Error = path, ""
	if s.Target != "" && s.Target != target {
		return result, fmt.Errorf("destination already prepared as %s; retry that target", s.Target)
	}
	if s.Opening && (result.SessionID == "" || result.WindowID == "" || result.BlockID == "") {
		reconciled, reconcileErr := reconcile(path)
		err = reconcileErr
		if err != nil {
			if !s.RetryCreate || !errors.Is(err, errNoDestinations) {
				return result, err
			}
			// Only a completed, explicit failure plus a full zero-match scan
			// permits another create. Timeouts/lost responses remain blocked.
			s.Opening, s.RetryCreate = false, false
			err = nil
		}
		result = reconciled
		s.Result = result
		if err = save(path, s); err != nil {
			return result, err
		}
	}
	if result.SessionID == "" {
		executable, err := os.Executable()
		if err != nil {
			return result, err
		}
		// Setup is a child command. Even a failure returns to a fresh usable login shell.
		wrapper := setupWrapper(executable, path)
		label := destinationLabel(s)
		args := []string{"new", label, "-c", path, "--json"}
		if target == "tab" {
			args = []string{"window", "new", "-s", ctx.Session, label, "-c", path, "--json"}
		}
		args = append(args, "--", "/bin/sh", "-c", wrapper)
		s.Opening, s.Target, s.RetryCreate = true, target, false
		if err = save(path, s); err != nil {
			return result, err
		}
		createCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		out, createErr := commandContext(createCtx, "", "rex", args...)
		var exitErr *exec.ExitError
		definite := errors.As(createErr, &exitErr) && createCtx.Err() == nil && exitErr.Exited() && !uncertainTransport(createErr)
		// An executable that could not start also cannot create resources.
		var startErr *exec.Error
		definite = definite || errors.As(createErr, &startErr)
		cancel()
		var created struct {
			Error     json.RawMessage `json:"error"`
			SessionID string          `json:"session_id"`
			WindowID  string          `json:"window_id"`
			BlockIDs  []string        `json:"block_ids"`
			Initial   []struct {
				WindowID string   `json:"window_id"`
				BlockIDs []string `json:"block_ids"`
			} `json:"initial_windows"`
		}
		parseErr := json.Unmarshal([]byte(out), &created)
		result.SessionID, result.WindowID = created.SessionID, created.WindowID
		if target == "tab" {
			result.SessionID = ctx.Session
		}
		if len(created.Initial) > 0 {
			result.WindowID, created.BlockIDs = created.Initial[0].WindowID, created.Initial[0].BlockIDs
		}
		if len(created.BlockIDs) > 0 {
			result.BlockID = created.BlockIDs[0]
		}
		// Publish a successful new session before journal/selection failures can
		// hide it. Never infer a session from a label or a failed create.
		if target == "session" && createErr == nil && parseErr == nil && len(created.Error) == 0 && result.SessionID != "" {
			rex.RecordLauncherCreation("", result.SessionID, label, path)
		}
		// Keep every returned ID, even when Rex reports an error.
		s.Result = result
		// Truncated/unrecognized responses are not explicit failures, even if
		// the CLI exits nonzero. A transport error can also exit normally.
		explicitFailure := strings.TrimSpace(out) == "" || parseErr == nil && len(created.Error) > 0 && string(created.Error) != "null"
		s.RetryCreate = definite && explicitFailure && created.SessionID == "" && result.WindowID == "" && result.BlockID == ""
		if err = save(path, s); err != nil {
			return result, err
		}
		if createErr != nil {
			if s.RetryCreate {
				return result, fmt.Errorf("Rex create failed; retry Open for authoritative reconciliation before another create: %w", createErr)
			}
			return result, fmt.Errorf("Rex create uncertain; retry Open to reconcile: %w", createErr)
		}
		if parseErr != nil || result.SessionID == "" || result.WindowID == "" || result.BlockID == "" {
			return result, fmt.Errorf("Rex returned incomplete IDs; retry Open to reconcile")
		}
	}
	// Verify IDs and cwd before selecting. Never replace a missing destination silently.
	if err = verifyDestination(result); err != nil {
		return result, err
	}
	if err = rex.Do(ctx.Client, "session.select", "session_id="+result.SessionID, "window_id="+result.WindowID); err != nil {
		return result, err
	}
	if result.SessionID != ctx.Session {
		_ = rex.RecordSessionUse("", ctx.Session)
	}
	_ = rex.RecordSessionUse("", result.SessionID)
	s.Result, s.Released = result, true
	if err = save(path, s); err != nil {
		return result, err
	}
	return result, nil
}

func uncertainTransport(err error) bool {
	if err == nil {
		return false
	}
	message := strings.ToLower(err.Error())
	for _, marker := range []string{"timeout", "timed out", "deadline", "eof", "connection", "socket", "transport", "broken pipe", "response", "respond", "network", "cancel", "interrupt"} {
		if strings.Contains(message, marker) {
			return true
		}
	}
	return false
}

func verifyDestination(result OpenResult) error {
	if result.SessionID == "" || result.BlockID == "" || result.WindowID == "" {
		return fmt.Errorf("incomplete destination IDs; inspect preserved Rex resources")
	}
	out, err := rex.Run("session", "inspect", result.SessionID, "--json")
	if err != nil {
		return fmt.Errorf("preserved destination unavailable: %w", err)
	}
	var view struct {
		Windows []struct {
			WindowID string `json:"window_id"`
		} `json:"windows"`
	}
	if err = json.Unmarshal([]byte(out), &view); err != nil {
		return err
	}
	found := false
	for _, window := range view.Windows {
		if window.WindowID == result.WindowID {
			found = true
		}
	}
	cwd, err := canonical(rex.BlockCwdInSession(result.SessionID, result.BlockID))
	if !found || err != nil || cwd != result.Path {
		return fmt.Errorf("destination IDs no longer match %s; resources preserved", result.Path)
	}
	return nil
}

var errNoDestinations = errors.New("authoritative reconciliation found zero destinations")

func reconcile(path string) (OpenResult, error) {
	result := OpenResult{Path: path}
	out, err := rex.Run("ls", "--json")
	if err != nil {
		return result, err
	}
	var list struct {
		Sessions *[]struct {
			ID string `json:"session_id"`
		} `json:"sessions"`
	}
	if err := json.Unmarshal([]byte(out), &list); err != nil {
		return result, err
	}
	if list.Sessions == nil {
		return result, fmt.Errorf("incomplete Rex session listing")
	}
	matches := 0
	for _, session := range *list.Sessions {
		out, err := rex.Run("session", "inspect", session.ID, "--json")
		if err != nil {
			return result, fmt.Errorf("cannot reconcile session %s: %w", session.ID, err)
		}
		var view struct {
			Windows *[]struct {
				ID     string `json:"window_id"`
				Block  string `json:"focused_block_id"`
				Blocks []struct {
					ID string `json:"block_id"`
				} `json:"blocks"`
			} `json:"windows"`
		}
		if err := json.Unmarshal([]byte(out), &view); err != nil {
			return result, err
		}
		if view.Windows == nil {
			return result, fmt.Errorf("incomplete Rex window listing")
		}
		for _, window := range *view.Windows {
			if len(window.Blocks) == 0 {
				return result, fmt.Errorf("incomplete Rex block listing")
			}
			for _, block := range window.Blocks {
				cwd := rex.BlockCwdInSession(session.ID, block.ID)
				p, err := canonical(cwd)
				if err != nil {
					return result, fmt.Errorf("cannot reconcile block %s cwd", block.ID)
				}
				if p == path {
					matches++
					result = OpenResult{Path: path, SessionID: session.ID, WindowID: window.ID, BlockID: block.ID}
				}
			}
		}
	}
	if matches == 0 {
		return result, errNoDestinations
	}
	if matches != 1 {
		return OpenResult{Path: path}, fmt.Errorf("uncertain Rex creation: found %d destinations at %s; inspect preserved resources before retry", matches, path)
	}
	return result, nil
}
