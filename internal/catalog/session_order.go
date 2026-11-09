package catalog

import (
	"sort"

	"github.com/alienxp03/raptor/internal/rex"
)

// OrderLauncherSessionsByRecency changes session order only. Callers supply a
// presentation's immutable ranks, then pin the origin and apply fuzzy search.
// Unknown sessions keep the native source order; folder order never changes.
func OrderLauncherSessionsByRecency(items []LauncherItem, ranks rex.SessionRecency) {
	sessions := make([]LauncherItem, 0)
	for _, item := range items {
		if item.Kind == "session" {
			sessions = append(sessions, item)
		}
	}
	rank := func(item LauncherItem) int {
		host := item.Host
		if item.Local {
			host = ""
		}
		return ranks.Rank(host, item.SessionID)
	}
	sort.SliceStable(sessions, func(i, j int) bool {
		return rank(sessions[i]) < rank(sessions[j])
	})
	n := 0
	for i := range items {
		if items[i].Kind == "session" {
			items[i] = sessions[n]
			n++
		}
	}
}
