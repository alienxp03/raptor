package rex

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/alienxp03/raptor/internal/paths"
)

// SessionEntry describes one selectable row in the Sessions view.
// Kind "session" jumps to a session; kind "window" jumps to one of its tabs.
// SessionID links each tab to its parent session row. Path mirrors ID so native
// clients can reuse their item decode shape. Host carries the display label of
// the server that owns the row ("This Mac" locally).
type SessionEntry struct {
	Kind         string `json:"kind"` // "session" | "window"
	ID           string `json:"id"`
	Path         string `json:"path"`
	SessionID    string `json:"session_id"`
	Label        string `json:"label"`
	SessionLabel string `json:"session_label"`
	Active       bool   `json:"active"`
	Host         string `json:"host"`
	State        string `json:"state,omitempty"`
	Working      bool   `json:"working,omitempty"`
}

// HostGroup is one host's slice of the Sessions view. Unreachable hosts keep
// their header row and an error string so the group does not silently vanish.
type HostGroup struct {
	Label     string         `json:"label"`
	Local     bool           `json:"local,omitempty"`
	Reachable bool           `json:"reachable"`
	Error     string         `json:"error,omitempty"`
	Entries   []SessionEntry `json:"entries"`
}

// ApplySessionActivity replaces activity in place. Session rows match SessionID;
// window rows also match the agent's WindowID against the row ID.
func ApplySessionActivity(entries []SessionEntry, agents []AgentEntry) {
	for i := range entries {
		entry := &entries[i]
		entry.State, entry.Working = "", false
		for _, agent := range agents {
			if entry.SessionID == "" || entry.SessionID != agent.SessionID ||
				(entry.Kind != "session" && (entry.Kind != "window" || entry.ID != agent.WindowID)) {
				continue
			}
			state := agent.State
			if state != "blocked" && state != "working" {
				state = "idle"
			}
			if entry.State == "" || AgentStateRank(state) < AgentStateRank(entry.State) {
				entry.State = state
			}
			entry.Working = entry.Working || state == "working"
		}
	}
}

type apiSession struct {
	SessionID string `json:"session_id"`
	Label     string `json:"label"`
}

type apiWindow struct {
	WindowID       string `json:"window_id"`
	Label          string `json:"label"`
	FocusedBlockID string `json:"focused_block_id"`
	Active         bool
}

// sessionWindowWorkers limits concurrent Rex processes per session listing.
const sessionWindowWorkers = 4

// SessionEntries lists sessions and their windows in sidebar order: each
// session is followed by its tabs. A window is active when it is the
// session's active window; a session is active when it is the origin session.
func SessionEntries(originSession string) ([]SessionEntry, error) {
	out, err := Run("ls", "--json")
	if err != nil {
		return nil, err
	}
	var data struct {
		Sessions []apiSession `json:"sessions"`
	}
	if err := json.Unmarshal([]byte(out), &data); err != nil {
		return nil, fmt.Errorf("could not parse the session list: %w", err)
	}
	// Fetch into separate slots, then assemble rows in sidebar order. Failed
	// sessions keep their session row but have no window rows.
	windowsBySession := make([][]apiWindow, len(data.Sessions))
	jobs := make(chan int)
	var workers sync.WaitGroup
	for range min(sessionWindowWorkers, len(data.Sessions)) {
		workers.Go(func() {
			for i := range jobs {
				windows, err := sessionWindows(data.Sessions[i].SessionID)
				if err == nil {
					// Resolve titles serially inside each worker: at most four Rex
					// calls at once, even for sessions with many unnamed tabs.
					for j := range windows {
						windows[j].Label = sessionWindowLabel(data.Sessions[i].SessionID, windows[j])
					}
					windowsBySession[i] = windows
				}
			}
		})
	}
	for i := range data.Sessions {
		jobs <- i
	}
	close(jobs)
	workers.Wait()

	entries := make([]SessionEntry, 0, len(data.Sessions)*2)
	for i, session := range data.Sessions {
		entries = append(entries, SessionEntry{
			Kind: "session", ID: session.SessionID, Path: session.SessionID, SessionID: session.SessionID,
			Label: session.Label, SessionLabel: session.Label,
			Active: session.SessionID == originSession,
		})
		for _, window := range windowsBySession[i] {
			entries = append(entries, SessionEntry{
				Kind: "window", ID: window.WindowID, Path: window.WindowID, SessionID: session.SessionID,
				Label: window.Label, SessionLabel: session.Label, Active: window.Active,
			})
		}
	}
	return entries, nil
}

