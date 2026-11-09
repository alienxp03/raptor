package rex

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"os/exec"
	"sync"
	"time"
)

// EventChange is a coalesced invalidation, not a state snapshot. Host identifies
// one cause (empty for local). A queued change can merge causes from other hosts;
// consumers must refresh all watched hosts, each with its own host-scoped API.
type EventChange struct{ Host string }

// EventWatcher owns long-lived CLI children. Close cancels and reaps all of
// them. Its bounded channel deliberately merges bursts: snapshots are truth.
type EventWatcher struct {
	Changes <-chan EventChange
	changes chan EventChange
	ctx     context.Context
	cancel  context.CancelFunc
	mu      sync.Mutex
	hosts   map[string]bool
	wg      sync.WaitGroup
}

func WatchEvents(parent context.Context) *EventWatcher {
	ctx, cancel := context.WithCancel(parent)
	ch := make(chan EventChange, 1)
	w := &EventWatcher{Changes: ch, changes: ch, ctx: ctx, cancel: cancel, hosts: map[string]bool{}}
	w.AddHost("")
	return w
}

func (w *EventWatcher) AddHost(host string) {
	if host == LocalHostLabel {
		host = ""
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.ctx.Err() != nil || w.hosts[host] {
		return
	}
	w.hosts[host] = true
	w.wg.Add(1)
	go func() { defer w.wg.Done(); w.follow(host) }()
}

// Discover adds configured remote servers without a finite subprocess helper
// or an uncancellable host-list request. Host-list output is bounded too.
func (w *EventWatcher) Discover() {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.ctx.Err() != nil {
		return
	}
	w.wg.Add(1)
	go func() {
		defer w.wg.Done()
		ctx, cancel := context.WithTimeout(w.ctx, 10*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, "rex", "--autostart=false", "api", "call", "hosts.list")
		pipe, err := cmd.StdoutPipe()
		if err != nil {
			return
		}
		if cmd.Start() != nil {
			return
		}
		stopRead := context.AfterFunc(ctx, func() { _ = pipe.Close() })
		defer stopRead()
		data, err := io.ReadAll(io.LimitReader(pipe, 1<<20))
		cancel()
		_ = cmd.Wait()
		if err != nil {
			return
		}
		var result hostsResult
		if json.Unmarshal(data, &result) != nil {
			return
		}
		for _, h := range result.Hosts {
			if h.Label != "" {
				w.AddHost(h.Label)
			}
		}
	}()
}

func (w *EventWatcher) Done() <-chan struct{} { return w.ctx.Done() }

func (w *EventWatcher) Close() {
	w.mu.Lock()
	w.cancel()
	w.mu.Unlock()
	w.wg.Wait()
}

func (w *EventWatcher) changed(host string) {
	select {
	case w.changes <- EventChange{Host: host}:
	default:
	}
}

func (w *EventWatcher) follow(host string) {
	backoff := 100 * time.Millisecond
	for w.ctx.Err() == nil {
		started := time.Now()
		w.stream(host)
		if w.ctx.Err() != nil {
			return
		}
		if time.Since(started) > 30*time.Second {
			backoff = 100 * time.Millisecond
		}
		timer := time.NewTimer(backoff)
		select {
		case <-w.ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
		backoff = min(backoff*2, 5*time.Second)
	}
}

func (w *EventWatcher) stream(host string) {
	ctx, cancel := context.WithCancel(w.ctx)
	defer cancel()
	args := []string{"--autostart=false", "--timeout", "2s"}
	if host != "" {
		args = append(args, "-S", host)
	}
	args = append(args, "do", "-e", eventsScript, "--all", "--fail-fast")
	cmd := exec.CommandContext(ctx, "rex", args...)
	pipe, err := cmd.StdoutPipe()
	if err != nil {
		return
	}
	if cmd.Start() != nil {
		return
	}
	// Closing the pipe also interrupts reads if a descendant retains stdout.
	stopRead := context.AfterFunc(ctx, func() { _ = pipe.Close() })
	defer stopRead()
	connected := false
	scanner := bufio.NewScanner(pipe)
	scanner.Buffer(make([]byte, 4096), 1<<20)
	for scanner.Scan() {
		var event struct {
			Type string `json:"type"`
		}
		if json.Unmarshal(scanner.Bytes(), &event) == nil {
			if event.Type == "raptor_ready" {
				connected = true
				w.changed(host)
				continue
			}
			if event.Type == "hosts_changed" {
				w.Discover()
			}
		}
		if relevantEvent(scanner.Bytes()) {
			w.changed(host)
		}
	}
	cancel()
	_ = cmd.Wait()
	// Invalidate once when an established stream drops; failed reconnects
	// must not turn into periodic state polling while the server is offline.
	if connected && w.ctx.Err() == nil {
		w.changed(host)
	}
}

// Ignore CLI/client churn: snapshot CLI requests themselves generate these
// events, and feeding them back would create a refresh loop.
func relevantEvent(data []byte) bool {
	var event struct {
		Type    string `json:"type"`
		Payload struct {
			Event json.RawMessage `json:"event"`
			Name  string          `json:"name"`
		} `json:"payload"`
	}
	if json.Unmarshal(data, &event) != nil {
		return false
	}
	switch event.Type {
	case "session_event":
		return relevantEvent(event.Payload.Event)
	case "block_event":
		switch event.Payload.Name {
		case "title_changed", "program_status_changed", "program_status_removed", "pwd_changed", "process_changed", "child_exited":
			return true
		}
		return false
	case "activity_changed", "session_created", "session_destroyed", "session_moved", "session_label_changed", "session_view_changed", "active_window_changed", "window_created", "window_closed", "window_destroyed", "window_label_changed", "block_created", "block_closed", "block_destroyed", "layout_changed", "hosts_changed", "tailscale_status_changed", "server_connected", "server_disconnected":
		return true
	}
	return false
}
