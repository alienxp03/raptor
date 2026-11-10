# Smoother UI — finalized plan

Decisions and rationale live in `docs/resh-notes.md`. This is the implementation spec.
Reference clone of resh: re-clone `https://github.com/CruelAddict/resh` if the tmp path is gone.

## 1 · Goals

1. Open the picker with **zero flicker and zero focus steal** on macOS (resh parity).
2. One design language across the Mac panel and terminal picker (pills, numbered rows, meta).
3. New capabilities: **Tabs & Sessions view** (jump + close/rename), **⌘1–9** direct open,
   **⌘⇧P pins** for repos/dirs.

## 2 · Non-goals

- No Recents (zoxide) view, no global worktree view, no Projects files.
- No notarization changes — brew/`make install` paths don't trigger Gatekeeper (no quarantine).
- Terminal pane spawn can't be fully flicker-free; we minimize, not eliminate.

## 3 · As-is (root causes of the flicker)

| Path | Today | Problem |
|---|---|---|
| Mac (`ui=auto`, local macos client) | `open -g -a Raptor.app raptor://picker?…` → Apple event → `ProcessBackend` spawns `raptor-cli` child per session → `NSApp.activate(ignoringOtherApps:)` + `makeKeyAndOrderFront` | cold app+backend spawn; activation yanks focus from Rex = visible flash |
| Terminal | `open_layer` → new Rex layer + shell block runs `raptor` bubbletea | layer + process spawn + first paint |

Key files: `init.lua`, `macos/Sources/Raptor/{RaptorApp,Backend,PickerRequest}.swift`,
`internal/picker/*`, `internal/api/api.go` (NDJSON backend), `internal/rex/rex.go`.

## 4 · Target architecture — resident host (Mac)

### 4.1 Process model (mirrors resh `ServiceLauncher.swift`)

- `Raptor serve` mode inside the existing app binary: AppKit host, no UI at launch, LSUIElement.
- launchd **gui-domain job** (no LaunchAgents file): plist at
  `~/Library/Caches/raptor/launcher.plist`, label `com.alienxp03.raptor.panel`,
  `KeepAlive={SuccessfulExit:false}`, `ThrottleInterval:2`, filtered env (`PATH`, `XDG_CONFIG_HOME`,
  `RAPTOR_*`). Install/manage via `raptor service install|start|stop|restart|status`.
- Single instance enforced by socket bind (stale-socket takeover), plus file lock around install
  (pattern: resh `FileLock` + `CFMessagePortCreateRemote` check).
- `make install` / brew postflight install + start the service; uninstall stops and removes.

### 4.2 IPC

- Unix socket `~/Library/Caches/raptor/panel.sock` (0600, dir 0700).
- New Go CLI entry: `raptor panel open --session S --block B --client C --title T --mode M` →
  one JSON request line → host replies `ok` after `orderFront` (or `err`). 1s timeout.
- Fallbacks: socket miss → launchd kickstart → `open -g -a Raptor.app raptor://picker?…` (URL path
  stays as-is for compatibility). `init.lua` uses CLI-first, fallback chain behind it.
- Demo/`--demo` path unchanged (`DemoBackend`).

### 4.3 Panel behavior (PanelController-equivalent in RaptorApp.swift)

- Panel **pre-created once**; open never resets model/catalog; `orderFront` **without**
  `NSApp.activate` (drop the focus yank; panel is already `.nonactivatingPanel`).
- Position over origin Rex window: CGWindowList frame by Rex PID (already read today), anchor with
  auto-height = search + pills + min(results, cap 9) rows; reposition on screen change.
- Refresh on open, stale-first: show last catalog instantly, `session.list` + repos refresh lands
  in-place (no blank frame, no spinner gate).
- Backend child (`raptor-cli` NDJSON) started with host, kept alive, re-used across opens; on child
  exit → respawn once, else surface error inline. Per-open context (`--session/--block/--client`)
  sent as a `context` request, not a process restart.

## 5 · UI spec (both surfaces)

Shared layout top→bottom: **search field · view pills · result rows · footer hints**.

