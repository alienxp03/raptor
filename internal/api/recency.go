package api

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/alienxp03/raptor/internal/rex"
)

const focusQueueLimit = 32

type focusObservation struct {
	sid     string
	pid     int
	at      time.Time
	initial bool
	origin  bool
}

type focusKey struct {
	pid int
	sid string
}

type focusWorker struct {
	mu      sync.Mutex
	pending []focusObservation
	wake    chan struct{}
	// A bounded high-water table rejects duplicate and out-of-order delivery.
	latest map[focusKey]focusObservation
}

// Rank maps are detached and immutable after publication. Never load history
// from sessions queries, live events, or the observation worker.
func (h *Handler) captureRecency(visitOrigin bool) {
	h.cacheMu.Lock()
	defer h.cacheMu.Unlock()
	load := h.loadRecency
	if load == nil {
		load = rex.LoadSessionRecency
	}
	ranks := load()
	h.ranks = make(rex.SessionRecency, len(ranks))
	for key, rank := range ranks {
		h.ranks[key] = rank
	}
	if visitOrigin && fullSessionID(h.ctx.Session) && h.focus != nil {
		h.focus.enqueue(focusObservation{sid: h.ctx.Session, at: time.Now(), origin: true})
	}
}

func fullSessionID(s string) bool {
	return strings.HasPrefix(s, "session:") && len(s) > len("session:") && len(s) <= 256 && !strings.ContainsFunc(s, func(r rune) bool { return unicode.IsSpace(r) || unicode.IsControl(r) })
}

func (h *Handler) observeFocus(params json.RawMessage) (any, error) {
	var p struct {
		SessionID  string `json:"session_id"`
		ClientPID  string `json:"client_pid"`
		ObservedAt string `json:"observed_at"`
		Initial    bool   `json:"initial"`
	}
	if len(params) > 2048 {
		return nil, fmt.Errorf("observation too large")
	}
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	pid, err := strconv.Atoi(p.ClientPID)
	if err != nil || pid <= 0 || len(p.ClientPID) > 10 || !fullSessionID(p.SessionID) {
		return nil, fmt.Errorf("invalid focus observation")
	}
	at, err := time.Parse(time.RFC3339Nano, p.ObservedAt)
	if err != nil || !at.After(time.Unix(0, 0)) || at.After(time.Now()) {
		return nil, fmt.Errorf("invalid observed_at")
	}
	h.cacheMu.Lock()
	if h.focus != nil {
		h.focus.enqueue(focusObservation{sid: p.SessionID, pid: pid, at: at, initial: p.Initial})
	}
	h.cacheMu.Unlock()
	return struct{}{}, nil
}

func (w *focusWorker) enqueue(o focusObservation) {
	w.mu.Lock()
	defer w.mu.Unlock()
	key := focusKey{pid: o.pid, sid: o.sid}
	if last, ok := w.latest[key]; ok && (!o.at.After(last.at)) {
		return
	}
	if len(w.latest) >= 128 { // Keep memory bounded even for hostile PID churn.
		var oldest focusKey
		var at time.Time
		for pid, last := range w.latest {
			if at.IsZero() || last.at.Before(at) {
				oldest, at = pid, last.at
			}
		}
		delete(w.latest, oldest)
	}
	w.latest[key] = o
	// Only the same session can be coalesced. Distinct visits from one
	// client must survive slow validation (A → B → C is three visits).
	for i, old := range w.pending {
		if old.pid == o.pid && old.sid == o.sid {
			w.pending = append(w.pending[:i], w.pending[i+1:]...)
			break
		}
	}
	if len(w.pending) == focusQueueLimit {
		oldest := 0
		for i := range w.pending {
			if w.pending[i].at.Before(w.pending[oldest].at) {
				oldest = i
			}
		}
		if !o.at.After(w.pending[oldest].at) {
			return
		}
		w.pending = append(w.pending[:oldest], w.pending[oldest+1:]...)
	}
	w.pending = append(w.pending, o)
	select {
	case w.wake <- struct{}{}:
	default:
	}
}

