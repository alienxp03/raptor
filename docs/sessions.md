# Sessions

The Sessions view is the launcher: one flat list where you pick where to work, and Enter always gets you there — sesh-style select-or-create.

There is one session/directory launcher. Ctrl+S selects Sessions from a nested terminal view; in the Mac picker, Cmd+Shift+S does the same. Escape dismisses the launcher.

To open the launcher directly from Rex, bind the action:

```lua
rex.bind("cmd+shift+o", function()
  rex.invoke("raptor")
end)
```

## The list

Two row types, one verb:

- **Live sessions** on every connected host. The session you came from is pinned to the top. Other sessions use most-recently-used order; sessions without history keep Rex's source order. Remote rows carry an `@host` badge; activity (working/blocked) shows right-aligned. Enter switches to the session — through the host's own copy of the app, so it works across hosts and Tailscale.
- **Frecency directories** (zoxide) from every host that do not already have a same-name live session. Enter creates the session — named after the directory — and switches to it. An existing session with the same label is reused, never duplicated. Remote directories read the host's zoxide over SSH.

Pinned local directories float to the top of the directory block (Ctrl+G toggles). The origin pane context is kept when refreshing.

## Recent-use order

Raptor records acknowledged session switches and the session from which you open the picker. On macOS, a small adapter also watches Rex's private `Workspace.lastFocusedSession` preference while the app is frontmost. This includes switches made in Rex's sidebar, not just Raptor. The installed Rex API has no last-used timestamp or selected-session event.

Go validates the app PID and session/host membership before saving an observation. History is shared by the Mac and terminal interfaces on the same filesystem. Without the Mac observer, confirmed Raptor navigation still records visits.

On an empty-query open or reopen, the default selection is the most-recent non-current live session. If none exists, select a directory before falling back to the current session. The current session remains marked and available; its top-of-list position does not make it the default destination. A nonempty search selects its top ranked match, and live refreshes preserve the user's selection.

The rank snapshot stays fixed while the picker is open. Agent reports, title changes, and background work do not change recency. Search prefers exact folder names and session labels, then fuzzy-match quality, with recent-use order for ties. A leading dot does not prevent an exact folder match: `pi` finds `.pi` before scattered path matches. A matching current session stays first.

History builds from observed visits, not inferred past activity. Up to 256 host/session timestamps persist in `$XDG_CACHE_HOME/raptor/session-recency.json`, or `~/Library/Caches/raptor/session-recency.json` by default. The file is private and atomically updated. Missing focus preferences do not clear history.

## Last Session

Use **Cmd+P** on Mac or **Ctrl+P** on mobile for Last Session
(`raptor_session_last`). It uses the same shared session-recency history as the
Sessions list, validates the host, and skips deleted sessions. The legacy single
session ID is used only as a fallback.

```lua
rex.bind("cmd+p", "raptor_session_last")
-- Mobile:
rex.bind("ctrl+p", "raptor_session_last")
```

## Open-target override

Local directory rows can skip session creation: Ctrl+O cycles the open target (session → tab → cd here → pane right → pane below), and Enter dispatches with it, exactly like the old directory picker. Remote rows always launch sessions on their host.

## Worktree creation

In the terminal picker, Ctrl+N opens the create-worktree form directly. On Mac, invoke `raptor_worktree_new` from Rex or bind it to a key. Instant Pi worktrees and PR checkout provide additional ways to start work. Use Worktrunk directly for listing/removal.

## Close

Ctrl+X closes the selected session. Raptor refuses to close the session the picker opened from.

## Preview

With a terminal at least 100 columns wide, the right side shows a live capture of the selected session (polled while the selection stays put; remote hosts are captured over their connection with a short timeout). Directory rows preview the full path and the session name that Enter would create. Narrower terminals — including phones — render rows only.

## Hosts

Hosts come from the Rex server's host list with This Mac first. A host that is down keeps its sessions if they were fetched recently and explains itself rather than vanishing; its directories simply don't appear until it answers.