- **Pills**: `Repos` · `Tabs & Sessions`. Mac: clickable; both: `Tab`/`Shift-Tab` cycle. Active pill
  rendered like resh (filled pill), inactive muted. Terminal: box-drawing pill equivalents from the
  shared palette (`25c6c02`).
- **Rows**: number badge (`⌘1`–`⌘9` mac / `alt-1`–`alt-9` terminal), title, optional status dot,
  right-aligned muted meta, pin glyph column. Selection = accent pill row (existing accent).
- **Repos view** = current flow unchanged underneath: filter → pick dir → targets (session/tab/
  splits/here) → worktree browse/create (per-repo). Pins float to top with glyph.
- **Tabs & Sessions view**: entries from `rex api call session.list` (+ labels via existing
  `rex.Sessions()` helpers); meta shows session context / host. `Enter` = jump
  (`rex.SelectSession` / `client.perform session.select` pattern from `internal/dispatch`).
  Secondary: close tab/session (rex API, resh `⌘⇧D` precedent), rename (session.rename). Jump keeps
  `history.SelectSession` last-session bookkeeping.
- **Pins**: `⌘⇧P` (mac) / `ctrl-p` (terminal) on a repo row toggles pin; persisted in raptor config
  (`internal/config`, new `pins = ["path", …]`), matched by canonical path.

## 6 · init.lua changes

- `show_picker` gui branch: run `cfg.bin panel open …` via `rex.exec`; on failure fall back to
  existing `open -g -a` URL flow; terminal/ios/ssh paths unchanged (keep `cfg.bounds` for the
  terminal layer path only).
- Keep key bindings and action names (`raptor`, `raptor_worktree_new`) stable.

## 7 · Testing & validation

- Go: IPC client (socket roundtrip, timeout, fallback), pins config roundtrip, tabs-view data
  shaping + filtering, `panel` subcommand arg parsing. Existing `make test` + lua routing tests
  extended for the gui-branch CLI-first order.
- macOS (`make test-macos`): serve-mode boot with `DemoBackend`; open-without-activation
  (assert no `activate` call); auto-height arithmetic (extend `PickerStyle` checks incl. pills row);
  panel-reuse (second open keeps state); backend respawn logic.
- Parity checklist per AGENTS.md: routing, targets, order, shortcuts identical in both UIs;
  run `make test` + `make test-macos`; finish with `make install` (rebuilds app + bundled CLI).

## 8 · Implementation order (each step shippable)

1. **Resident host + IPC** (§4): serve mode, launchd, socket, CLI `panel open`, no-activation open,
   auto-height, stale-first refresh. Flicker gone here.
2. **Restyle both UIs** (§5 layout): pills, numbered rows, meta column, footer (no new data yet).
3. **Tabs & Sessions view + pins + ⌘1–9 wiring** (§5 capabilities), terminal parity throughout.

## 9 · Risks / notes

- rex CLI method availability for close/rename varies by Rex version → feature-detect
  (`rex api call …` error) and hide actions gracefully.
- launchd env PATH must include zoxide/fd if we ever add them (not now); keep PATH filter explicit.
- Ad-hoc resign per rebuild resets TCC grants — our panel needs none (CGWindowList bounds only).
- KeepAlive crash-loop: ThrottleInterval + SuccessfulExit=false matches resh; add status command.

---

## Status: implemented (verified e2e 2026-11-01)

All three phases shipped and installed (`make install` = app + bundled CLI + resident service).

Verified live: IPC open (8–35 ms round-trip, vs ~1 s cold spawn before), zero focus steal
(nonactivating panel over Rex, typing reaches the panel while Rex stays frontmost), ⌘S-style
toggle on repeated open, Repos ⇥ Tabs view switch by keyboard, live Tabs & Sessions list from
`session.list`+`session.view`, Enter-jump switched Rex's active window (verified via
`session.view` active_window_id), close/rename/pins via API + config persistence, terminal pills/
numbered rows/tabs view in a pty. Tests: 12 Go/lua suites, 6 Swift check groups green.

Resident footprint: host app ≈103 MB RSS + Go backend ≈11 MB.

Known follow-up (user-requested, see resh-notes.md): open/close animation + transition polish to
match resh's feel; terminal tabs load blocks Update ~100–600 ms (async-load later).
