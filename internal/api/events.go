package api

import (
	"context"
	"fmt"
	"time"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/rex"
)

type snapshotLoader func(rex.Ctx, bool) ([]rex.AgentEntry, []catalog.LauncherItem, []hostHeader, error)

func (h *Handler) cacheGeneration() uint64 {
	h.cacheMu.Lock()
	defer h.cacheMu.Unlock()
	return h.generation
}

// Invalidation never removes usable rows. Only the event path schedules work;
// reading a warm snapshot cannot start a scan or a self-refresh loop.
func (h *Handler) invalidateActivity() {
	h.cacheMu.Lock()
	h.generation++
	h.cacheMu.Unlock()
}

func (h *Handler) storeLauncher(generation uint64, items []catalog.LauncherItem, hosts []hostHeader) {
	h.cacheMu.Lock()
	defer h.cacheMu.Unlock()
	if generation != h.generation {
		return
	}
	h.commitLauncher(items, hosts)
}

// cacheMu must be held. Published slices are never changed after this call.
func (h *Handler) commitLauncher(items []catalog.LauncherItem, hosts []hostHeader) {
	h.commitLauncherAt(items, hosts, h.launcher.ScanStarted)
}

func (h *Handler) commitLauncherAt(items []catalog.LauncherItem, hosts []hostHeader, started time.Time) {
	// A failed host must not erase its last usable rows. Host headers still
	// report the error; successful empty hosts do replace their old rows.
	failed := make(map[string]bool)
	for _, host := range hosts {
		if !host.Reachable {
			failed[host.Label] = true
		}
	}
	if len(failed) != 0 && h.launcherLoaded {
		kept := make([]catalog.LauncherItem, 0, len(items)+len(h.launcher.Items))
		for _, item := range items {
			if !failed[item.Host] {
				kept = append(kept, item)
			}
		}
		for _, item := range h.launcher.Items {
			if failed[item.Host] {
				kept = append(kept, item)
			}
		}
		// Fresh and retained rows each have sessions before folders. Keep
		// that boundary after merging, without changing either kind's order.
		items = make([]catalog.LauncherItem, 0, len(kept))
		for _, item := range kept {
			if item.Kind == "session" {
				items = append(items, item)
			}
		}
		for _, item := range kept {
			if item.Kind != "session" {
				items = append(items, item)
			}
		}
	}
	if items == nil {
		items = []catalog.LauncherItem{}
	}
	h.launcher = launcherCacheEntry{Timestamp: time.Now(), ScanStarted: started, Items: items, Hosts: hosts}
	h.launcherLoaded = true
	h.launcherGeneration = h.generation
	h.writeLauncherCache(items, hosts)
}

// At most one snapshot worker exists, including across subscription changes.
// Events during a scan set one pending bit. Publish each completed snapshot
// before the trailing scan, so continuous activity cannot starve the UI.
func (h *Handler) requestRefresh() {
	h.cacheMu.Lock()
	defer h.cacheMu.Unlock()
	h.queueRefreshLocked()
}

func (h *Handler) requestLiveRefresh() {
	h.cacheMu.Lock()
	defer h.cacheMu.Unlock()
	if h.notify != nil {
		h.queueRefreshLocked()
	}
}

func (h *Handler) queueRefreshLocked() {
	h.generation++
	h.refreshPending = true
	h.refreshLauncher = true
	h.startRefreshLocked()
}

func (h *Handler) startRefreshLocked() {
	if h.revalidating {
		return
	}
	h.revalidating = true
	h.refreshDone = make(chan struct{})
	go h.refresh()
}

func (h *Handler) refreshCold(launcher bool) error {
	return h.refreshColdContext(context.Background(), launcher)
}

func (h *Handler) refreshColdContext(ctx context.Context, launcher bool) error {
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		h.cacheMu.Lock()
		loaded := h.activityLoaded
		if launcher {
			loaded = h.launcherLoaded
		}
		if loaded {
			h.cacheMu.Unlock()
			return nil
		}
		if launcher && !h.refreshLauncher {
			h.refreshLauncher = true
			if h.revalidating {
				h.refreshPending = true
				h.generation++
			}
		}
		h.startRefreshLocked()
		done, changed := h.refreshDone, h.snapshotChanged
		h.cacheMu.Unlock()
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-done:
		case <-changed:
		}
		h.cacheMu.Lock()
		loaded = h.activityLoaded
		if launcher {
			loaded = h.launcherLoaded
		}
		working := h.revalidating
		h.cacheMu.Unlock()
		if loaded {
			return nil
		}
		if !working {
			return fmt.Errorf("snapshot unavailable")
		}
	}
}

func (h *Handler) refresh() {
	h.cacheMu.Lock()
	defer func() {
		h.revalidating = false
		close(h.refreshDone)
		h.cacheMu.Unlock()
	}()
	for {
		generation, presentation := h.generation, h.presentation
		origin, cfg, load := h.ctx, h.cfg, h.loadSnapshot // capture only while locked
		launcher, hadLauncher := h.refreshLauncher, h.launcherLoaded
		h.refreshPending = false
		h.cacheMu.Unlock()

		// Base snapshots do not depend on the current presentation's origin.
		origin.Session, origin.Block = "", ""
		if load == nil {
			load = func(origin rex.Ctx, launcher bool) ([]rex.AgentEntry, []catalog.LauncherItem, []hostHeader, error) {
				worker := New(origin, cfg)
				agents, err := rex.AgentEntries("")
				var items []catalog.LauncherItem
				var hosts []hostHeader
				if launcher && (err == nil || !hadLauncher) {
					if err != nil {
						// Status is optional. An explicit empty slice prevents a
						// second status scan from holding cold discovery hostage.
						agents = []rex.AgentEntry{}
					}
					items, hosts = worker.fetchLauncher(agents)
				}
				return agents, items, hosts, err
			}
		}
		started := time.Now()
		agents, items, hosts, err := load(origin, launcher)

		h.cacheMu.Lock()
		if presentation == h.presentation && (err == nil || (launcher && !h.launcherLoaded && items != nil)) {
			if err == nil {
				h.activityAgents = append([]rex.AgentEntry{}, agents...)
				h.activityLoaded = true
				h.activityAt, h.activityGeneration = time.Now(), generation
			}
			if launcher {
				h.commitLauncherAt(items, hosts, started)
			}
			close(h.snapshotChanged)
			h.snapshotChanged = make(chan struct{})
			// Keep notification and presentation changes ordered. No worker from an
			// old subscription can notify after unsubscribe or a context response.
			if h.notify != nil {
				_ = h.notify()
			}
		}
		if !h.refreshPending {
			return
		}
	}
}
