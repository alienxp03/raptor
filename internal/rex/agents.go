package rex

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/alienxp03/raptor/internal/paths"
)

// AgentEntry is one live program_status record, not one tab or metadata file.
type AgentEntry struct {
	Path         string     `json:"path"`
	Kind         string     `json:"kind"`
	Label        string     `json:"label"`
	App          string     `json:"app"`
	State        string     `json:"state"`
	AgentID      string     `json:"agent_id,omitempty"`
	SessionID    string     `json:"session_id"`
	SessionLabel string     `json:"session_label"`
	WindowID     string     `json:"window_id"`
	WindowLabel  string     `json:"window_label"`
	BlockID      string     `json:"block_id"`
	Active       bool       `json:"active,omitempty"`
	UpdatedAt    *time.Time `json:"updated_at,omitempty"`
	Cwd          string     `json:"cwd,omitempty"`
}

// One CLI process, serial API requests, no process spawning per pane. pcall
// tolerates sessions/panes disappearing while the snapshot is being read.
const agentsScript = `
local result = { sessions = {} }
local listing = rex.call("session.list", {})
for _, s in ipairs(listing.sessions or {}) do
 local ok, attached = pcall(rex.call, "session.attach", {session_id=s.session_id})
 if ok and attached and attached.view then
  local view = attached.view
  local session = {session_id=s.session_id, label=s.label, active_window_id=view.active_window_id, windows={}}
  for _, w in ipairs(view.windows or {}) do
   local window = {window_id=w.window_id, label=w.label, focused_block_id=w.focused_block_id, blocks={}}
   for _, layer in ipairs(w.layers or {}) do
    for _, b in ipairs(layer.blocks or {}) do
     if b.creator_name == "com.superlogical.terminal" then
      local args = {session_id=s.session_id, block_id=b.block_id, args={}}
      local good, status = pcall(rex.call, "com.superlogical.terminal.program_status", args)
      if good and status and status.records and #status.records > 0 then
       local block = {block_id=b.block_id, records=status.records}
       local titled, title = pcall(rex.call, "com.superlogical.terminal.title", args)
       if titled and title then block.title = title.title end
       local inspected, process = pcall(rex.call, "com.superlogical.terminal.process", args)
       if inspected and process then block.process = process end
       table.insert(window.blocks, block)
      end
     end
    end
   end
   if #window.blocks == 0 then window.blocks = nil end
   table.insert(session.windows, window)
  end
  if #session.windows == 0 then session.windows = nil end
  table.insert(result.sessions, session)
 end
end
if #result.sessions == 0 then result.sessions = nil end
return result
`

type agentProcess struct {
	PID  int    `json:"pid"`
	Name string `json:"name"`
	Cwd  string `json:"cwd"`
}

type agentRecord struct {
	ID           string          `json:"id"`
	App          string          `json:"app"`
	EffectiveApp string          `json:"effective_app"`
	State        string          `json:"state"`
	Title        string          `json:"title"`
	Msg          string          `json:"msg"`
	Owner        *agentProcess   `json:"owner"`
	UpdatedAt    json.RawMessage `json:"updated_at"`
}

type agentBlock struct {
	BlockID string        `json:"block_id"`
	Title   string        `json:"title"`
	Records []agentRecord `json:"records"`
	Process *struct {
		Foreground *agentProcess `json:"foreground"`
	} `json:"process"`
}

// AgentEntries returns blocked, working, then idle agents, newest native status
// update first within each group. Equal or missing times retain decode order.
func AgentEntries(originSession string) ([]AgentEntry, error) {
	out, err := Run("do", "-e", agentsScript, "--json")
	if err != nil {
		return nil, err
	}
	return decodeAgentEntries([]byte(out), originSession, time.Now())
}

func decodeAgentEntries(data []byte, origin string, now time.Time) ([]AgentEntry, error) {
	return decodeAgentEntriesWithNames(data, origin, now, true)
}