type sessionView struct {
	ActiveWindowID string      `json:"active_window_id"`
	Windows        []apiWindow `json:"windows"`
}

func sessionWindows(sessionID string) ([]apiWindow, error) {
	out, err := apiCall(sessionID, "session.view", map[string]string{"session_id": sessionID})
	if err != nil {
		return nil, err
	}
	var view sessionView
	if json.Unmarshal([]byte(out), &view) != nil {
		return nil, fmt.Errorf("could not parse the window list for %s", sessionID)
	}
	windows := make([]apiWindow, 0, len(view.Windows))
	for _, window := range view.Windows {
		window.Active = window.WindowID == view.ActiveWindowID
		windows = append(windows, window)
	}
	return windows, nil
}

// sessionWindowLabel mirrors Rex's terminal title fallback without changing
// stored labels. Explicit tab names never need an additional Rex call.
func sessionWindowLabel(sessionID string, window apiWindow) string {
	autogenerated := len(window.WindowID) >= 8 && window.Label == "Window "+window.WindowID[len(window.WindowID)-8:]
	if window.FocusedBlockID == "" || (window.Label != "" && !autogenerated) {
		return window.Label
	}
	out, err := Run("block", "call", "-s", sessionID, "-b", window.FocusedBlockID, "title")
	if err != nil {
		return window.Label
	}
	var result struct {
		Title string `json:"title"`
	}
	if json.Unmarshal([]byte(out), &result) != nil || strings.TrimSpace(result.Title) == "" {
		return window.Label
	}
	return result.Title
}

func apiCall(sessionID, method string, params any) (string, error) {
	return apiCallOn("", sessionID, method, params)
}

func apiCallOn(host, sessionID, method string, params any) (string, error) {
	args := []string{"api", "call"}
	if sessionID != "" {
		args = append(args, "-s", sessionID)
	}
	payload, err := json.Marshal(params)
	if err != nil {
		return "", err
	}
	args = append(args, method, string(payload))
	out, err := RunOn(host, args...)
	if err != nil {
		return "", err
	}
	return out, nil
}

// Jump activates a session or window for the requesting client, falling back
// to server-side focus when no client context exists.
func Jump(entry SessionEntry, client string) error {
	if client != "" {
		kv := []string{"session_id=" + entry.SessionID}
		if entry.Kind == "window" {
			kv = append(kv, "window_id="+entry.ID)
		}
		return Do(client, "session.select", kv...)
	}
	return focusLocalSession(entry)
}

func focusLocalSession(entry SessionEntry) error {
	if entry.Kind == "window" {
		return FocusWindow("", entry.SessionID, entry.ID)
	}
	windows, err := sessionWindows(entry.SessionID)
	if err != nil || len(windows) == 0 {
		return fmt.Errorf("session %s has no windows", entry.SessionLabel)
	}
	return focusWindowOf(windows, entry)
}

func focusWindowOf(windows []apiWindow, entry SessionEntry) error {
	active := windows[0].WindowID
	for _, window := range windows {
		if window.Active {
			active = window.WindowID
			break
		}
	}
	return FocusWindow("", entry.SessionID, active)
}

