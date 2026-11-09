package picker

import (
	"os"
	"strings"
	"time"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/rex"
	tea "github.com/charmbracelet/bubbletea"
)

type activityLoadedMsg struct {
	entries []rex.AgentEntry
	err     error
}

type activityTickMsg struct{ id uint64 }

func activityCommand(session string) tea.Cmd {
	return func() tea.Msg {
		entries, err := rex.AgentEntries(session)
		return activityLoadedMsg{entries, err}
	}
}

func applyRowActivity(rows []row, agents []rex.AgentEntry) {
	items := make([]catalog.Directory, len(rows))
	for i, r := range rows {
		items[i] = catalog.Directory{Path: r.path}
	}
	catalog.ApplyDirectoryActivity(items, agents)
	for i, item := range items {
		rows[i].state, rows[i].working = item.State, item.Working
	}
}

// projectActivity folds agent activity onto launcher directory rows. Session
// rows already carry their state from the host listing.
func (m *dirModel) projectActivity(agents []rex.AgentEntry) {
	paths := make([]string, len(m.launcher))
	for i, r := range m.launcher {
		if r.dir != nil {
			paths[i] = r.dir.Path
		}
	}
	items := make([]catalog.Directory, len(paths))
	for i, path := range paths {
		items[i] = catalog.Directory{Path: path}
	}
	catalog.ApplyDirectoryActivity(items, agents)
	for i, item := range items {
		if m.launcher[i].dir != nil {
			m.launcher[i].dir.State = item.State
			m.launcher[i].dir.Working = item.Working
		}
	}
}

// REX_REDUCED_MOTION disables animation for any nonempty value other than
// 0, false, or off (case-insensitive). NO_COLOR removes indicator color only.
func reducedMotion() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("REX_REDUCED_MOTION"))) {
	case "", "0", "false", "off":
		return false
	default:
		return true
	}
}

func activityIndicator(state string, working bool, frame int) string {
	result := ""
	if state == "blocked" {
		result = " !"
		if _, plain := os.LookupEnv("NO_COLOR"); !plain {
			result = styGhost.Render(result)
		}
	}
	if working || state == "working" {
		glyph := "•"
		if !reducedMotion() {
			glyph = []string{"•", "∙", "·", "∙"}[frame%4]
		}
		indicator := " " + glyph
		if _, plain := os.LookupEnv("NO_COLOR"); !plain {
			indicator = stySession.Render(indicator)
		}
		result += indicator
	}
	return result
}

func (m *dirModel) hasWorkingData() bool {
	for _, r := range m.launcher {
		if r.sessionWorking() || r.sessionState() == "working" ||
			(r.dir != nil && (r.dir.Working || r.dir.State == "working")) {
			return true
		}
	}
	for _, e := range m.agents {
		if e.State == "working" {
			return true
		}
	}
	for _, group := range m.sessions {
		for _, e := range group.Entries {
			if e.Working || e.State == "working" {
				return true
			}
		}
	}
	return false
}

func (m *dirModel) scheduleActivityTick() tea.Cmd {
	if m.activityStopping || reducedMotion() || !m.hasWorkingData() || m.activityTickPending {
		return nil
	}
	m.activityTickPending = true
	m.activityTickID++
	id := m.activityTickID
	return tea.Tick(500*time.Millisecond, func(time.Time) tea.Msg { return activityTickMsg{id} })
}
