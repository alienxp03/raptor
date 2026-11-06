package catalog

import (
	"path/filepath"
	"sort"
	"strings"

	"github.com/alienxp03/raptor/internal/paths"

	"github.com/alienxp03/raptor/internal/rex"
)

// ApplyDirectoryActivity replaces activity in place. A directory contains an
// agent when its canonical cwd equals the directory or is below it.
func ApplyDirectoryActivity(items []Directory, agents []rex.AgentEntry) {
	cwds := make([]string, len(agents))
	for i, agent := range agents {
		cwds[i] = paths.Canonical(agent.Cwd)
	}
	for i := range items {
		item := &items[i]
		item.State, item.Working = "", false
		dir := paths.Canonical(item.Path)
		if dir == "" {
			continue
		}
		for j, agent := range agents {
			if cwds[j] == "" {
				continue
			}
			rel, err := filepath.Rel(dir, cwds[j])
			if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
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