// JumpOnHost activates a row that lives on another host. The app keeps one
// client per server; the remote client shares the origin client's label, so the
// row is selected through that host's copy of the app. Server-side focus is
// the fallback when no matching client answers.
func JumpOnHost(host string, entry SessionEntry, clientID string) error {
	if host == "" || host == LocalHostLabel {
		return Jump(entry, clientID)
	}
	if client := appClientOn(host, ClientLabel(clientID)); client != "" {
		kv := []string{"session_id=" + entry.SessionID}
		if entry.Kind == "window" {
			kv = append(kv, "window_id="+entry.ID)
		}
		if err := DoOn(host, client, "session.select", kv...); err == nil {
			return nil
		}
	}
	windows, err := hostWindows(host, entry.SessionID)
	if err != nil || len(windows) == 0 {
		return fmt.Errorf("session %s has no windows on %s", entry.SessionLabel, host)
	}
	if entry.Kind == "window" {
		return FocusWindow(host, entry.SessionID, entry.ID)
	}
	return focusRemoteWindow(host, windows, entry)
}

func focusRemoteWindow(host string, windows []apiWindow, entry SessionEntry) error {
	active := windows[0].WindowID
	for _, window := range windows {
		if window.Active {
			active = window.WindowID
			break
		}
	}
	return FocusWindow(host, entry.SessionID, active)
}

func hostWindows(host, sessionID string) ([]apiWindow, error) {
	out, err := apiCallOn(host, sessionID, "session.view", map[string]string{"session_id": sessionID})
	if err != nil {
		return nil, err
	}
	var view sessionView
	if json.Unmarshal([]byte(out), &view) != nil {
		return nil, fmt.Errorf("could not parse the window list for %s", sessionID)
	}
	return view.Windows, nil
}

func FocusWindow(host, sessionID, windowID string) error {
	_, err := apiCallOn(host, "", "session.focus_window", map[string]string{"session_id": sessionID, "window_id": windowID})
	return err
}

// CloseWindow closes one window; CloseSession destroys the whole session.
func CloseWindow(host, sessionID, windowID string) error {
	_, err := apiCallOn(host, "", "session.close_window", map[string]string{"session_id": sessionID, "window_id": windowID})
	return err
}

func CloseSession(host, sessionID string) error {
	_, err := apiCallOn(host, "", "session.destroy", map[string]string{"session_id": sessionID})
	return err
}

func SetWindowLabel(host, sessionID, windowID, label string) error {
	_, err := apiCallOn(host, "", "session.set_window_label", map[string]string{"session_id": sessionID, "window_id": windowID, "label": label})
	return err
}

func SetSessionLabel(host, sessionID, label string) error {
	_, err := apiCallOn(host, "", "session.set_label", map[string]string{"session_id": sessionID, "label": label})
	return err
}

// SessionGroups lists every host's sessions, local first. Each host answers in
// parallel: one ls for the sessions and one agent snapshot for activity. A
// host that fails keeps its header with the error; the view must not hide
// configured hosts just because SSH or the server is down. localAgents feeds
// the local group's activity so callers with a fresh cached snapshot avoid a
// second scan; nil just means plain local rows.
func SessionGroups(originSession string, localAgents []AgentEntry) []HostGroup {
	hosts := Hosts()
	groups := make([]HostGroup, len(hosts))
	of := make([]HostGroup, len(hosts))
	var mu sync.Mutex
	mapHosts(hosts, func(host Host) {
		group := hostGroup(host, originSession, localAgents)
		mu.Lock()
		of[indexOfHost(hosts, host)] = group
		mu.Unlock()
	})
	copy(groups, of)
	return groups
}

func indexOfHost(hosts []Host, target Host) int {
	for i, host := range hosts {
		if host.Label == target.Label {
			return i
		}
	}
	return 0
}

// Session listing budgets: remote hosts answer over SSH and may be down;
// sessions and activity fetch in parallel so the slower one hides inside the
// faster one. A host that misses its budget keeps its header with a short
// error instead of stalling the whole view.
const (
	remoteListTimeout  = 3
	remoteAgentTimeout = 4
	localAgentTimeout  = 3
)

