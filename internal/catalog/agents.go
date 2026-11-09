package catalog

import (
	"path/filepath"
	"sort"

	"github.com/alienxp03/raptor/internal/paths"

	"github.com/alienxp03/raptor/internal/rex"
)

// ApplyDirectoryActivity replaces activity in place. Only an exact canonical
// working-directory match contributes activity; parent directories stay quiet.
func ApplyDirectoryActivity(items []Directory, agents []rex.AgentEntry) {
	ApplyDirectoryActivityOn("", items, agents)
}

// Remote paths belong to another filesystem. Never resolve their symlinks or
// relative paths against this machine when projecting a host-native snapshot.
func ApplyDirectoryActivityOn(host string, items []Directory, agents []rex.AgentEntry) {
	normalize := paths.Canonical
	if host != "" && host != rex.LocalHostLabel {
		normalize = func(value string) string {
			if value == "" {
				return ""
			}
			return filepath.Clean(value)
		}
	}
	cwds := make([]string, len(agents))
	for i, agent := range agents {
		cwds[i] = normalize(agent.Cwd)
	}
	for i := range items {
		item := &items[i]
		item.State, item.Working = "", false
		dir := normalize(item.Path)
		if dir == "" {
			continue
		}
		for j, agent := range agents {
			if cwds[j] != dir {
				continue
			}
			state := agent.State
			if state != "blocked" && state != "working" {
				state = "idle"
			}
			if item.State == "" || rex.AgentStateRank(state) < rex.AgentStateRank(item.State) {
				item.State = state
			}
			item.Working = item.Working || state == "working"
		}
	}
}

// FilterAgents searches names, applications, state, sessions and tabs. Empty
// and non-empty queries both preserve incoming group/time order.
func FilterAgents(entries []rex.AgentEntry, query string) []int {
	texts := make([]string, len(entries))
	for i, e := range entries {
		texts[i] = e.Label + " " + e.App + " " + e.State + " " + e.SessionLabel + " " + e.WindowLabel
	}
	indices := match(texts, query)
	// Fuzzy scores select matches, but must not reorder the agent groups.
	sort.Ints(indices)
	return indices
}
