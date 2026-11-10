# Raptor

Raptor is a project and session launcher for [Rex](https://www.superlogical.com/rex/docs). It uses a native SwiftUI picker on Mac and Bubble Tea on mobile. Both interfaces use the same Go search, worktree creation, and Rex action logic.

Pick a session to resume, or a directory to open in a session, tab, pane, or the current shell.

## Screenshots

The screenshots show native macOS views with synthetic data. All project names, paths, and terminal output are synthetic.

<table>
  <tr>
    <td><img width="100%" src="docs/screenshots/directories.png" alt="Native directory picker with saved paths and open targets"></td>

    <td><img width="100%" src="docs/screenshots/create-worktree.png" alt="Native Create form with branch, base, destination preview, and open target"></td>
  </tr>
</table>

- **Sessions:** One sesh-style launcher — live sessions and frecency directories from every host in a single list. The default selection is the most-recent non-current session; the current session stays identifiable and available. Enter switches or creates; Ctrl+O overrides the open target; wide terminals preview the selected session live. See [Sessions](docs/sessions.md).
- **Activity:** Compact session indicators show reported working/blocked status.
- **Pane splits:** Press Ctrl+P, then H/J/K/L or arrows. Escape cancels.
- **Create:** Search local base branches, preview the path, then create and open in one action.

[Full-size gallery and feature notes](docs/screenshots/README.md).

## Install

### Early Homebrew builds

Install the native app, terminal CLI, and Rex plugin from the current `master`:

```sh
brew install --HEAD alienxp03/tap/raptor
# Quit Raptor before upgrading:
brew upgrade --fetch-HEAD alienxp03/tap/raptor
```

The source remains private. Before installation, install `gh` and add a credential
helper scoped to this repository (existing helpers are retained):

```sh
git config --global --add credential.https://github.com/alienxp03/raptor.git.helper '!gh auth git-credential'
```

Set `HOMEBREW_GITHUB_API_TOKEN` in your shell using your secret manager or
GitHub CLI account with private-repo read access. Homebrew passes it to the Git
fetch helper; it is not written into the package. Normal Keychain-only Git login
is not sufficient inside the fetch sandbox. With that variable set, the install
and upgrade commands above work without extra flags. Do not commit tokens.

These are development builds, not stable releases. Building requires macOS 14+,
Xcode 26+, and Go 1.27.1+ (Homebrew installs Go, zoxide, Worktrunk, and gh). The formula downloads
Go modules before its offline build. Source access uses your Git credentials.

For a fresh Rex setup, append the packaged module to the Lua search path:

```lua
-- Apple Silicon; use /usr/local for standard Intel Homebrew.
package.path = package.path .. ";/opt/homebrew/opt/raptor/share/?/init.lua"
require("raptor").setup{}
rex.bind("shift+cmd+o", "raptor")
rex.bind("ctrl+n", "raptor_worktree_new")
```

Then run `rex config reload`. Existing plugin checkouts and Rex settings are
not overwritten. Update an existing checkout once to get package discovery.
The plugin prefers a detected Homebrew app/CLI pair through stable `opt` paths,
so upgrades need no config edits. Explicit `bin` and `app` options still win.
A previous `~/.local/bin/raptor` can shadow Homebrew's CLI on PATH; use
`$(brew --prefix raptor)/bin/raptor` to select the packaged CLI explicitly.

### Install from a checkout

Clone the plugin and install Raptor. Building the Mac app requires macOS 14 or later and Xcode 26+; Go and Lua are needed for development and tests.

```sh
git clone https://github.com/alienxp03/raptor ~/.config/rex/raptor
cd ~/.config/rex/raptor
make install
```

On Mac, `make install` builds and installs both `~/Applications/Raptor.app` and `~/.local/bin/raptor`. Use `make install-app` for the app only (including its internal backend), or `make install-cli` for the standalone CLI only. These commands leave the Rex plugin unchanged. On other systems, `make install` installs the CLI only.

Add setup and your own key bindings to `~/.config/rex/init.lua`:

```lua
require("raptor").setup{}
rex.bind("shift+cmd+o", "raptor")
rex.bind("ctrl+n", "raptor_worktree_new")
```

These are example bindings. Change them to keys that work for you. Raptor also adds `raptor`, `raptor_worktree_new`, `raptor_pr_open`, and `raptor_session_last` to the Rex command palette. Reload the Rex config after you change it.

The plugin uses the native app for local macOS clients and the terminal picker for iPhone/iPad or remote Mac clients. The Mac picker opens centered over the terminal window that invoked it (near its top, like a command palette) and stays warm while hidden. Escape dismisses it. The installed resident host keeps the Go backend warm across navigation; reopening supplies fresh Rex context. An event-driven Mac focus observer records recent session use, including Rex sidebar switches. See [session ordering](docs/sessions.md#recent-use-order). If the app is missing or its launch command fails, it uses the terminal picker. Force the terminal UI with `require("raptor").setup{ ui = "terminal" }`. Set `ui = "gui"` to force the server’s Mac app, including from CLI or iOS; a missing app or failed launch reports an error instead of falling back.

### Instant Pi worktree

`raptor_task_new` skips the form: generate a two-word branch such as
`otter-falcon` by pairing two words from a bundled 473-word list (cryptographically
shuffled; collisions try another pair, never a suffix), create its worktree from the origin repository's committed
HEAD, open and select a new tab, and run fresh `pi` with no initial prompt.
Uncommitted changes stay in the original worktree. This action is independent of
`ui`: Mac and iOS use the same backend flow, without opening either picker.
Pi must be installed on the server host. Missing context, a missing Pi executable,
or an unborn/non-Git repository fails before creating a worktree.

```lua
rex.bind("ctrl+shift+n", function()
  rex.invoke("raptor_task_new")
  return true
end)
```

CLI equivalent: `raptor -client CLIENT task` (session/block default to Rex's
terminal environment). `task --repo /path/to/repo` overrides repository detection.
If opening the tab fails, the error reports the preserved worktree; reuse it with
`raptor -client CLIENT task --resume /path/to/worktree`. If only switching fails,
select the already-created tab rather than creating another task. Tabs stay open
after Pi exits or fails, so startup errors remain visible.

### Experimental two-stage launcher

`raptor launcher` (Rex action `raptor_launcher`) is a terminal-only preview,
separate from the normal terminal picker and native Mac UI. Search a directory,
press Enter to choose an action, then Enter again to run it. Escape returns to
the path list without losing the search or selection. Actions respect configured
`targets`; Git repositories also offer New Worktree.
Existing direct-open and worktree shortcuts are unchanged.

For iOS onscreen modifiers, use a function binding:

```lua
rex.bind("ctrl+m", function()
  rex.invoke("raptor_launcher")
  return true
end)
```

### Local Mac package

```sh
make app                    # dist/Raptor.app, current architecture
make package                # App ZIP and SHA-256 checksum in dist/
./scripts/package-macos.sh --universal  # Intel + Apple Silicon
```

Builds are ad-hoc signed, **not Apple-notarized**. Tagged releases create a draft with a universal Mac ZIP and a prebuilt Homebrew formula; publishing the release and updating the tap are manual. Until the first stable release, use the HEAD formula in `alienxp03/tap`. Prebuilt formula installs need neither Go nor Xcode. Browser downloads can still trigger Gatekeeper. See [Mac architecture and protocol](docs/native-app.md) and [packaging instructions](packaging/macos.md).

## Last Session

```lua
rex.bind("cmd+p", "raptor_session_last")
-- Mobile:
rex.bind("ctrl+p", "raptor_session_last")
```

**Cmd+P** on Mac and **Ctrl+P** on mobile return to the last session.
`raptor_session_last` uses the shared [session-recency history](docs/sessions.md#recent-use-order),
validates the host, and skips deleted sessions. The legacy single session ID is
used only as a fallback.

## Directory picker

Use the `raptor` Rex action for the platform-appropriate UI. `raptor dirs` always opens the terminal picker. Both show live sessions and frequent directories. The current session comes first, then other sessions in recent-use order. Directory order remains based on frecency and pins.

| Key | Action |
| --- | --- |
| Type | Filter saved directory paths |
| ↑ / ↓, Ctrl+J / Ctrl+K | Move through results |
| Ctrl+O | Change the open target |
| Enter | Open the selected directory |
| Ctrl+P, then H/J/K/L or arrow | Open in a pane split |
| Ctrl+N / F2 | Open Create worktree directly for the selected Git repository |
| Esc | Clear the filter, then close the picker |

`here` changes directory only when the current pane is at a shell prompt. Session mode reuses a matching session or creates one.

## Create a worktree

Use `raptor wt --create` for the terminal form, or the `raptor_worktree_new` Rex action to open Create using the configured `ui` (`auto` prefers the local Mac app; `terminal` always uses the terminal). Both use the origin pane's repository. Bind it with `rex.bind("ctrl+n", "raptor_worktree_new")` to use it from Pi or a shell. Without a repository in the current pane, Raptor shows a repository picker. Use `wt list` for Git worktree administration.

When creation hooks are configured, New Worktree and Instant Pi Worktree also defer setup to a new terminal. Installs run visibly before Pi starts. A failed setup leaves a usable shell and a printed retry command. **Here** cannot run pending setup; choose Session, Tab, or a new pane. Repositories without creation hooks keep their existing open behavior.

Both create forms show labeled **Repo** and **Destination** paths, the branch, base, and open target. Direct Create launches render before repository metadata loads; typing and Escape stay available. Escape closes a directly launched form (or first dismisses its base chooser); forms opened from a list return to that list. The create form prefills an available two-word branch name, such as `otter-falcon`, using the same generator as Instant Pi worktree. The name stays editable. Suggesting a name creates no files or Git references. Go supplies the destination preview and validation in both interfaces. In the terminal UI, Tab moves through Branch name → Base branch → Open in → Create. Ctrl+O cycles the target from any form field. The visible **Open in** field also uses Left/Right to choose a tab, session, current shell, or pane direction (when a source pane is available). Enter on Open in moves to Create without submitting. Once the form is ready, Enter in Branch name accepts the default name, base, and target, then creates and opens the worktree. Enter on Create does the same. Git validates the name and destination again before creation.

On Mac, the `raptor_worktree_new` action opens the native form; bind it to your preferred key. Tab / Shift+Tab moves between enabled controls. Search local base branches in **From branch**; Enter selects and Escape returns to the form. Ctrl+O changes the **Open in** target. Press Enter in the branch field to use the default fields, click **Create**, or press Cmd+Enter. If opening fails after creation, **Retry opening** reuses the created worktree, never creates it again. Hiding and reopening preserves this recovery state. **Discard recovery** clears the recovery screen but keeps the worktree. Use Worktrunk directly for worktree administration.

Worktrunk (`wt`) manages creation. Its configured `worktree-path` owns destination paths; Raptor does not move existing worktrees or override the template. For example, in `~/.config/worktrunk/config.toml`:

```toml
worktree-path = "~/workspace/worktrees/{{ repo }}/{{ branch | sanitize }}"
```

With this template, `feat/login` in `raptor` uses `~/workspace/worktrees/raptor/feat-login`. The branch name stays unchanged. The old Raptor `worktree_root` setting no longer sets new worktree paths.

## Open a pull request (Mac)

While the native picker is open, press **Cmd+Shift+P**, or paste a GitHub PR URL into main search and select **Open PR #123 — owner/repo**. Both open a confirmation form; pasting alone creates nothing. A clickable **⇧⌘P PR** footer hint opens the same form. There is no terminal PR form.

Use a full GitHub URL in the native form. Query strings, fragments, and PR tabs are normalized away; bare numbers are rejected. An empty form prefills a valid GitHub PR URL from the clipboard. Raptor reuses a matching local clone or clones the base repository into `~/workspace/<owner>/<repo>`, then uses Worktrunk to create or reuse the PR worktree. Fork PRs keep their branch names. Closed or merged PRs with deleted branches offer **Check out PR commit…** with confirmation; this uses isolated local branch `pr/N`, without restoring or pushing the deleted branch. Occupied paths and branch conflicts are not overwritten.

The form opens a Session (default) or Tab. New destination labels use `<repo>-pr-<number>-<branch>`, with branch slashes replaced by hyphens; for example `aurora-pr-10990-fix-cancellation-page-back-navigation`. Worktree paths stay under Worktrunk's control. Reopening the same PR with the same target reuses its worktree and recorded Rex destination; completed setup does not run again. A concurrent operation reports busy instead of creating duplicates. Existing destination labels are not renamed.

Setup runs there with visible output and normal Worktrunk approval prompts. Setup failure keeps the worktree and terminal available; use the printed retry command after fixing the error. Reopening an existing worktree does not repeat creation setup. If opening fails, retry opening the preserved worktree rather than creating another one.

The Rex command palette action **`raptor_pr_open`** opens the native form directly. Add an optional binding:

```lua
rex.bind("shift+cmd+p", "raptor_pr_open")
```

This binding is optional; Raptor does not install global bindings. The action reports an error when the native Mac app is unavailable. Authenticate GitHub CLI on the server host with `gh auth login`.

Safety limits: repositories with `pre-switch` hooks need an interactive Worktrunk switch first. Changed source/destination hook configuration stops deferred setup rather than changing its meaning. Background service hooks remain Worktrunk-managed; inspect `wt config state logs` if one fails. Raptor never auto-approves project hooks.

## Open targets

On Mac, use Ctrl+O / Ctrl+Shift+O or the **Open in** dropdown. In the terminal picker, use Ctrl+O. In the create form, Tab / Shift+Tab move between fields; on Mac they keep normal focus navigation. The default target list is:

| Target | Opens the worktree or directory… |
| --- | --- |
| `session` | In a matching or new session |
| `tab` | In a new tab |
| `here` | In the current shell |
| `pane_right`, `pane_below` | In a pane split |

The default order is session → tab → cd here → pane right → pane below. Ctrl+P also opens the selected item in a pane split; choose the direction with H/J/K/L or arrow keys.

## Configuration

All settings are optional. Save them in `~/.config/raptor/config.toml`:

```toml
enter = "tab"
targets = ["session", "tab", "here", "pane_right", "pane_below"]
```

| Setting | Default | Purpose |
| --- | --- | --- |
| `worktree_root` | Legacy | Ignored for new paths; configure Worktrunk `worktree-path` instead |
| `enter` | `tab` | Target selected when a picker opens |
| `targets` | `session`, `tab`, `here`, `pane_right`, `pane_below` | Available open targets |

The Rex plugin also accepts UI selection and terminal popup settings:

```lua
require("raptor").setup{
  ui = "auto", -- Or "terminal" / "gui" (force the server’s Mac app).
  -- app = "/custom/path/Raptor.app",
  bounds = { x = 0.28, y = 0.14, w = 0.44, h = 0.40 },
  mobile_bounds = { x = 0.04, y = 0.10, w = 0.92, h = 0.78 },
  -- bin = "/custom/path/raptor", -- Only for an intentional override.
}
```

For a direct open without the picker:

```sh
rex do raptor target=tab dir=/path/to/project
```

## Requirements and development

Raptor needs Rex, Git, zoxide, and Worktrunk (`wt`, tested with 0.81.0). PR opening also needs authenticated GitHub CLI (`gh`). Go builds both interfaces' backend. The Mac UI also requires Swift/Xcode tools to build; end users of the packaged app do not need build tools.

```sh
make              # Build ./raptor (terminal CLI)
make install      # Mac app + CLI on macOS; CLI elsewhere
make install-app  # Mac app only, including its internal backend
make install-cli  # Standalone CLI only
make test         # Go and Lua checks
make test-macos   # Swift 6 model/transport checks and UI type-check
```
