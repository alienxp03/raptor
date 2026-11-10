# Native Mac app

Raptor has two interfaces and one Go implementation of picker behavior:

```text
macOS Rex action -> Raptor.app (SwiftUI) -> bundled raptor api
mobile Rex action --------------------> raptor sessions / wt --create (Bubble Tea)
                                             |
                        shared Go catalog, worktree, dispatch, Rex history
```

The Mac app is a separate floating window, not a Rex-rendered popup. It requires macOS 14 or later. The picker opens 72 points below the active screen's usable top edge and grows downward as results change.

The installed resident host keeps the panel, model, and Go backend warm between uses. Escape or Cmd+Q hides the resident panel and stops its live Rex subscription. Use `raptor service stop` to stop the resident host. Each reopening supplies fresh Rex context. A live mutation or removal confirmation cannot have its context replaced.

## UI selection

The Rex plugin checks the requesting client's platform. With `ui = "auto"`, a local macOS client uses an installed app. iOS, iPadOS, and remotely connected Mac clients use the terminal picker. The plugin requires a local Unix-socket app client before it launches an app on the server machine. In auto mode, CLI clients always use the terminal picker: their platform describes the server executing the CLI, not the device viewing the terminal. This also prevents a CLI invoked from an iPhone from opening the Mac app when Rex supplies the CLI's identity to a registered action. A missing app or failed launch command falls back to the terminal picker. Launch Services delivers a validated `raptor://picker` URL to the existing app instead of starting another instance. URLs contain picker context only, never an action to run automatically. If the app crashes after macOS accepts the launch, the plugin cannot detect that failure; use the terminal override while investigating it.

```lua
require("raptor").setup{
  ui = "auto", -- Or "terminal"; "gui" forces the server’s Mac app.
  -- app = "/custom/path/Raptor.app",
}
```

Set `ui = "gui"` to force the Mac app on the server, regardless of the invoking client (including CLI and iOS). This does not open an app on the iPhone. If the app is missing or cannot be launched, the action fails instead of opening a terminal picker.

The launcher (`raptor`) and `raptor_worktree_new` use this setting. `raptor_worktree_new` sends `mode=wt-create` to the native app or runs `raptor wt --create` in the terminal. It only opens a form; it never creates a worktree without confirmation.

`raptor_pr_open` is Mac-only. It sends `mode=pr` and opens the PR form without executing it. There is no terminal fallback for this action. Inside the native picker, Cmd+Shift+P opens the same form. Pasting a GitHub PR URL into main search adds a selectable action; it does not create resources until form confirmation. A clickable `⇧⌘P PR` footer hint makes the shortcut visible in the launcher.

Normal installations run `raptor init`, which writes one managed block loading the packaged plugin by stable opt path; no `bin`/`app` options. The plugin pairs the CLI and app from the same Homebrew installation through stable `opt/raptor` paths. For standalone apps installed elsewhere, Launch Services can resolve bundle ID `com.alienxp03.raptor`; no disk scan or fixed Applications directory is required. Explicit paths remain optional overrides. Your bindings remain in your Rex `init.lua`; the installer does not change them.

## Reopening and performance

The plugin skips the terminal-title lookup for the native UI. The resident app keeps its panel and backend warm while hidden. A new request supplies session, pane, and client IDs. Cached rows appear before revalidation; context-bound actions remain gated until the new context is ready. Empty-query opens and warm reopens select the most-recent non-current session, or a directory when no other session exists. Go returns `selected_id`; manual selection stays stable during live updates. Successful session navigation and dispatch hide the resident panel without closing its backend. This avoids a new process and catalog scan on the next opening.

While visible, the panel receives native Rex events through Go. Status changes update rows without reopening or resetting selection, scroll, search, or target. Search filters Go's in-memory catalog, not a new Rex scan. A live refresh runs separately and publishes its completed snapshot. Typing retains the current rows until matching results arrive; actions on an older query stay gated. Subscription cleanup and reconnect recovery are separate from dot animation. See [Rex API integration](rex-api.md).

Local measurements from the launch command to a visible window were about 125–140 ms for warm reopens versus 230–280 ms for fresh processes. Populated results took about 170–180 ms warm. These are local measurements, not timing guarantees; the first launch after installation can take longer.

`make install` stops the resident host before replacing the bundle, then restarts it. Before a manual bundle replacement, run `raptor service stop`; Cmd+Q only hides a resident picker. Restart it with `raptor service start`.

## Shared logic

The **Open in** control uses the shared target order: session → tab → cd here → pane right → pane below. Configured target lists are respected by both interfaces; cd/pane targets require an origin pane. Ctrl+O cycles the choices; Ctrl+Shift+O cycles backward. The dropdown also supports pointer selection. Tab / Shift+Tab moves keyboard focus, not the open target. Ctrl+P remains the pane-split shortcut.

Home-directory labels use `~/…`; tooltips and backend requests retain the full absolute paths. Paths outside the current home directory stay absolute.

Swift draws the UI, manages keyboard focus, and displays confirmations. It does not calculate worktree names, validate branches, run Git, or dispatch Rex actions. Those operations use the same Go packages as Bubble Tea:

