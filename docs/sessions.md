# Sessions

Use **Repos · Sessions · Agents** to switch views. Tab moves forward; Shift+Tab moves back; Ctrl+S selects Sessions from any view. In the Mac picker, Cmd+Shift+S selects Sessions directly. Escape dismisses the launcher from any of these views.

To open Sessions directly from Rex, add this to your Rex config and reload it:

```lua
rex.bind("cmd+shift+s", function()
  rex.invoke("raptor_sessions")
end)
```

The `raptor_sessions` action supports both the Mac and terminal pickers. From an open terminal directory or worktree list, it selects Sessions without opening another layer.

## Hosts

Sessions are grouped by host: **This Mac** first, then every remote host the server knows (`hosts.list`). Each host answers in parallel; a host that is down keeps its header with an "unreachable" note instead of silently disappearing. While filtering, groups without matching sessions hide.

Every row is a session; tabs stay inside the session. The origin session carries a dot. Sessions show agent activity (working/blocked) when the host reports it.

## Switch

Enter jumps to the selected session. The app keeps one client per server, so a remote session is selected through that host's copy of the app (matched by client label); server-side focus is the fallback. This works from both the Mac and terminal pickers, including over Tailscale.

## Create

Each reachable host group ends with a **New Session** row. It lists that host's frecency directories — the same zoxide order as Repos. Local hosts read the local database; remote hosts are queried over SSH (batch mode, short connect timeout, common install paths tried when zoxide is not on the non-interactive PATH).

Enter creates a session named after the directory and switches to it. An existing session with the same label is reused, never duplicated. Create failures keep the picker open with the error so you can retry.

## Close

Ctrl+X (terminal) or ⌘X / the Close button (Mac) closes the selected session after you confirm on the Mac. Raptor refuses to close the session the picker opened from. Renames and window-level actions stay in Rex itself for now.

## Remote requirements

- The remote host runs a reachable Rex server (`rex -S <host> ls` answers).
- SSH access matching the host label for directory search (`ssh <host>`), with BatchMode.
- zoxide on the remote host for directory suggestions; without it, only switching, closing, and manual paths work.
