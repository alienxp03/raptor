# resh-inspired smoother UI — working notes

Reference: https://github.com/CruelAddict/resh (native Swift panel for Rex; clone kept at
`/private/tmp/pi-github-repos/runtime-KuthmQ/65d6ef16fb5654b96fd5c44aaeb42d5556c22cdf79eac589984eb56be1481d57` until it evaporates — re-clone if missing).

## Why resh starts smooth (root cause of our flicker)

- `resh serve` runs as a **launchd gui-domain job** (KeepAlive, ThrottleInterval 2) — AppKit host always resident.
- NSPanel is **pre-created once** ("Opening never clears the catalog"); open = CFMessagePort IPC → `orderFront`.
- Panel is `.nonactivatingPanel` — never steals focus from Rex, so no activation flash.
- SessionStore/data **pre-warmed** via persistent Rex connections.
- Positioned over Rex's window frame (read by PID via CGWindowList).

Our flow: `open -g -a Raptor.app raptor://picker?…` per invocation → cold app launch + Apple event +
backend start + `NSApp.activate(ignoringOtherApps:)` focus yank = the Rex flicker. Terminal path
(new Rex layer + bubbletea spawn) can never be fully flicker-free, only minimized.

## Decisions

- Scope: **smoothness architecture + resh-style design, together** (one arc of work).
- Mac app: **resident service like resh** (launchd host, pre-created nonactivating panel, IPC toggle,
  pre-warmed catalog). Go backend stays the shared logic layer.
- Terminal UI: **keep + restyle** to the same design language (box-drawing limits). Stays fallback for
  SSH/iOS. Parity rule holds.
- Adopt: **⌘1–9 direct-open + pins**.
- Dropped: Recents (zoxide) — user doesn't care.
- Theme: **done** — `5569c33 match the native picker to the rex ui` (+ `25c6c02` for terminal).

## Resolved in discussion (round 2)

- Tabs view: **list tabs AND sessions**; Enter jumps to the selection, plus manage actions
  (close/rename) on secondary shortcuts (resh Sessions-view style).
- Pins: **pin repos/dirs** in the launcher (⌘⇧P like resh); pinned float to top; persisted in
  raptor config.
- Worktree: **stays per-repo** in the existing flow; no global worktree view.
- Mac app data today: `ProcessBackend` spawns `raptor-cli` (NDJSON stdio) per picker session —
  resident model should keep app + backend alive and pre-warm the catalog.

## Final decisions (round 3)

- Trigger: **direct IPC** — init.lua runs `raptor panel open --session … --block … --mode …`;
  Go CLI talks to the resident host over a local unix socket; `open -g -a` stays as fallback and
  auto-starts the host.
- View switch: **pills + Tab key** (Repos · Tabs & Sessions), clickable in Mac app, Tab/Shift-Tab
  cycles in both UIs.
- Panel sizing: **auto-height** to result count (capped), anchored over the origin Rex window.

## Proposed implementation order

1. Resident host: launchd gui job + `serve` mode, pre-created panel, persistent backend child,
   unix-socket IPC, nonactivating open over origin window, auto-height.
2. Design restyle, both surfaces: search field, numbered rows, pills, selection pill, right-aligned
   meta, pin glyph, auto-height (terminal: box-drawing equivalent).
3. Tabs & Sessions view (jump + close/rename) and ⌘⇧P pins for repos/dirs; parity in terminal UI.

## Follow-ups (user feedback after first live run)

- **Smoothness gap vs resh** — DONE: 0.18 s fade + top-anchored scale-in on open, 0.12 s fade-out
  on dismiss (reopen cancels the fade), 0.14 s animated height morphs on result changes, row hover
  states. Terminal unchanged (no animation there).
- rex CLI method availability for close/rename varies by Rex version → feature-detect and hide
  actions gracefully.
- launchd env PATH must include zoxide/fd if we ever add them (not now); keep PATH filter explicit.
- Ad-hoc resign per rebuild resets TCC grants — panel needs none (CGWindowList bounds only).
- KeepAlive crash-loop: ThrottleInterval + SuccessfulExit=false matches resh; status command exists.
- KeepAlive is now `true` (always restart): a clean exit-0 used to leave the service dead and
  every open fell back to the cold Launch Services path — that's the "looks the same" incident.
  Installing from another checkout (master) silently reverts the panel; install from smoother-ui.