func hostGroup(host Host, originSession string, localAgents []AgentEntry) HostGroup {
	name := ""
	if !host.Local {
		name = host.Label
	}
	group := HostGroup{Label: host.Label, Local: host.Local, Reachable: true, Entries: []SessionEntry{}}
	type listing struct {
		out string
		err error
	}
	ls := make(chan listing, 1)
	go func() {
		out, err := RunOnBounded(name, remoteListTimeout, "ls", "--json")
		ls <- listing{out, err}
	}()
	type activity struct {
		agents []AgentEntry
		err    error
	}
	agents := make(chan activity, 1)
	go func() {
		if host.Local && localAgents != nil {
			agents <- activity{agents: localAgents}
			return
		}
		budget := localAgentTimeout
		if !host.Local {
			budget = remoteAgentTimeout
		}
		out, err := RunOnBounded(name, budget, "do", "-e", agentsScript, "--json")
		if err != nil {
			agents <- activity{err: err}
			return
		}
		decoded, decodeErr := decodeAgentEntries([]byte(out), "", time.Now())
		agents <- activity{agents: decoded, err: decodeErr}
	}()
	listed := <-ls
	if listed.err != nil {
		group.Reachable = false
		group.Error = shortHostError(listed.err)
		if group.Error == "" {
			group.Error = "unreachable"
		}
		return group
	}
	var data struct {
		Sessions []apiSession `json:"sessions"`
	}
	if json.Unmarshal([]byte(listed.out), &data) != nil {
		group.Reachable = false
		group.Error = "could not parse the session list"
		return group
	}
	entries := make([]SessionEntry, 0, len(data.Sessions))
	for _, session := range data.Sessions {
		entries = append(entries, SessionEntry{
			Kind: "session", ID: session.SessionID, Path: session.SessionID, SessionID: session.SessionID,
			Label: session.Label, SessionLabel: session.Label, Host: host.Label,
			Active: host.Local && session.SessionID == originSession,
		})
	}
	// Activity is optional: a slow or absent snapshot keeps plain rows.
	if snapshot := <-agents; snapshot.err == nil && snapshot.agents != nil {
		ApplySessionActivity(entries, snapshot.agents)
	}
	group.Entries = entries
	return group
}

// shortHostError strips the rex command line and transport detail: the view
// should explain "the host is down", not dump an argv.
func shortHostError(err error) string {
	message := err.Error()
	if idx := strings.Index(message, ": "); idx >= 0 && strings.HasPrefix(message, "rex ") {
		message = message[idx+2:]
	}
	if idx := strings.IndexByte(message, '\n'); idx >= 0 {
		message = message[:idx]
	}
	if len(message) > 120 {
		message = message[:120]
	}
	return message
}

// CreateSessionOn reuses a host session by label or creates one at dir, then
// returns the session id. The bool reports whether an existing session matched.
func CreateSessionOn(host, dir string) (string, bool, error) {
	name := paths.Basename(dir)
	if out, err := RunOn(host, "ls", "--json"); err == nil {
		var data struct {
			Sessions []apiSession `json:"sessions"`
		}
		if json.Unmarshal([]byte(out), &data) == nil {
			for _, session := range data.Sessions {
				if session.Label == name {
					return session.SessionID, true, nil
				}
			}
		}
	}
	out, err := RunOn(host, "new", "--json", "-c", dir, name)
	if err != nil {
		return "", false, err
	}
	var res struct {
		SessionID string `json:"session_id"`
	}
	if json.Unmarshal([]byte(out), &res) != nil || res.SessionID == "" {
		return "", false, fmt.Errorf("could not create session for %s on %s", dir, host)
	}
	return res.SessionID, false, nil
}

// SelectOnHost switches the host's app client to a session, falling back to
// server-side focus on that host.
func SelectOnHost(host, sessionID, clientID string) error {
	entry := SessionEntry{Kind: "session", ID: sessionID, Path: sessionID, SessionID: sessionID}
	return JumpOnHost(host, entry, clientID)
}

// apiTimeout documents the shared rex call budget for session mutations.
const apiTimeout = 15 * time.Second