func decodeAgentEntriesWithNames(data []byte, origin string, now time.Time, localNames bool) ([]AgentEntry, error) {
	var snapshot struct {
		Sessions []struct {
			SessionID      string `json:"session_id"`
			Label          string `json:"label"`
			ActiveWindowID string `json:"active_window_id"`
			Windows        []struct {
				WindowID       string       `json:"window_id"`
				Label          string       `json:"label"`
				FocusedBlockID string       `json:"focused_block_id"`
				Blocks         []agentBlock `json:"blocks"`
			} `json:"windows"`
		} `json:"sessions"`
	}
	if err := json.Unmarshal(data, &snapshot); err != nil {
		return nil, fmt.Errorf("could not parse agents: %w", err)
	}
	entries := make([]AgentEntry, 0)
	for _, s := range snapshot.Sessions {
		for _, w := range s.Windows {
			windowLabel := w.Label
			generated := len(w.WindowID) >= 8 && w.Label == "Window "+w.WindowID[len(w.WindowID)-8:]
			if strings.TrimSpace(windowLabel) == "" || generated {
				for _, block := range w.Blocks {
					if block.BlockID == w.FocusedBlockID && strings.TrimSpace(block.Title) != "" {
						windowLabel = strings.TrimSpace(block.Title)
						break
					}
				}
			}
			if strings.TrimSpace(windowLabel) == "" {
				windowLabel = w.WindowID
			}
			for _, b := range w.Blocks {
				for _, r := range b.Records {
					app := normalizeAgentApp(r.EffectiveApp)
					if app == "" {
						app = normalizeAgentApp(r.App)
					}
					// Rex owns record lifetime and emits program_status_removed.
					// A process snapshot must not override its native status records.
					if app == "" {
						continue
					}
					state := r.State
					// done/error describe a task, not process exit. Keep the live
					// agent visible as idle until ownership proves it has stopped.
					switch state {
					case "working", "blocked":
					default:
						state = "idle"
					}
					label := strings.TrimSpace(r.Title)
					// Rex's native record title is authoritative. The optional Pi
					// name bridge only fills names that the program did not report.
					if label == "" && localNames && app == "pi" && r.Owner != nil {
						if name := piAgentName(r.Owner.PID, b.BlockID, s.SessionID, now); name != "" {
							label = name
						}
					}
					// Status messages (for example "Needs input") are not agent names.
					if label == "" {
						label = strings.TrimSpace(b.Title)
					}
					if label == "" {
						label = app
					}
					cwd := ""
					if b.Process != nil && b.Process.Foreground != nil {
						cwd = b.Process.Foreground.Cwd
					}
					entries = append(entries, AgentEntry{
						Path: b.BlockID + "#" + r.ID, Kind: "agent", Label: label, App: app, State: state, AgentID: r.ID,
						SessionID: s.SessionID, SessionLabel: s.Label, WindowID: w.WindowID, WindowLabel: windowLabel, BlockID: b.BlockID,
						Active:    s.SessionID == origin && w.WindowID == s.ActiveWindowID && b.BlockID == w.FocusedBlockID,
						UpdatedAt: agentUpdatedAt(r.UpdatedAt), Cwd: cwd,
					})
				}
			}
		}
	}
	SortGroups(entries)
	return entries, nil
}

func normalizeAgentApp(app string) string {
	switch strings.ToLower(strings.TrimSpace(app)) {
	case "pi", "pi-coding-agent", "@earendil-works/pi-coding-agent", "@mariozechner/pi-coding-agent":
		return "pi"
	case "codex", "codex-cli", "openai-codex", "@openai/codex":
		return "codex"
	case "claude", "claude-code", "claude_code", "@anthropic-ai/claude-code":
		return "claude"
	}
	return ""
}

func piAgentName(pid int, block, session string, now time.Time) string {
	if pid <= 0 {
		return ""
	}
	file := filepath.Join(paths.CacheDir(), "agents", fmt.Sprintf("pi-%d.json", pid))
	info, err := os.Lstat(file)
	if err != nil || !info.Mode().IsRegular() || info.Size() > 64*1024 {
		return ""
	}
	data, err := os.ReadFile(file)
	if err != nil {
		return ""
	}
	var m struct {
		PID       int       `json:"pid"`
		App       string    `json:"app"`
		Name      string    `json:"name"`
		BlockID   string    `json:"block_id"`
		SessionID string    `json:"session_id"`
		UpdatedAt time.Time `json:"updated_at"`
	}
	if json.Unmarshal(data, &m) != nil || m.PID != pid || m.App != "pi" || m.BlockID != block || m.SessionID != session || m.UpdatedAt.IsZero() || now.Sub(m.UpdatedAt) > 15*time.Second || m.UpdatedAt.After(now.Add(5*time.Second)) {
		return ""
	}
	return strings.TrimSpace(m.Name)
}

// JumpAgent verifies membership before changing focus, then selects the exact
// session/window on the requesting client. Never resolve ambiguous short IDs.
func JumpAgent(entry AgentEntry, client string) error {
	if strings.TrimSpace(entry.SessionID) == "" || strings.TrimSpace(entry.WindowID) == "" || strings.TrimSpace(entry.BlockID) == "" {
		return fmt.Errorf("session_id, window_id and block_id are required")
	}
	out, err := apiCall(entry.SessionID, "session.list_blocks", map[string]string{"session_id": entry.SessionID})
	if err != nil {
		return err
	}
	var listing struct {
		Blocks []struct {
			BlockID  string `json:"block_id"`
			WindowID string `json:"window_id"`
			Creator  string `json:"creator_name"`
		} `json:"blocks"`
	}
	if err := json.Unmarshal([]byte(out), &listing); err != nil {
		return fmt.Errorf("could not validate agent pane: %w", err)
	}
	found := false
	for _, b := range listing.Blocks {
		if b.BlockID == entry.BlockID && b.WindowID == entry.WindowID && b.Creator == "com.superlogical.terminal" {
			found = true
			break
		}
	}
	if !found {
		return fmt.Errorf("agent pane is gone or does not belong to this session/window")
	}
	if _, err := apiCall(entry.SessionID, "session.focus_block", map[string]string{"session_id": entry.SessionID, "block_id": entry.BlockID}); err != nil {
		return err
	}
	if client != "" {
		return Do(client, "session.select", "session_id="+entry.SessionID, "window_id="+entry.WindowID)
	}
	return nil
}