- `internal/catalog`: directory/repository discovery, fuzzy matching, worktree data.
- `internal/worktree`: destination paths, validation, creation, safe removal.
- `internal/dispatch`: open targets and previous-location recording.
- `internal/rex`: Rex commands and history.

The native `--demo` launch option uses synthetic fixtures for visual checks. Demo mode does not call Rex, create real worktrees, or replace the production backend.

## Local backend protocol

The app starts the bundled `Contents/MacOS/raptor-cli` executable with the originating Rex context and the `api` command. Requests and responses are newline-delimited JSON over stdin/stdout. No port is opened.

```json
{"id":1,"method":"directories","params":{"query":"demo"}}
{"id":1,"result":{"items":[{"path":"/demo/project","label":"project"}],"targets":["session","tab","here","pane_right","pane_below"],"target":"tab"}}
```

Errors have an `error` string instead of `result`. IDs identify requests; they do not identify directories or worktrees. Paths returned by Go identify selectable entries.

| Method | Parameters | Result |
| --- | --- | --- |
| `sessions` | `query` | Unified session/directory items, hosts, targets, and preferred `selected_id` |
| `directories` | `query`, `repos_only` | Directory or repository items and open targets |
| `worktrees.list` | `repo`, `query` | Internal creation metadata: local base branches, current base, targets; `needs_repo` if origin has no repository. No browser UI is exposed |
| `worktrees.branches` | `repo`, `query` | Local base branches ranked by the shared Go fuzzy search; no network access |
| `worktrees.preview` | `repo`, `branch`, `base` | Destination `path` and `validation_error` |
| `worktrees.create` | `repo`, `branch`, `base` | Created `path`; does not open it automatically |
| `pullrequests.resolve` | `repo`, `input` | Read-only PR metadata, clone location, existing/predicted worktree path |
| `pullrequests.prepare` | `repo`, `input` | Clone/reuse repository and create/reuse PR worktree with setup deferred |
| `pullrequests.open` | `path`, `target` (`session`/`tab`) | Open/select destination and release visible setup; retain returned IDs/path on error |
| `dispatch` | `target`, `path` | Outcome fields (`path`/IDs) after the Rex dispatch, plus `launcher_items` when available |
| `sessions.create` | `host`, `dir` | `session_id`, `existing`, selection `error?`, and `launcher_items` when available |
| `theme` | none | Active Rex theme palette; `error` string when resolution fails |

Mutation responses may carry `launcher_items`: an authoritative unfiltered snapshot that covers the created session, included only when a snapshot already exists. The native app publishes it before hiding so the next open shows the new session instantly. A persisted creation journal overlays warm caches until a completed post-creation scan supersedes it (two-minute bound); only Rex-returned identities are recorded, never labels or failed creates.

The native **Create** button sends creation followed by dispatch. These remain separate backend operations: the app records the created path before opening it. If opening fails, **Retry opening** dispatches that existing path without creating again. A timeout during creation can leave the outcome unknown; check the worktree list before trying creation again.

PR preparation and opening are separate mutations. Partial failures can return a result containing `path` and `error`; the native form preserves this recovery path. Setup uses a durable journal under the Raptor state directory. It runs after the destination terminal starts and selection is requested, not after an assumed visual-focus acknowledgement. Empty hook phases advance silently; configured hooks run with their real output, and long-lived post hooks remain background jobs with Worktrunk logs. Approval prompts are never auto-accepted. Setup failure keeps a usable shell and prints the retry command.

Worktrunk owns all new worktree destinations. Raptor's legacy `worktree_root` does not override Worktrunk configuration. Existing creation interfaces stay available, including the terminal UI; the new PR form is native-only.

## Rex theme colors

Both interfaces take their colors from the active Rex theme instead of hardcoding them. The Go resolver reads `Workspace.appearance`, `Workspace.interfaceStyle`, `Workspace.darkThemeID`/`Workspace.lightThemeID`, and `Workspace.customThemes` from the `com.superlogical.rex` preferences, then looks the theme up in the Rex app bundle's `SuperUI_SuperDesignTokens` catalog. Tinted interface styles (`blendTheme`, `useTheme`) fall back to built-in colors, as does any resolution failure. The terminal picker applies the resolved ANSI palette on startup; the native app requests the same palette over the `theme` method and repaints.

Set `RAPTOR_THEME=ansi` to force the built-in palette (tests do this for deterministic output), and `RAPTOR_REX_APP` to point at a Rex installation outside the standard `/Applications` and `~/Applications` paths.

The creation form labels the source **Repo** and new **Destination** paths, with branch, searchable local base branch, and open target fields. Direct `wt-create` launches display the form before metadata loads. Escape closes a directly opened form; it returns to the parent list for a form opened from that list. A base-branch popover is dismissed first. Branch matching and validation run in Go. An untouched branch field shows guidance, not a validation error. Tab / Shift+Tab skips disabled controls; Cmd+Enter submits. The branch popover owns its keyboard events: Enter selects, Escape closes it and restores form focus; neither submits nor closes the form beneath it.

## Releases

Local builds use ad-hoc code signing. This checks bundle integrity but is not Developer ID signing or Apple notarization. A public download should use a Developer ID certificate and notarization before distribution. Release packaging and the Homebrew formula do not publish a release or update the tap automatically.