func (h *Handler) startFocusWorker(parent context.Context) func() {
	ctx, cancel := context.WithCancel(parent)
	w := &focusWorker{wake: make(chan struct{}, 1), latest: make(map[focusKey]focusObservation)}
	h.cacheMu.Lock()
	h.focus = w
	validate, resolve, record := h.validateFocus, h.resolveFocus, h.recordFocus
	h.cacheMu.Unlock()
	if validate == nil {
		validate = rex.ValidateFocusClientPIDContext
	}
	if resolve == nil {
		resolve = h.resolveFocusHost
	}
	if record == nil {
		record = rex.RecordSessionVisit
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			select {
			case <-ctx.Done():
				return
			case <-w.wake:
			}
			for ctx.Err() == nil {
				w.mu.Lock()
				if len(w.pending) == 0 {
					w.mu.Unlock()
					break
				}
				o := w.pending[0]
				w.pending = w.pending[1:]
				w.mu.Unlock()
				if !o.origin && !validate(ctx, o.pid) {
					continue
				}
				if ctx.Err() != nil {
					return
				}
				host, ok := resolve(ctx, o.sid)
				if !ok || ctx.Err() != nil {
					continue
				}
				if o.origin && host != "" && host != rex.LocalHostLabel {
					continue
				}
				// History sorts by observation time. A completed older visit
				// remains useful behind newer visits; it must not be discarded.
				if ctx.Err() == nil {
					_ = record(host, o.sid, o.at, o.initial)
				}
			}
		}
	}()
	return func() {
		h.cacheMu.Lock()
		if h.focus == w {
			h.focus = nil
		}
		h.cacheMu.Unlock()
		cancel()
		<-done
	}
}

// Cached full IDs carry host identity. A cache miss uses native read-only
// listings, never agent snapshots or client.session_ids attachments.
func (h *Handler) resolveFocusHost(ctx context.Context, sid string) (string, bool) {
	h.cacheMu.Lock()
	hosts := make(map[string]bool)
	for _, item := range h.launcher.Items {
		if item.Kind != "session" || item.SessionID != sid {
			continue
		}
		host := item.Host
		if item.Local || host == rex.LocalHostLabel {
			host = ""
		}
		hosts[host] = true
	}
	h.cacheMu.Unlock()
	if len(hosts) > 1 {
		return "", false
	}
	for host := range hosts {
		return host, true
	}
	return resolveNativeFocusHost(ctx, sid)
}

// One total budget also bounds configurations with many/unreachable hosts.
// Fail closed if any listing fails: uniqueness cannot then be established.
func resolveNativeFocusHost(parent context.Context, sid string) (string, bool) {
	ctx, cancel := context.WithTimeout(parent, 10*time.Second)
	defer cancel()
	list := func(host string) (bool, bool) {
		var data struct {
			Sessions []struct {
				ID string `json:"session_id"`
			} `json:"sessions"`
		}
		args := []string{"ls", "--json"}
		if host != "" {
			args = append([]string{"-S", host, "--timeout", "2s"}, args...)
		}
		if !focusRead(ctx, args, &data) || data.Sessions == nil {
			return false, false
		}
		for _, session := range data.Sessions {
			if session.ID == sid {
				return true, true
			}
		}
		return false, true
	}
	found, ok := list("")
	if !ok {
		return "", false
	}
	selected := ""
	var data struct {
		Hosts []struct {
			Label string `json:"label"`
		} `json:"hosts"`
	}
	if !focusRead(ctx, []string{"api", "call", "hosts.list"}, &data) || data.Hosts == nil {
		return "", false
	}
	seen := map[string]bool{"": true, rex.LocalHostLabel: true}
	for _, host := range data.Hosts {
		if seen[host.Label] {
			continue
		}
		seen[host.Label] = true
		match, valid := list(host.Label)
		if !valid || (match && found) {
			return "", false
		}
		if match {
			selected, found = host.Label, true
		}
	}
	return selected, found && ctx.Err() == nil
}

func focusRead(parent context.Context, args []string, result any) bool {
	ctx, cancel := context.WithTimeout(parent, 3*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "rex", args...)
	cmd.WaitDelay = 100 * time.Millisecond
	out, err := cmd.Output()
	return err == nil && json.Unmarshal(out, result) == nil
}
