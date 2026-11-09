package picker

import (
	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/rex"
	tea "github.com/charmbracelet/bubbletea"
)

type activityEventMsg struct{}
type activityLiveMsg struct {
	id, agentsRequest, sessionsRequest uint64
	agents                             []rex.AgentEntry
	groups                             []rex.HostGroup
	err                                error
	remoteAgents                       map[string][]rex.AgentEntry
}

func waitActivityEvent(w *rex.EventWatcher) tea.Cmd {
	if w == nil {
		return nil
	}
	return func() tea.Msg {
		select {
		case <-w.Done():
			return nil
		case <-w.Changes:
			return activityEventMsg{}
		}
	}
}

func (m *dirModel) refreshLiveActivity() tea.Cmd {
	if m.activityLivePending {
		m.activityLiveDirty = true
		return nil
	}
	m.activityLivePending = true
	m.activityLiveDirty = false
	m.activityLiveID++
	m.agentsRequest++
	m.launcherSessionsRequest++
	m.agentsLoading, m.launcherSessionsLoading = true, true
	id, ar, sr, session := m.activityLiveID, m.agentsRequest, m.launcherSessionsRequest, m.ctx.Session
	return func() tea.Msg {
		agents, err := rex.AgentEntries(session)
		groups := rex.SessionGroups(session, agents)
		remote := map[string][]rex.AgentEntry{}
		for _, group := range groups {
			if !group.Local && group.Reachable {
				if entries, remoteErr := rex.AgentEntriesOn(group.Label, ""); remoteErr == nil {
					remote[group.Label] = entries
				}
			}
		}
		return activityLiveMsg{id: id, agentsRequest: ar, sessionsRequest: sr, agents: agents, groups: groups, err: err, remoteAgents: remote}
	}
}

func (m *dirModel) acceptLiveActivity(msg activityLiveMsg) tea.Cmd {
	if msg.id != m.activityLiveID || !m.activityLivePending || m.activityStopping {
		return nil
	}
	m.activityLivePending = false
	// Preserve each host's existing shortcut order during automatic refreshes.
	for i := range msg.groups {
		for _, old := range m.sessions {
			if old.Label != msg.groups[i].Label || old.Local != msg.groups[i].Local {
				continue
			}
			incoming := msg.groups[i].Entries
			ordered := make([]rex.SessionEntry, 0, len(incoming))
			used := make(map[string]bool)
			for _, entry := range old.Entries {
				for _, fresh := range incoming {
					if fresh.Kind == entry.Kind && fresh.ID == entry.ID {
						ordered = append(ordered, fresh)
						used[fresh.Kind+fresh.ID] = true
						break
					}
				}
			}
			for _, entry := range incoming {
				if !used[entry.Kind+entry.ID] {
					ordered = append(ordered, entry)
				}
			}
			msg.groups[i].Entries = ordered
		}
	}
	if m.activityRemote == nil {
		m.activityRemote = map[string][]rex.AgentEntry{}
	}
	for host, agents := range msg.remoteAgents {
		m.activityRemote[host] = agents
		catalog.ApplyDirectoryActivityOn(host, m.hostDirs[host], agents)
	}
	m.acceptLauncherSessions(launcherSessionsMsg{request: msg.sessionsRequest, groups: msg.groups})
	m.acceptAgents(agentsLoadedMsg{request: msg.agentsRequest, entries: msg.agents, err: msg.err})
	cmds := []tea.Cmd{m.schedulePreview()}
	for _, group := range msg.groups {
		if m.activityWatcher != nil {
			if !group.Local {
				m.activityWatcher.AddHost(group.Label)
			}
		}
		if group.Reachable && m.hostDirs[group.Label] == nil {
			cmds = append(cmds, m.loadLauncherDirs(group.Label, false))
		}
	}
	if m.activityLiveDirty {
		cmds = append(cmds, m.refreshLiveActivity())
	}
	return tea.Batch(cmds...)
}
