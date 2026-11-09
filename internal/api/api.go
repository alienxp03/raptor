// Package api serves the persistent, line-delimited JSON protocol for native clients.
package api

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/dispatch"
	"github.com/alienxp03/raptor/internal/paths"
	"github.com/alienxp03/raptor/internal/picker"
	"github.com/alienxp03/raptor/internal/pullrequest"
	"github.com/alienxp03/raptor/internal/rex"
	"github.com/alienxp03/raptor/internal/worktree"
)

// launcherDirWorkers bounds the concurrent per-host directory fetches.
const launcherDirWorkers = 4

// MaxRequestSize bounds one request, excluding its newline. Oversized lines are
// drained without growing memory, then the next request can be processed.
const MaxRequestSize = 1024 * 1024

type Handler struct {
	ctx rex.Ctx
	cfg config.Config

	activityAgents     []rex.AgentEntry
	activityAt         time.Time
	activityGeneration uint64
	cacheMu            sync.Mutex // protects snapshots, refresh state, and background context capture
	generation         uint64
	launcherGeneration uint64
	revalidating       bool
	launcher           launcherCacheEntry
	launcherLoaded     bool
	activityLoaded     bool
	refreshDone        chan struct{}
	snapshotChanged    chan struct{}
	refreshPending     bool
	refreshLauncher    bool
	presentation       uint64
	notify             func() error
	loadSnapshot       snapshotLoader // optional backend override; set before serving
	ranks              rex.SessionRecency
	loadRecency        func() rex.SessionRecency
	focus              *focusWorker
	validateFocus      func(context.Context, int) bool
	resolveFocus       func(context.Context, string) (string, bool)
	recordFocus        func(string, string, time.Time, bool) error
}

func New(ctx rex.Ctx, cfg config.Config) *Handler {
	return &Handler{ctx: ctx, cfg: cfg, snapshotChanged: make(chan struct{}), ranks: rex.LoadSessionRecency()}
}

const activitySnapshotTTL = 2 * time.Second

// Keep successful, unfiltered activity across view and context changes.
// Events refresh it in the background; warm requests only copy and filter.
func (h *Handler) activitySnapshot(fresh bool) ([]rex.AgentEntry, error) {
	return h.activitySnapshotContext(context.Background(), fresh)
}

