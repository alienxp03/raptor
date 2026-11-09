# Agents

Use **Sessions · Agents** to switch views. Tab moves forward; Shift+Tab moves back. Escape dismisses the launcher from any of these views, even with search text entered. Ctrl+U clears the search in the terminal picker. In the Mac picker, Cmd+Shift+A selects Agents directly.

To open Agents directly from Rex, add this to your Rex config and reload it:

```lua
rex.bind("cmd+shift+a", function()
  rex.invoke("raptor_agents")
  return true
end)
```

The `raptor_agents` action supports both the Mac and terminal pickers. From an open terminal directory or worktree list, it selects Agents without opening another layer. Forms and confirmations keep their input until you dismiss them.

Agents lists the agent program-status records that Rex reports for terminal panes. It supports Pi, Codex, and Claude. Search by name, app, state, session, or tab. Enter opens the agent's exact pane, not just its tab.

## What is a row?

One row represents one reported agent record. A tab with several agent panes has several rows. A pane can also have several records. Duplicate tab names are expected.

This is not a scan of all operating-system processes. A headless agent that does not report status to Rex does not appear. Rex events trigger fresh status and name snapshots while the picker is open. No periodic status polling is used. A session or pane that closes during discovery does not block the other rows.

Rows use an app icon and agent name. Every row shows session/tab context on the right; repeated tab names are omitted. Idle agents have no status badge. A compact age shows the time since Rex's last status report, when available.

## Status groups and time

Groups appear in this order: **Blocked → Working → Idle**. Empty groups are hidden. Within each group, newer Rex status reports come first. Missing or invalid timestamps sort last in their group; equal timestamps keep their source order.

This time is the native `program_status.updated_at`. It is not process creation time, token arrival time, or the Pi name bridge's heartbeat.

Group placement and existing row order remain a snapshot while the picker is open. A new opening or search can regroup the results. Newly discovered records wait for a new opening; names and activity can update in place. This avoids unexpected movement of numbered targets.

## Working indicators

Working indicators use three animated dots in **Sessions and Agents**. Blocked indicators remain static; Idle has no indicator. The Mac picker respects the system's Reduced Motion setting. Set `REX_REDUCED_MOTION=1` to disable terminal animation. `NO_COLOR` disables terminal colors, not motion.

Directory indicators show only agents whose working directory exactly matches that folder. Activity in child folders does not mark the parent. Local symlink aliases still match the same folder. A row with both blocked and working agents can show both indicators. Rex status events update activity while the picker is open. The indicators show reported agent status, not CPU activity.

Agents is a navigation view. It does not terminate, rename, or close agents. Use the agent's own commands for those actions.

## Pi session names

An optional Pi extension can publish `/name` changes without changing the terminal title or Rex's native status reports. Existing Pi processes need `/reload` once after this extension is installed. New Pi processes load it at startup.

The bridge writes one private metadata file per Pi process:

```text
$XDG_CACHE_HOME/raptor/agents/pi-<pid>.json
```

Without `XDG_CACHE_HOME`, the current Raptor cache location is `~/Library/Caches/raptor/agents/`.

```json
{
  "pid": 1234,
  "app": "pi",
  "name": "fix-login",
  "block_id": "block:...",
  "session_id": "session:...",
  "updated_at": "2026-11-06T13:30:00.000Z"
}
```

Write files atomically with mode `0600`. Publish at session start and on `session_info_changed`; refresh every five seconds. Remove the process's own file at session shutdown.

Rex's native program-status title takes priority. If the title is empty, Raptor uses the bridge name only when the process owner, pane, session, and fresh timestamp match a Rex agent record. Invalid or old metadata is ignored. Metadata does not create extra agent rows. Without a matching name, Raptor uses the terminal title or app name.
