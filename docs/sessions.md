# Sessions

The Sessions view is the launcher: one flat list where you pick where to work, and Enter always gets you there — sesh-style select-or-create.

There is one native Mac session/directory launcher. Cmd+Shift+S selects Sessions. Escape dismisses the launcher.

To open the launcher directly from Rex, bind the action:

```lua
rex.bind("shift+cmd+o", "raptor")
rex.bind("shift+cmd+c", "raptor_pr_open")
```

## The list

Two row types, one verb:

- **Live sessions** on every connected host. Pinned rows appear ahead of the current session. Other sessions use most-recently-used order; sessions without history keep Rex's source order. Remote rows carry an `@host` badge; activity (working/blocked) shows right-aligned. Enter switches to the session — through the host's own copy of the app, so it works across hosts and Tailscale.
- **Frecency directories** (zoxide) from every host that do not already have a same-name live session, with a shallow fd scan (depth 2 from `$HOME`, Trash and Library pruned) appended below them. The scan surfaces projects zoxide has never seen — newly created folders, never-`cd`'d paths — capped at 100 entries so it stays a fallback, not a second index. Remote directories read the host's zoxide and run the same scan over SSH, preferring `fd` and falling back to POSIX `find`. Enter creates the session — named after the directory — and switches to it. An existing session with the same label is reused, never duplicated. Opening a directory that came from the scan runs `zoxide add` on it, so after first use it becomes a permanent zoxide entry (sesh's AddToZoxide behavior).
- **Typed paths**: a query starting with `~/`, `/`, `./`, or `../` that resolves to an existing local directory adds one extra row below the matches — the sesh behavior of opening any path you hand it, not just listed ones. Remote typed paths are a follow-up.

Cmd+Shift+P pins or unpins the selected session or local directory. Pinned rows appear ahead of the current session. Session pins persist with their host identity, so equal session IDs on different hosts stay separate. Local directory pins also persist. Remote directories cannot be pinned. The origin pane context is kept when refreshing.

Rows have one leading session or directory icon. Pins follow the title. The current session has no extra circle; accessibility still announces its active state.

## Activity

Working shows `...`; a finished unread result shows a small, static theme-accent dot on the session or agent icon. A matching Rex seen receipt removes the dot. Working and unread are independent, so both can show. Blocked activity stays independent too. Unread-only rows do not animate. Accessibility announces “Finished, unread”. Raw `done` or `idle` state alone does not mean unread.

The backend reads the local Mac client's `com.superlogical.rex` preference `Workspace.programActivitySeen`. Receipts match block ID, record ID, and update time in milliseconds. Idle completion needs an alerted receipt. Missing or unsupported receipt data hides the dot; local preferences cannot establish another client's seen state. Raptor keeps no receipt ledger and writes no seen receipts.

Receipt changes refresh rows only while the picker is visible and its context is ready. Selection, query, target, and scroll stay unchanged. This needs no status event or full scan. Reopen reconciles cached rows with current receipts.

## Recent-use order

Raptor records acknowledged session switches and the session from which you open the picker. On macOS, a small adapter also watches Rex's private `Workspace.lastFocusedSession` preference while the app is frontmost. This includes switches made in Rex's sidebar, not just Raptor. The installed Rex API has no last-used timestamp or selected-session event.

The backend validates the app PID and session/host membership before saving an observation. History persists on the same filesystem for the Mac app and CLI backend. Without the Mac observer, confirmed Raptor navigation still records visits.

On an empty-query open or reopen, select the current session, even below pinned rows. If the current session is unavailable, select the first displayed row. A nonempty search selects its top ranked match, and live refreshes preserve the user's selection.

The rank snapshot stays fixed while the picker is open. Agent reports, title changes, and background work do not change recency. Search puts matching open sessions before directories. Within each group, exact names lead fuzzy matches, with recent-use order for ties. Each match stays within one name, path, or hostname. A leading dot does not prevent an exact folder match: `pi` finds `.pi` before scattered directory-path matches. Pins affect empty-query order only; search keeps relevance and recent-use tie order.

History builds from observed visits, not inferred past activity. Up to 256 host/session timestamps and host-qualified session pins persist together in `~/Library/Application Support/raptor/state.json` (directory mode 0700, file mode 0600). Raptor migrates existing pins and recency history there on first access. Directory pins and user-editable settings remain in `~/.config/raptor/config.toml`. Missing focus preferences do not clear history.

## Last Session

**Cmd+P** runs Last Session (`raptor_session_last`). It uses the same shared
session-recency history as the Sessions list, validates the host, and skips
deleted sessions. The legacy single session ID is used only as a fallback.

```lua
rex.bind("cmd+p", "raptor_session_last")
```

## Open-target override

Local directory rows can skip session creation: Ctrl+O cycles the open target (session → tab → cd here → pane right → pane below), and Enter dispatches with it, exactly like the old directory picker. Remote rows always launch sessions on their host.

## Worktree creation

Invoke `raptor_worktree_new` from Rex or bind it to a key; Instant Pi worktrees and PR checkout provide additional ways to start work. Use Worktrunk directly for listing/removal.

## Pull requests

Cmd+Shift+C opens **Checkout pull request** from Rex or inside the picker. In Rex, `raptor init` binds it directly to `raptor_pr_open`; Cmd+Shift+O still opens Raptor. Pasting a GitHub PR URL into search remains available. Confirm the form before Raptor creates or opens resources.

## Close

Ctrl+X closes the selected session. Raptor refuses to close the session the picker opened from.

## Preview

The native picker shows session labels, activity, and host badges. Directory rows show their paths.

## Hosts

Hosts come from the Rex server's host list with This Mac first. A host that is down keeps its sessions if they were fetched recently and explains itself rather than vanishing; its directories simply don't appear until it answers.