func (h *Handler) activitySnapshotContext(ctx context.Context, fresh bool) ([]rex.AgentEntry, error) {
	h.cacheMu.Lock()
	if h.activityLoaded {
		entries := append([]rex.AgentEntry(nil), h.activityAgents...)
		h.cacheMu.Unlock()
		return entries, nil
	}
	h.cacheMu.Unlock()
	if err := h.refreshColdContext(ctx, false); err != nil {
		return nil, err
	}
	h.cacheMu.Lock()
	defer h.cacheMu.Unlock()
	return append([]rex.AgentEntry(nil), h.activityAgents...), nil
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

// Serve writes protocol responses and opt-in rex.changed notifications.
// Invalid envelopes use id 0 when their integer id cannot be read.
func (h *Handler) Serve(input io.Reader, output io.Writer) error {
	return h.ServeContext(context.Background(), input, output)
}

// ServeContext also cancels long-lived Rex children when the owner shuts down.
func (h *Handler) ServeContext(ctx context.Context, input io.Reader, output io.Writer) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	stopFocus := h.startFocusWorker(ctx)
	defer stopFocus()
	type inputLine struct {
		data      []byte
		oversized bool
		err       error
	}
	// A standard-input pipe can remain in a blocking read after SIGTERM.
	// Keep that read off the owner goroutine so it can reap its Rex children.
	lines := make(chan inputLine, 1)
	go func() {
		r := bufio.NewReader(input)
		for ctx.Err() == nil {
			line, oversized, err := readLine(r)
			select {
			case lines <- inputLine{line, oversized, err}:
			case <-ctx.Done():
				return
			}
			if err != nil {
				return
			}
		}
	}()
	encoder := json.NewEncoder(output)
	var outputMu sync.Mutex
	var outputErr error
	write := func(value any) error {
		outputMu.Lock()
		defer outputMu.Unlock()
		if outputErr == nil {
			outputErr = encoder.Encode(value)
		}
		return outputErr
	}
	var watcher *rex.EventWatcher
	var watchDone chan struct{}
	stop := func() {
		h.cacheMu.Lock()
		h.presentation++
		h.notify = nil
		h.refreshPending = false
		h.cacheMu.Unlock()
		if watcher != nil {
			watcher.Close()
			<-watchDone
			watcher = nil
		}
	}
	defer stop()
	for {
		var next inputLine
		select {
		case <-ctx.Done():
			return nil
		case next = <-lines:
		}
		if ctx.Err() != nil {
			return nil
		}
		line, oversized, err := next.data, next.oversized, next.err
		if err != nil && !errors.Is(err, io.EOF) {
			return err
		}
		if len(line) == 0 && !oversized && errors.Is(err, io.EOF) {
			stop()
			outputMu.Lock()
			defer outputMu.Unlock()
			return outputErr
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
			case req.Method == "events.subscribe":
				var p struct {
					Enabled bool `json:"enabled"`
				}
				if decodeErr := json.Unmarshal(req.Params, &p); decodeErr != nil {
					res.Error = decodeErr.Error()
				} else {
					stop()
					if p.Enabled {
						h.captureRecency(true)
						h.cacheMu.Lock()
						h.notify = func() error {
							return write(struct {
								Event string `json:"event"`
							}{"rex.changed"})
						}
						h.cacheMu.Unlock()
						watcher = rex.WatchEvents(ctx)
						watcher.Discover()
						watchDone = make(chan struct{})
						w, done := watcher, watchDone
						go func() {
							defer close(done)
							for {
								select {
								case _, ok := <-w.Changes:
									if !ok {
										return
									}
									h.requestLiveRefresh()
								case <-w.Done():
									return
								}
							}
						}()
					}
					res.Result = struct{}{}
				}
			default:
				result, callErr := h.callContext(ctx, req.Method, req.Params)
				if ctx.Err() != nil {
					return nil
				}
				if callErr != nil {
					res.Error = callErr.Error()
				} else {
					res.Result = result
				}
			}
		}
		if writeErr := write(res); writeErr != nil {
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
	Items   []catalog.LauncherItem `json:"items"`
	Hosts   []hostHeader           `json:"hosts"`
	Targets []string               `json:"targets"`
	Target  string                 `json:"target"`
}

// launcherCacheEntry is the on-disk stale-while-revalidate payload: the full
// unfiltered composition plus its host headers, stamped when fetched.
type launcherCacheEntry struct {
	Timestamp time.Time              `json:"timestamp"`
	Items     []catalog.LauncherItem `json:"items"`
	Hosts     []hostHeader           `json:"hosts"`
}

// launcherSoftTTL is sesh's stale-while-revalidate window: within it the
// cache answers instantly; past it the cache still answers instantly while a
// background fetch refreshes the file for the next open.
const launcherSoftTTL = 5 * time.Second

func (h *Handler) launcherCachePath() string {
	return filepath.Join(paths.CacheDir(), "launcher-cache.json")
}

func (h *Handler) readLauncherCache() (launcherCacheEntry, bool) {
	h.cacheMu.Lock()
	defer h.cacheMu.Unlock()
	if h.launcherLoaded {
		return h.launcher, true
	}
	data, err := os.ReadFile(h.launcherCachePath())
	if err != nil {
		return launcherCacheEntry{}, false
	}
	var entry launcherCacheEntry
	if json.Unmarshal(data, &entry) != nil || entry.Items == nil {
		return launcherCacheEntry{}, false
	}
	h.launcher, h.launcherLoaded = entry, true
	return entry, true
}

// writeLauncherCache replaces the cache atomically so a crashed write never
// leaves a truncated file behind.
func (h *Handler) writeLauncherCache(items []catalog.LauncherItem, hosts []hostHeader) {
	entry := launcherCacheEntry{Timestamp: time.Now(), Items: items, Hosts: hosts}
	data, err := json.Marshal(entry)
	if err != nil {
		return
	}
	path := h.launcherCachePath()
	if os.MkdirAll(filepath.Dir(path), 0o755) != nil {
		return
	}
	tmp := path + ".tmp"
	if os.WriteFile(tmp, data, 0o644) != nil {
		return
	}
	_ = os.Rename(tmp, path)
}

// hostHeader tells native clients which group headers to render, including
// unreachable hosts so their absence is explained rather than silent.
type hostHeader struct {
	Label     string `json:"label"`
	Local     bool   `json:"local,omitempty"`
	Reachable bool   `json:"reachable"`
	Error     string `json:"error,omitempty"`
}

// decodeSessionAction validates the shared {kind, session_id, window_id?, host?}
// envelope of the tab/session mutations. The empty host is the local server.
func decodeSessionAction(params json.RawMessage) (struct {
	Kind      string `json:"kind"`
	SessionID string `json:"session_id"`
	WindowID  string `json:"window_id"`
	Label     string `json:"label"`
	Host      string `json:"host"`
}, rex.SessionEntry, error) {
	var p struct {
		Kind      string `json:"kind"`
		SessionID string `json:"session_id"`
		WindowID  string `json:"window_id"`
		Label     string `json:"label"`
		Host      string `json:"host"`
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
	entry := rex.SessionEntry{Kind: p.Kind, ID: p.WindowID, SessionID: p.SessionID, Host: p.Host}
	if p.Kind == "session" {
		entry.ID = p.SessionID
	}
	return p, entry, nil
}

// fetchLauncher composes the full unfiltered launcher payload: sessions and
// directories per host in parallel, with activity folded in. This is the slow
// path — remote hosts answer over SSH within their own bounds.
func (h *Handler) fetchLauncher(localAgents []rex.AgentEntry) ([]catalog.LauncherItem, []hostHeader) {
	groups := rex.SessionGroups(h.ctx.Session, localAgents)
	hostOrder := []string{rex.LocalHostLabel}
	for _, group := range groups {
		if !group.Local {
			hostOrder = append(hostOrder, group.Label)
		}
	}
	pins := map[string]bool{}
	for _, pin := range config.LoadPins() {
		pins[paths.Canonical(pin)] = true
	}
	hostDirs := make(map[string][]catalog.Directory, len(hostOrder))
	var mu sync.Mutex
	var workers sync.WaitGroup
	jobs := make(chan string)
	for range min(launcherDirWorkers, len(hostOrder)) {
		workers.Go(func() {
			for host := range jobs {
				items := catalog.DirectoriesOn(host, false)
				agents := localAgents
				if host != rex.LocalHostLabel {
					agents, _ = rex.AgentEntriesOn(host, "")
				}
				catalog.ApplyDirectoryActivityOn(host, items, agents)
				if host == rex.LocalHostLabel {
					for i := range items {
						items[i].Pinned = pins[paths.Canonical(items[i].Path)]
					}
				}
				mu.Lock()
				hostDirs[host] = items
				mu.Unlock()
			}
		})
	}
	for _, host := range hostOrder {
		jobs <- host
	}
	close(jobs)
	workers.Wait()

	localDisplay := rex.LocalHostname()
	items := catalog.LauncherItems(groups, hostOrder, hostDirs, "", localAgents, localDisplay)
	hosts := make([]hostHeader, 0, len(groups))
	for _, group := range groups {
		label := group.Label
		if group.Local {
			label = localDisplay
		}
		hosts = append(hosts, hostHeader{Label: label, Local: group.Local, Reachable: group.Reachable, Error: group.Error})
	}
	return items, hosts
}

// revalidateLauncher refreshes the launcher cache in the background after a
// stale response went out.
func (h *Handler) revalidateLauncher() {
	h.requestRefresh()
}

func (h *Handler) call(method string, params json.RawMessage) (any, error) {
	return h.callContext(context.Background(), method, params)
}

func (h *Handler) callContext(ctx context.Context, method string, params json.RawMessage) (any, error) {
	// Decode each method separately: unrelated parameters must not change type
	// validation for the selected method.
	switch method {
	case "theme":
		return map[string]any{"theme": picker.ThemeJSON()}, nil
	case "sessions.visit":
		return h.observeFocus(params)
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
		h.cacheMu.Lock()
		h.ctx = rex.Ctx{Session: p.Session, Block: p.Block, Client: p.Client, Title: p.Title}
		h.presentation++
		if h.revalidating {
			h.refreshPending = true
			h.generation++
		}
		h.cacheMu.Unlock()
		h.captureRecency(true)
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
		h.patchLauncherPin(p.Path, pinned)
		return pinsResult{Pinned: pinned}, nil
	case "agents":
		var p struct {
			Query string `json:"query"`
		}
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, err
		}
		entries, err := h.activitySnapshotContext(ctx, true)
		if err != nil {
			return nil, err
		}
		for i := range entries {
			entries[i].Active = entries[i].SessionID == h.ctx.Session && (h.ctx.Block == "" || entries[i].BlockID == h.ctx.Block)
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
		h.cacheMu.Lock()
		wasLoaded := h.launcherLoaded
		h.cacheMu.Unlock()
		cached, ok := h.readLauncherCache()
		if !ok {
			if err := h.refreshColdContext(ctx, true); err != nil {
				return nil, err
			}
			cached, _ = h.readLauncherCache()
		} else if !wasLoaded {
			// Disk rows are immediately usable. Refresh once, not per query.
			h.revalidateLauncher()
		}
		items := append([]catalog.LauncherItem{}, cached.Items...)
		h.cacheMu.Lock()
		origin, ranks := h.ctx.Session, h.ranks
		h.cacheMu.Unlock()
		for i := range items {
			items[i].Active = items[i].Local && items[i].SessionID == origin
		}
		catalog.OrderLauncherSessionsByRecency(items, ranks)
		// Full IDs were compared above. An empty origin prevents catalog's
		// reference resolver from making native calls for each candidate.
		items = catalog.PinLauncherOrigin(items, "")
		items = catalog.FilterLauncherItems(items, p.Query, "")
		return sessionsResult{Items: items, Hosts: cached.Hosts, Targets: h.targets(), Target: "session"}, nil
	case "sessions.jump":
		_, entry, err := decodeSessionAction(params)
		if err != nil {
			return nil, err
		}
		entry.Host = rex.NormalizeHost(entry.Host)
		if err := rex.JumpOnHost(entry.Host, entry, h.ctx.Client); err != nil {
			return nil, err
		}
		return struct{}{}, nil
	case "sessions.create":
		var p struct {
			Host string `json:"host"`
			Dir  string `json:"dir"`
		}
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, err
		}
		if p.Dir == "" {
			return nil, fmt.Errorf("dir is required")
		}
		p.Host = rex.NormalizeHost(p.Host)
		sid, existing, err := rex.CreateSessionOn(p.Host, p.Dir)
		if err != nil {
			return nil, err
		}
		if err := rex.SelectOnHost(p.Host, sid, h.ctx.Client); err != nil {
			return nil, fmt.Errorf("created %s on %s, but could not switch to it: %w", sid, rex.LocalHostLabelOr(p.Host), err)
		}
		return map[string]any{"session_id": sid, "existing": existing}, nil
	case "sessions.close":
		_, entry, err := decodeSessionAction(params)
		if err != nil {
			return nil, err
		}
		if entry.Kind == "session" && (entry.Host == "" || entry.Host == rex.LocalHostLabel) && entry.SessionID == h.ctx.Session {
			return nil, fmt.Errorf("refusing to close the session this picker opened from")
		}
		entry.Host = rex.NormalizeHost(entry.Host)
		if entry.Kind == "session" {
			err = rex.CloseSession(entry.Host, entry.SessionID)
		} else {
			err = rex.CloseWindow(entry.Host, entry.SessionID, entry.ID)
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
		entry.Host = rex.NormalizeHost(entry.Host)
		if entry.Kind == "session" {
			err = rex.SetSessionLabel(entry.Host, entry.SessionID, p.Label)
		} else {
			err = rex.SetWindowLabel(entry.Host, entry.SessionID, entry.ID, p.Label)
		}
		if err != nil {
			return nil, err
		}
		return struct{}{}, nil
	case "directories":
		var p struct {
			Query     string `json:"query"`
			ReposOnly bool   `json:"repos_only"`
			Host      string `json:"host"`
		}
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, err
		}
		items := catalog.DirectoriesOn(p.Host, p.ReposOnly)
		if agents, err := h.activitySnapshotContext(ctx, false); err == nil {
			catalog.ApplyDirectoryActivity(items, agents)
		}
		result := directoryResult{Items: []catalog.Directory{}, Targets: h.targets(), Target: h.cfg.Enter}
		for _, i := range catalog.FilterDirectories(items, p.Query) {
			result.Items = append(result.Items, items[i])
		}
		result.Items = catalog.ApplyPins(result.Items)
		return result, nil
	case "pullrequests.resolve", "pullrequests.prepare", "pullrequests.open":
		return h.pullRequest(method, params)
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
		setup, err := pullrequest.PreflightLocal(repo)
		if err != nil {
			return nil, err
		}
		before := map[string]bool{}
		for _, tree := range worktree.List(repo) {
			before[canonicalPath(tree.Path)] = true
		}
		createErr := worktree.CreateLocal(repo, p.Branch, p.Base, path)
		// Use the registered resource, including a switch which failed after
		// creation. Never attach creation setup to a pre-existing worktree.
		for _, tree := range worktree.List(repo) {
			if tree.Branch == p.Branch && !before[canonicalPath(tree.Path)] {
				if canonicalPath(path) != canonicalPath(tree.Path) {
					path = tree.Path
				}
				if err := setup.Register(tree.Path, tree.Branch, p.Base); err != nil {
					return pathResult{Path: path}, fmt.Errorf("worktree preserved at %s; creation error: %v; could not register setup: %w", path, createErr, err)
				}
				if createErr != nil {
					return pathResult{Path: path}, fmt.Errorf("worktree preserved at %s: %w", path, createErr)
				}
				return pathResult{Path: path}, nil
			}
		}
		if createErr != nil {
			return nil, createErr
		}
		return nil, fmt.Errorf("creation returned without a new registered worktree; inspect %s", path)
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
