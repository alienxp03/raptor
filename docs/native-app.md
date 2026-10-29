# Native Mac app

Raptor has two interfaces and one Go implementation of picker behavior:

```text
macOS Rex action -> Raptor.app (SwiftUI) -> bundled raptor api
mobile Rex action --------------------> raptor dirs / wt (Bubble Tea)
                                             |
                        shared Go catalog, worktree, dispatch, Rex history
```

The Mac app is a separate floating window, not a Rex-rendered popup. It requires macOS 14 or later. The picker opens 72 points below the active screen's usable top edge and grows downward as results change.

The Mac UI stays warm between uses. Escape hides the window and closes that picker's Go child; Cmd+Q quits the app completely. No focus watcher, login item, or network service runs. Each reopening creates a new model and Go backend with fresh Rex context; a live mutation or removal confirmation cannot have its context replaced.

## UI selection

The Rex plugin checks the requesting client's platform. With `ui = "auto"`, a local macOS client uses an installed app. iOS, iPadOS, and remotely connected Mac clients use the terminal picker. The plugin requires a local Unix-socket client before it launches an app on the server machine. A missing app or failed launch command falls back to the terminal picker. Launch Services delivers a validated `raptor://picker` URL to the existing app instead of starting another instance. URLs contain picker context only, never an action to run automatically. If the app crashes after macOS accepts the launch, the plugin cannot detect that failure; use the terminal override while investigating it.

```lua
require("raptor").setup{
  ui = "auto", -- Or "terminal" on every platform.
  -- app = "/custom/path/Raptor.app",
}
```

Without an explicit app path, the plugin checks `~/Applications/Raptor.app` and `/Applications/Raptor.app`. Your bindings remain in your Rex `init.lua`. The installer does not change those bindings.

## Reopening and performance

The plugin skips the terminal-title lookup for the native UI. The app keeps its window and SwiftUI runtime warm, but stops Go while hidden. A new request supplies session, pane, and client IDs; those IDs are never reused from a previous invocation. Search text, form state, and backend connection reset on reopening.

Local measurements from the launch command to a visible window were about 125–140 ms for warm reopens versus 230–280 ms for fresh processes. Populated results took about 170–180 ms warm. These are local measurements, not timing guarantees; the first launch after installation can take longer.

Quit the app before replacing an installed bundle. The build/installer refuses to replace a running copy. Open the picker and press Cmd+Q, then retry.

## Shared logic

The footer's **Open in:** dropdown names the destination explicitly: **New tab**, **Session**, or **Current shell**. Ctrl+O cycles the choices; Ctrl+Shift+O cycles backward. The dropdown also supports pointer selection. Tab / Shift+Tab moves keyboard focus, not the open target. Ctrl+P remains the pane-split shortcut.

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
{"id":1,"result":{"items":[{"path":"/demo/project","label":"project"}],"targets":["tab","here","session"],"target":"tab"}}
```

Errors have an `error` string instead of `result`. IDs identify requests; they do not identify directories or worktrees. Paths returned by Go identify selectable entries.

| Method | Parameters | Result |
| --- | --- | --- |
| `directories` | `query`, `repos_only` | Directory or repository items and open targets |
| `worktrees.list` | `repo`, `query` | Worktrees, local base branches, current base, targets; `needs_repo` if origin has no repository |
| `worktrees.branches` | `repo`, `query` | Local base branches ranked by the shared Go fuzzy search; no network access |
| `worktrees.preview` | `repo`, `branch`, `base` | Destination `path` and `validation_error` |
| `worktrees.create` | `repo`, `branch`, `base` | Created `path`; does not open it automatically |
| `worktrees.remove` | `repo`, `path` | Empty result after safe Git removal; branch retained |
| `dispatch` | `target`, `path` | Empty result after the existing Rex dispatch |

The native **Create** button sends creation followed by dispatch. These remain separate backend operations: the app records the created path before opening it. If opening fails, **Retry opening** dispatches that existing path without creating again. A timeout during creation can leave the outcome unknown; check the worktree list before trying creation again.

The creation form has a branch field, searchable local **From branch** picker, read-only destination preview, and open target. Branch matching and validation run in Go. An untouched branch field shows guidance, not a validation error. Tab / Shift+Tab skips disabled controls; Cmd+Enter submits. The branch popover owns its keyboard events: Enter selects, Escape closes it and restores form focus; neither submits nor closes the form beneath it.

## Releases

Local builds use ad-hoc code signing. This checks bundle integrity but is not Developer ID signing or Apple notarization. A public download should use a Developer ID certificate and notarization before distribution. Release packaging and the Homebrew cask template do not publish a release or create a tap.
