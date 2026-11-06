// Package api serves the persistent, line-delimited JSON protocol for native clients.
package api

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"time"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/dispatch"
	"github.com/alienxp03/raptor/internal/picker"
	"github.com/alienxp03/raptor/internal/rex"
	"github.com/alienxp03/raptor/internal/worktree"
)

// MaxRequestSize bounds one request, excluding its newline. Oversized lines are
// drained without growing memory, then the next request can be processed.
const MaxRequestSize = 1024 * 1024

type Handler struct {
	ctx rex.Ctx
	cfg config.Config

	activityAgents []rex.AgentEntry
	activityAt     time.Time
}

func New(ctx rex.Ctx, cfg config.Config) *Handler { return &Handler{ctx: ctx, cfg: cfg} }

const activitySnapshotTTL = 2 * time.Second

// Serve dispatches requests serially. Keep one successful snapshot across view
// and context changes. Failures are not cached; the next request can retry.
// Fresh agent requests also refresh activity, but never reuse origin Active flags.
func (h *Handler) activitySnapshot(fresh bool) ([]rex.AgentEntry, error) {
	if !fresh && !h.activityAt.IsZero() && time.Since(h.activityAt) < activitySnapshotTTL {
		return h.activityAgents, nil
	}
	entries, err := rex.AgentEntries(h.ctx.Session)
	if err != nil {
		return nil, err
	}
	h.activityAgents, h.activityAt = entries, time.Now()
	return entries, nil
}

