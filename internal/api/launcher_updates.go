package api

import (
	"time"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/launcherupdate"
	"github.com/alienxp03/raptor/internal/pullrequest"
)

// Overlay only snapshots that predate a creation. Successful later discovery
// owns renames/removals; failed hosts retain their bounded creation hints.
func overlayLauncher(entry launcherCacheEntry) launcherCacheEntry {
	entry.Items = append([]catalog.LauncherItem{}, entry.Items...)
	failed := map[string]bool{}
	for _, host := range entry.Hosts {
		if !host.Reachable {
			failed[host.Label] = true
		}
	}
	for _, s := range launcherupdate.Since(time.Time{}) {
		// A scan that started before (or at the same instant as) the creation
		// cannot know about it; only a strictly later completed scan is
		// authoritative. Clocks tie, so equality merges — bounded by TTL.
		if !failed[s.Host] && s.Created.Before(entry.ScanStarted) {
			continue
		}
		found := false
		for _, item := range entry.Items {
			if item.Kind == "session" && item.SessionID == s.ID && item.Local == s.Local && (s.Local || item.Host == s.Host) {
				found = true
				break
			}
		}
		if !found {
			item := catalog.LauncherItem{Kind: "session", ID: s.ID, SessionID: s.ID, Label: s.Label, SessionLabel: s.Label, Path: s.Path, Host: s.Host, Local: s.Local}
			entry.Items = append([]catalog.LauncherItem{item}, entry.Items...)
		}
	}
	return entry
}

// No scan on the mutation path: only return a complete snapshot when one is
// already available. The native client must omit replacement when absent.
func (h *Handler) launcherItems() []catalog.LauncherItem {
	cached, ok := h.readLauncherCache()
	if !ok {
		return nil
	}
	h.cacheMu.Lock()
	origin, ranks := h.ctx.Session, h.ranks
	h.cacheMu.Unlock()
	items := cached.Items
	for i := range items {
		items[i].Active = items[i].Local && items[i].SessionID == origin
	}
	catalog.OrderLauncherSessionsByRecency(items, ranks)
	return catalog.PinLauncherOrigin(items, "")
}

func (h *Handler) addLauncherItems(result map[string]any) {
	if items := h.launcherItems(); len(items) > 0 {
		result["launcher_items"] = items
	}
}

type openLauncherResult struct {
	pullrequest.OpenResult
	LauncherItems []catalog.LauncherItem `json:"launcher_items,omitempty"`
}

func (h *Handler) openLauncherResult(result pullrequest.OpenResult, err error) openLauncherResult {
	if err != nil {
		result.Error = err.Error()
	}
	return openLauncherResult{OpenResult: result, LauncherItems: h.launcherItems()}
}
