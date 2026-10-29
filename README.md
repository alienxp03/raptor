# Raptor

Raptor is a directory and Git worktree picker for [Rex](https://www.superlogical.com/rex/docs). It uses Go and Bubble Tea.

Pick a saved directory or worktree, then open it in a tab, session, pane, or the current shell.

## Screenshots

Screenshots show Raptor over an illustrative Rex workspace. Project names, paths, and terminal output are synthetic.

<table>
  <tr>
    <td><img width="100%" src="docs/screenshots/directories.png" alt="Directory picker over a synthetic Rex workspace"></td>
    <td><img width="100%" src="docs/screenshots/worktrees.png" alt="Worktree picker with synthetic branches"></td>
  </tr>
  <tr>
    <td><img width="100%" src="docs/screenshots/split-mode.png" alt="Pane split mode over a synthetic Rex workspace"></td>
    <td><img width="100%" src="docs/screenshots/create-worktree.png" alt="Create-worktree form with synthetic data"></td>
  </tr>
</table>

## Install

Clone the plugin and install the Go binary:

```sh
git clone https://github.com/alienxp03/raptor ~/.config/rex/raptor
cd ~/.config/rex/raptor
make install
```

Add setup and your own key bindings to `~/.config/rex/init.lua`:

```lua
require("raptor").setup{}
rex.bind("shift+cmd+o", "raptor")
rex.bind("shift+cmd+t", "raptor_wt")
```

These are example bindings. Change them to keys that work for you. Raptor also adds `raptor`, `raptor_wt`, and `raptor_last` to the Rex command palette. Reload the Rex config after you change it.

## Directory picker

Run `raptor dirs` from a Rex session, or use the `raptor` action.

| Key | Action |
| --- | --- |
| Type | Filter saved directories and sessions |
| ↑ / ↓, Ctrl+J / Ctrl+K | Move through results |
| Tab / Shift+Tab | Change the open target |
| Enter | Open the selected result |
| Ctrl+P, then H/J/K/L or arrow | Open in a pane split |
| Ctrl+T | Open worktrees for the selected Git repository |
| Esc | Clear the filter, then close the picker |

`here` changes directory only when the current pane is at a shell prompt. Session mode reuses a matching session or creates one.

## Worktree picker

Run `raptor wt` to use the current Git repository. Use `raptor wt --repo /path/to/repo` to choose a repository directly. Without a repository in the current pane, Raptor shows a repository picker.

| Key | Action |
| --- | --- |
| Type | Filter worktree branches and paths |
| ↑ / ↓, Ctrl+J / Ctrl+K | Move through worktrees |
| Tab / Shift+Tab | Change the open target |
| Enter | Open the selected worktree with that target |
| Ctrl+P, then H/J/K/L or arrow | Open in a pane split |
| Ctrl+N or F2 | Create a worktree |
| Ctrl+X or Delete | Remove a worktree after confirmation |
| Esc | Clear the filter, then return to directories |

The create form asks for a branch and local base branch. It shows the destination before you create the worktree. Tab moves between fields; Enter selects the base or creates the worktree when the create button is selected. New worktrees open with the target selected in the picker.

Raptor lists local worktrees only. It keeps the branch when you remove a worktree. Git blocks removal when the worktree has uncommitted changes or is locked. You cannot remove the primary worktree.

Worktrees use this layout:

```text
<worktree_root>/<primary-repo>/<branch-folder>
```

`feat/login` becomes `feature-login`; other slashes become hyphens. Leading dots are removed from the primary repository name so the folder is not hidden. The Git branch name does not change.

## Open targets

Use Tab / Shift+Tab to cycle through the configured targets. The default list is:

| Target | Opens the worktree or directory… |
| --- | --- |
| `tab` | In a new tab |
| `here` | In the current shell |
| `session` | In a matching or new session |
| `pane`, `pane_left`, `pane_above`, `pane_below` | In a pane split |

Pane targets can be added to the target list. Ctrl+P also opens the selected item in a pane split; choose the direction with H/J/K/L or arrow keys.

## Configuration

All settings are optional. Save them in `~/.config/raptor/config.toml`:

```toml
worktree_root = "~/Workspace/worktrees"
enter = "tab"
targets = ["tab", "here", "session"]
```

| Setting | Default | Purpose |
| --- | --- | --- |
| `worktree_root` | `~/Workspace/worktrees` | Parent folder for new worktrees |
| `enter` | `tab` | Target selected when a picker opens |
| `targets` | `tab`, `here`, `session` | Targets cycled by Tab / Shift+Tab |

The Rex plugin also accepts optional popup settings:

```lua
require("raptor").setup{
  bounds = { x = 0.28, y = 0.14, w = 0.44, h = 0.40 },
  mobile_bounds = { x = 0.04, y = 0.10, w = 0.92, h = 0.78 },
  bin = os.getenv("HOME") .. "/.local/bin/raptor",
}
```

For a direct open without the picker:

```sh
rex do raptor target=tab dir=/path/to/project
```

## Requirements and development

Raptor needs Rex, Git, and zoxide. Go is needed to build it.

```sh
make          # Build ./raptor
make install  # Install ~/.local/bin/raptor
go test ./...
```
