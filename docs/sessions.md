# Sessions

The Sessions view is the launcher: one flat list where you pick where to work, and Enter always gets you there — sesh-style select-or-create.

Use **Sessions · Agents** to switch views. Tab moves between them; Shift+Tab goes back; Ctrl+S selects Sessions from any view. In the Mac picker, Cmd+Shift+S does the same. Escape dismisses the launcher.

To open the launcher directly from Rex, bind the action:

```lua
rex.bind("cmd+shift+s", function()
  rex.invoke("raptor_sessions")
end)
```

## The list

Two row types, one verb:

- **Live sessions** on every connected host. The session you came from is pinned to the top. Remote rows carry an `@host` badge; activity (working/blocked) shows right-aligned. Enter switches to the session — through the host's own copy of the app, so it works across hosts and Tailscale.
- **Frecency directories** (zoxide) from every host that do not already have a same-name live session. Enter creates the session — named after the directory — and switches to it. An existing session with the same label is reused, never duplicated. Remote directories read the host's zoxide over SSH.

Pinned local directories float to the top of the directory block (Ctrl+G toggles). The origin pane context is kept when refreshing.

## Open-target override

Local directory rows can skip session creation: Ctrl+O cycles the open target (session → tab → split → here), and Enter dispatches with it, exactly like the old directory picker. Remote rows always launch sessions on their host.

## Worktrees

Ctrl+T opens the worktree browser for the selected Git repository; Ctrl+N opens the create-worktree form directly.

## Close

Ctrl+X closes the selected session. Raptor refuses to close the session the picker opened from.

## Preview

With a terminal at least 100 columns wide, the right side shows a live capture of the selected session (polled while the selection stays put; remote hosts are captured over their connection with a short timeout). Directory rows preview the full path and the session name that Enter would create. Narrower terminals — including phones — render rows only.

## Hosts

Hosts come from the Rex server's host list with This Mac first. A host that is down keeps its sessions if they were fetched recently and explains itself rather than vanishing; its directories simply don't appear until it answers.