type request struct {
	ID     *int64          `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

type response struct {
	ID     int64  `json:"id"`
	Result any    `json:"result,omitempty"`
	Error  string `json:"error,omitempty"`
}

// Serve writes only protocol responses. Invalid envelopes use id 0 when their
// integer id cannot be read. Input/output failures terminate the stream.
func (h *Handler) Serve(input io.Reader, output io.Writer) error {
	r := bufio.NewReader(input)
	encoder := json.NewEncoder(output)
	for {
		line, oversized, err := readLine(r)
		if err != nil && !errors.Is(err, io.EOF) {
			return err
		}
		if len(line) == 0 && !oversized && errors.Is(err, io.EOF) {
			return nil
		}
		res := response{}
		if oversized {
			res.Error = "request exceeds maximum size"
		} else {
			var req request
			decodeErr := json.Unmarshal(line, &req)
			if req.ID != nil {
				res.ID = *req.ID
			}
			switch {
			case decodeErr != nil:
				res.Error = "invalid request: " + decodeErr.Error()
			case req.ID == nil || req.Method == "":
				res.Error = "request requires integer id and method"
			case len(bytes.TrimSpace(req.Params)) == 0 || bytes.TrimSpace(req.Params)[0] != '{':
				res.Error = "params must be an object"
			default:
				result, callErr := h.call(req.Method, req.Params)
				if callErr != nil {
					res.Error = callErr.Error()
				} else {
					res.Result = result
				}
			}
		}
		if writeErr := encoder.Encode(res); writeErr != nil {
			return writeErr
		}
		if errors.Is(err, io.EOF) {
			return nil
		}
	}
}

func readLine(r *bufio.Reader) ([]byte, bool, error) {
	var line []byte
	oversized := false
	for {
		part, err := r.ReadSlice('\n')
		if len(part) > 0 && part[len(part)-1] == '\n' {
			part = part[:len(part)-1]
		}
		if !oversized {
			if len(line)+len(part) > MaxRequestSize {
				oversized, line = true, nil
			} else {
				line = append(line, part...)
			}
		}
		if !errors.Is(err, bufio.ErrBufferFull) {
			return line, oversized, err
		}
	}
}

type directoryResult struct {
	Items   []catalog.Directory `json:"items"`
	Targets []string            `json:"targets"`
	Target  string              `json:"target"`
}

type treeItem struct {
	Path   string `json:"path"`
	Branch string `json:"branch"`
	IsMain bool   `json:"is_main"`
}

type treeResult struct {
	DestinationRoot string     `json:"destination_root"`
	Repo            string     `json:"repo"`
	NeedsRepo       bool       `json:"needs_repo"`
	Items           []treeItem `json:"items"`
	Branches        []string   `json:"branches"`
	BaseBranch      string     `json:"base_branch"`
	SuggestedBranch string     `json:"suggested_branch,omitempty"`
	Targets         []string   `json:"targets"`
	Target          string     `json:"target"`
}

type branchesResult struct {
	Branches []string `json:"branches"`
}

type previewResult struct {
	Path            string `json:"path"`
	ValidationError string `json:"validation_error"`
}

type pathResult struct {
	Path string `json:"path"`
}

type pinsResult struct {
	Pinned bool `json:"pinned"`
}

type agentsResult struct {
	Items   []rex.AgentEntry `json:"items"`
	Targets []string         `json:"targets"`
	Target  string           `json:"target"`
}

type sessionsResult struct {
	Items   []rex.SessionEntry `json:"items"`
	Targets []string           `json:"targets"`
	Target  string             `json:"target"`
}

// decodeSessionAction validates the shared {kind, session_id, window_id?}
// envelope of the tab/session mutations.
func decodeSessionAction(params json.RawMessage) (struct {
	Kind      string `json:"kind"`
	SessionID string `json:"session_id"`
	WindowID  string `json:"window_id"`
	Label     string `json:"label"`
}, rex.SessionEntry, error) {
	var p struct {
		Kind      string `json:"kind"`
		SessionID string `json:"session_id"`
		WindowID  string `json:"window_id"`
		Label     string `json:"label"`
	}
	if err := json.Unmarshal(params, &p); err != nil {
		return p, rex.SessionEntry{}, err
	}
	if p.Kind != "session" && p.Kind != "window" {
		return p, rex.SessionEntry{}, fmt.Errorf("kind must be session or window")
	}
	if p.SessionID == "" {
		return p, rex.SessionEntry{}, fmt.Errorf("session_id is required")
	}
	if p.Kind == "window" && p.WindowID == "" {
		return p, rex.SessionEntry{}, fmt.Errorf("window_id is required for a window")
	}
	entry := rex.SessionEntry{Kind: p.Kind, ID: p.WindowID, SessionID: p.SessionID}
	if p.Kind == "session" {
		entry.ID = p.SessionID
	}
	return p, entry, nil
}

func (h *Handler) call(method string, params json.RawMessage) (any, error) {
	// Decode each method separately: unrelated parameters must not change type
	// validation for the selected method.
	switch method {
	case "theme":
		return map[string]any{"theme": picker.ThemeJSON()}, nil
	case "context":
		// The resident backend is shared across opens; every open sends its
		// origin context here instead of spawning a new process.
		var p struct {
			Session string `json:"session"`
			Block   string `json:"block"`
			Client  string `json:"client"`
			Title   string `json:"title"`
		}
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, err
		}
		h.ctx = rex.Ctx{Session: p.Session, Block: p.Block, Client: p.Client, Title: p.Title}
		return struct{}{}, nil
	case "pins.toggle":
		var p struct {
			Path string `json:"path"`
		}
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, err
		}
		if p.Path == "" {
			return nil, fmt.Errorf("path is required")
		}
		pinned, err := config.TogglePin(p.Path)
		if err != nil {
			return nil, err
		}
		return pinsResult{Pinned: pinned}, nil
	case "agents":
		var p struct {
			Query string `json:"query"`
		}
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, err
		}
		entries, err := h.activitySnapshot(true)
		if err != nil {
			return nil, err
		}
		result := agentsResult{Items: []rex.AgentEntry{}, Targets: []string{}, Target: h.cfg.Enter}
		for _, i := range catalog.FilterAgents(entries, p.Query) {
			result.Items = append(result.Items, entries[i])
		}
		return result, nil
	case "agents.jump":
		var p struct {
			SessionID string `json:"session_id"`
			WindowID  string `json:"window_id"`
			BlockID   string `json:"block_id"`
		}
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, err
		}
		if err := rex.JumpAgent(rex.AgentEntry{SessionID: p.SessionID, WindowID: p.WindowID, BlockID: p.BlockID}, h.ctx.Client); err != nil {
			return nil, err
		}
		return struct{}{}, nil
	case "sessions":
		var p struct {
			Query string `json:"query"`
		}
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, err
		}
		entries, err := rex.SessionEntries(h.ctx.Session)
		if err != nil {
			return nil, err
		}
		if agents, err := h.activitySnapshot(false); err == nil {
			rex.ApplySessionActivity(entries, agents)
		}
		result := sessionsResult{Items: []rex.SessionEntry{}, Targets: []string{}, Target: h.cfg.Enter}
		for _, i := range catalog.FilterSessions(entries, p.Query) {
			result.Items = append(result.Items, entries[i])
		}
		return result, nil
	case "sessions.jump":
		_, entry, err := decodeSessionAction(params)
		if err != nil {
			return nil, err
		}
		if err := rex.Jump(entry, h.ctx.Client); err != nil {
			return nil, err
		}
		return struct{}{}, nil
	case "sessions.close":
		_, entry, err := decodeSessionAction(params)
		if err != nil {
			return nil, err
		}
		if entry.Kind == "session" && entry.SessionID == h.ctx.Session {
			return nil, fmt.Errorf("refusing to close the session this picker opened from")
		}
		if entry.Kind == "session" {
			err = rex.CloseSession(entry.SessionID)
		} else {
			err = rex.CloseWindow(entry.SessionID, entry.ID)
		}
		if err != nil {
			return nil, err
		}
		return struct{}{}, nil
	case "sessions.rename":
		p, entry, err := decodeSessionAction(params)
		if err != nil {
			return nil, err
		}
		if p.Label == "" {
			return nil, fmt.Errorf("label is required")
		}
		if entry.Kind == "session" {
			err = rex.SetSessionLabel(entry.SessionID, p.Label)
		} else {
			err = rex.SetWindowLabel(entry.SessionID, entry.ID, p.Label)
		}
		if err != nil {
			return nil, err
		}
		return struct{}{}, nil
	case "directories":
		var p struct {
			Query     string `json:"query"`
			ReposOnly bool   `json:"repos_only"`
		}
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, err
		}
		items := catalog.Directories(p.ReposOnly)
		if agents, err := h.activitySnapshot(false); err == nil {
			catalog.ApplyDirectoryActivity(items, agents)
		}
		result := directoryResult{Items: []catalog.Directory{}, Targets: h.targets(), Target: h.cfg.Enter}
		for _, i := range catalog.FilterDirectories(items, p.Query) {
			result.Items = append(result.Items, items[i])
		}
		result.Items = catalog.ApplyPins(result.Items)
		return result, nil
	case "worktrees.list":
		var p struct {
			Repo  string `json:"repo"`
			Query string `json:"query"`
		}
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, err
		}
		repo, err := catalog.ResolveRepo(h.ctx, p.Repo)
		if err != nil {
			return nil, err
		}
		result := treeResult{Repo: repo, NeedsRepo: repo == "", Items: []treeItem{}, Branches: []string{}, Targets: h.targets(), Target: h.cfg.Enter}
		if repo != "" {
			info := catalog.ListWorktrees(repo, h.cfg)
			result.DestinationRoot = info.Root
			result.Branches = append(result.Branches, info.Branches...)
			result.BaseBranch = info.BaseBranch
			result.SuggestedBranch = info.SuggestedBranch
			for _, i := range catalog.FilterWorktrees(info.Items, p.Query) {
				w := info.Items[i]
				result.Items = append(result.Items, treeItem{w.Path, w.Branch, w.IsMain})
			}
		}
		return result, nil
	case "worktrees.branches":
		var p struct {
			Repo  string `json:"repo"`
			Query string `json:"query"`
		}
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, err
		}
		repo, err := catalog.ResolveRepo(h.ctx, p.Repo)
		if err != nil {
			return nil, err
		}
		if repo == "" {
			return nil, fmt.Errorf("choose a repository")
		}
		return branchesResult{Branches: catalog.FilterBranches(worktree.LocalBranches(repo), p.Query)}, nil
	case "worktrees.preview", "worktrees.create", "worktrees.remove":
		var p struct {
			Repo   string `json:"repo"`
			Branch string `json:"branch"`
			Base   string `json:"base"`
			Path   string `json:"path"`
		}
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, err
		}
		repo, err := catalog.ResolveRepo(h.ctx, p.Repo)
		if err != nil {
			return nil, err
		}
		if repo == "" {
			return nil, fmt.Errorf("choose a repository")
		}
		if method == "worktrees.remove" {
			if p.Path != "" {
				for _, w := range worktree.List(repo) {
					if canonicalPath(w.Path) == canonicalPath(p.Path) {
						if err := worktree.Remove(repo, w); err != nil {
							return nil, err
						}
						return struct{}{}, nil
					}
				}
			}
			return nil, fmt.Errorf("unknown worktree: %s", p.Path)
		}
		path := worktree.Path(repo, p.Branch, h.cfg)
		if method == "worktrees.preview" {
			result := previewResult{Path: path}
			if err := worktree.Validate(repo, p.Branch, p.Base, path); err != nil {
				result.ValidationError = err.Error()
			}
			return result, nil
		}
		if err := worktree.CreateLocal(repo, p.Branch, p.Base, path); err != nil {
			return nil, err
		}
		return pathResult{Path: path}, nil
	case "dispatch":
		var p struct {
			Target string `json:"target"`
			Path   string `json:"path"`
		}
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, err
		}
		if p.Path == "" {
			return nil, fmt.Errorf("path is required")
		}
		if err := dispatch.Dispatch(p.Target, p.Path, h.ctx, h.cfg); err != nil {
			return nil, err
		}
		return struct{}{}, nil
	default:
		return nil, fmt.Errorf("unknown method %q", method)
	}
}

func (h *Handler) targets() []string {
	return h.cfg.AvailableTargets(h.ctx.Block != "")
}

func canonicalPath(path string) string {
	if real, err := filepath.EvalSymlinks(path); err == nil {
		path = real
	}
	absolute, err := filepath.Abs(path)
	if err != nil {
		return filepath.Clean(path)
	}
	return absolute
}
