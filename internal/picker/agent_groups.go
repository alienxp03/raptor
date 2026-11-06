package picker

import (
	"fmt"
	"time"

	"github.com/alienxp03/raptor/internal/rex"
)

type agentIdentity [4]string

func agentKey(e rex.AgentEntry) agentIdentity {
	return agentIdentity{e.SessionID, e.WindowID, e.BlockID, e.AgentID}
}

func (m *dirModel) captureAgentGroups() {
	if m.agentGroups == nil {
		m.agentGroups = make(map[agentIdentity]int)
	}
	for _, e := range m.agents {
		key := agentKey(e)
		if _, ok := m.agentGroups[key]; !ok {
			m.agentGroups[key] = rex.AgentStateRank(e.State)
		}
	}
}

type agentDisplayRow struct {
	header   string
	position int
	spacer   bool
}

// Headers use viewport lines, not selectable positions. Repeat the current
// group header at the scroll boundary when there is room for header + agent.
func (m *dirModel) agentDisplayRows(height int) []agentDisplayRow {
	if height <= 0 {
		return nil
	}
	labels := [...]string{"Blocked", "Working", "Idle"}
	var rows []agentDisplayRow
	selected, last := 0, -1
	for position, index := range m.agentsView {
		e := m.agents[index]
		group, ok := m.agentGroups[agentKey(e)]
		if !ok {
			group = rex.AgentStateRank(e.State)
		}
		if group != last {
			rows = append(rows, agentDisplayRow{header: labels[group]})
			last = group
		}
		if position == m.sel {
			selected = len(rows)
		}
		rows = append(rows, agentDisplayRow{position: position})
	}
	// Separate groups when the whole list fits; tight viewports keep room
	// for navigation instead of spending lines on decorative spacing.
	gaps := 0
	for i, row := range rows {
		if i > 0 && row.header != "" {
			gaps++
		}
	}
	if len(rows)+gaps <= height {
		spaced := make([]agentDisplayRow, 0, len(rows)+gaps)
		for i, row := range rows {
			if i > 0 && row.header != "" {
				spaced = append(spaced, agentDisplayRow{position: -1, spacer: true})
			}
			spaced = append(spaced, row)
		}
		return spaced
	}
	start := maxInt(selected-height+1, 0)
	if start > 0 && rows[start].header == "" && height >= 2 {
		// Reserve a line for the repeated header without hiding selection.
		start = maxInt(start, selected-height+2)
		if rows[start].header != "" {
			return rows[start:min(len(rows), start+height)]
		}
		header := start
		for header > 0 && rows[header].header == "" {
			header--
		}
		result := []agentDisplayRow{rows[header]}
		end := min(len(rows), start+height-1)
		return append(result, rows[start:end]...)
	}
	return rows[start:min(len(rows), start+height)]
}

func agentAge(updated *time.Time, now time.Time) string {
	if updated == nil || updated.IsZero() {
		return ""
	}
	age := now.Sub(*updated)
	switch {
	case age < time.Minute:
		return "now"
	case age < time.Hour:
		return fmt.Sprintf("%dm", int(age/time.Minute))
	case age < 24*time.Hour:
		return fmt.Sprintf("%dh", int(age/time.Hour))
	default:
		return fmt.Sprintf("%dd", int(age/(24*time.Hour)))
	}
}
