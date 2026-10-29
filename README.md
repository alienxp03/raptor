# Raptor

A compact directory and worktree picker for [Rex](https://www.superlogical.com/rex/docs), built with Go and Bubble Tea.

## Directory picker

`raptor dirs` searches your zoxide directories. A single-column list shows home-relative paths, with a soft selection highlight. Long paths shorten on the left to keep the destination visible. Long queries scroll to keep the cursor visible.

- Type to fuzzy-filter; arrows or Ctrl+J/K navigate.
- Tab / Shift+Tab cycle the target: tab, cd here, or session.
- Ctrl+P enters split mode. Then h/j/k/l or Left/Down/Up/Right opens the selected directory in that direction, relative to the origin pane. Esc cancels split mode without clearing the query. Outside split mode, letters search and arrows navigate. No Alt or Shift direction shortcuts.
- Enter opens the selection. Session mode reuses a matching session label or creates one.
- Ctrl+W on a git repository opens its worktrees; returning resumes your directory query, selection, and opening target.
- Esc clears the query, then closes the picker.

`here` only sends a cd command when the origin pane's foreground process is a shell.

## Worktree picker

`raptor wt --repo /path/to/repo` shows local worktrees only: branch name and path, without status badges or GitHub requests. Without `--repo`, it detects the repository from the origin pane, falling back to a repository picker.

- Branches and paths use two columns; paths start at a fixed position near the middle. Long paths shorten on the left, not the folder end. Narrow panes show branches only.
- The selected path uses the full width below the list, wrapping across up to three rows when space allows.
- Type to search branches and paths; arrows or Ctrl+J/K navigate.
- Enter opens an existing worktree as a session.
- Ctrl+N (or F2) opens the creation form: branch name, local base branch, and a live full destination path preview.
- Tab / Shift+Tab move between Branch name, Base branch, and the explicit Create & open button.
- Enter advances from the branch name, opens the searchable local-base chooser from Base branch, and only submits when Create & open is focused.
- Esc backs out of the base chooser to the form, or cancels the form without changing the worktree list query/selection.
- Ctrl+X (or Delete) offers worktree removal with confirmation. The branch is kept; Git refuses uncommitted changes and locked worktrees. The primary worktree cannot be removed.
- Esc clears the query, then returns to directories.

Worktrees live under `<worktree_root>/<primary-repo>/<folder>`. Branch `feat/login` becomes folder `feature-login`; other slashes become hyphens (`fix/crash` → `fix-crash`, `chore/deps` → `chore-deps`). The branch name is preserved. Existing branches/destinations and invalid names are rejected with errors in the form.

## Rex integration

Install the Rex plugin and Go binary:

```sh
git clone https://github.com/alienxp03/raptor ~/.config/rex/raptor
cd ~/.config/rex/raptor && make install
```

Keep the Rex config small. Setup registers actions; choose and change key bindings in your own `~/.config/rex/init.lua`:

```lua
require("raptor").setup{}
rex.bind("shift+cmd+o", "raptor")
rex.bind("shift+ctrl+w", "raptor_wt")
```

Change either binding to any key you prefer. The actions are also available in Rex's command palette. Run `rex config reload` after changing the config.

Optional setup settings override popup bounds or the binary path:

```lua
require("raptor").setup{
  bounds = { x = 0.28, y = 0.14, w = 0.44, h = 0.40 },
  mobile_bounds = { x = 0.04, y = 0.10, w = 0.92, h = 0.78 },
  bin = os.getenv("HOME") .. "/.local/bin/raptor",
}
```

Direct mode: `rex do raptor target=tab dir=/path/to/project`.

## Configuration

Optional `~/.config/raptor/config.toml`:

```toml
worktree_root = "~/Workspace/worktrees"
slug_len = 24
enter = "tab"
targets = ["tab", "here", "session"]
```

Custom target lists can still include `pane` (right), `pane_left`, `pane_above`, and `pane_below`.

Last-session state lives at `$XDG_CACHE_HOME/rex/raptor-last` (default `~/.cache/rex/raptor-last`).

## Build

```sh
make          # ./raptor
make install  # ~/.local/bin/raptor
go test ./...
```

Requires `rex`, `zoxide`, and `git`. Development version stays **0.0.1**.
