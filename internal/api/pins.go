package api

import (
	"sort"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/paths"
)

// Pinning is Raptor state, not a Rex event. Patch its visible snapshot now;
// refresh once in the background to restore frecency order after unpinning.
func (h *Handler) patchLauncherPin(path string, pinned bool) {
	_, _ = h.readLauncherCache()
	canonical := paths.Canonical(path)
	h.cacheMu.Lock()
	defer h.cacheMu.Unlock()
	// An older scan must not undo this local mutation when it completes.
	h.presentation++
	if h.launcherLoaded {
		items := append([]catalog.LauncherItem{}, h.launcher.Items...)
		localDirs := []catalog.LauncherItem{}
		for i := range items {
			if items[i].Kind != "dir" || !items[i].Local {
				continue
			}
			if paths.Canonical(items[i].Path) == canonical {
				items[i].Pinned = pinned
			}
			localDirs = append(localDirs, items[i])
		}
		sort.SliceStable(localDirs, func(i, j int) bool {
			return localDirs[i].Pinned && !localDirs[j].Pinned
		})
		n := 0
		for i := range items {
			if items[i].Kind == "dir" && items[i].Local {
				items[i] = localDirs[n]
				n++
			}
		}
		h.commitLauncher(items, h.launcher.Hosts)
	}
	h.queueRefreshLocked()
}
