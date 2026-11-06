package rex

import (
	"encoding/json"
	"sort"
	"time"
)

// AgentStateRank orders blocked, working, then idle (including unknown states).
func AgentStateRank(state string) int {
	switch state {
	case "blocked":
		return 0
	case "working":
		return 1
	default:
		return 2
	}
}

// SortGroups sorts in place by state, then newest UpdatedAt first. Missing times
// sort last within each group. Equal times retain source order.
func SortGroups(entries []AgentEntry) {
	sort.SliceStable(entries, func(i, j int) bool {
		a, b := entries[i], entries[j]
		if ar, br := AgentStateRank(a.State), AgentStateRank(b.State); ar != br {
			return ar < br
		}
		if a.UpdatedAt == nil || a.UpdatedAt.IsZero() {
			return false
		}
		return b.UpdatedAt == nil || b.UpdatedAt.IsZero() || a.UpdatedAt.After(*b.UpdatedAt)
	})
}

// Only native status time is used. Invalid/absent times stay unknown; valid
// future times are preserved, since producer clock skew is not proof of error.
func agentUpdatedAt(raw json.RawMessage) *time.Time {
	var updated time.Time
	if json.Unmarshal(raw, &updated) != nil || updated.IsZero() {
		return nil
	}
	return &updated
}
