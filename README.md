# Raptor

A compact directory and worktree picker for [Rex](https://www.superlogical.com/rex/docs), built with Go and Bubble Tea.

## Directory picker

`raptor dirs` searches your zoxide directories. Paths use `~`, with a soft selection highlight and no preview.

- Type to fuzzy-filter; arrows or Ctrl+J/K navigate.
- Tab / Shift+Tab cycle the target: session, tab, pane right, pane below, or cd here.
- Enter opens the selection. Session mode reuses a matching session label or creates one.
- Ctrl+W on a git repository opens its worktrees.
- Esc clears the query, then closes the picker.

`here` only sends a cd command when the origin pane's foreground process is a shell.

## Worktree picker

`raptor wt --repo /path/to/repo` shows local worktrees only: branch name and path, without status badges or GitHub requests. Without `--repo`, it detects the repository from the origin pane, falling back to a repository picker.

- Type to search branches and paths; arrows or Ctrl+J/K navigate.
- Enter opens an existing worktree as a session.
- Ctrl+N (or F2) opens the creation form: branch name, local base branch, and a live full destination path preview.
- Tab switches fields; arrows choose a base branch. Enter creates and opens; Esc cancels.
- Ctrl+D (or Delete) offers worktree removal with confirmation. The branch is kept; Git refuses uncommitted changes and locked worktrees. The primary worktree cannot be removed.
- Esc clears the query, then returns to directories.

Worktrees live under `<worktree_root>/<primary-repo>/<folder>`. Branch `feat/login` becomes folder `feature-login`; other slashes become hyphens (`fix/crash` → `fix-crash`, `chore/deps` → `chore-deps`). The branch name is preserved. Existing branches/destinations and invalid names are rejected with errors in the form.

## Rex integration

Copy `rex/raptor.lua` to `~/.config/rex/raptor.lua`, then add `require("raptor")` to `init.lua` and run `rex config reload`.

- **Cmd+Shift+P** / **Raptor**: directory picker.
- **Ctrl+Shift+W** / **Raptor Worktrees**: worktree picker.
- **Raptor: Last Session**: toggle between sessions switched through the picker.

Direct mode: `rex do raptor target=tab dir=/path/to/project`.

The Lua wrapper opens a focused floating terminal layer. Its binary path and popup bounds are configurable there.

## Configuration

Optional `~/.config/raptor/config.toml`:

```toml
worktree_root = "~/Workspace/worktrees"
slug_len = 24
enter = "session"
targets = ["session", "tab", "pane", "pane_below", "here"]
```

Last-session state lives at `$XDG_CACHE_HOME/rex/raptor-last` (default `~/.cache/rex/raptor-last`).

## Build

```sh
make          # ./raptor
make install  # ~/.local/bin/raptor
go test ./...
```

Requires `rex`, `zoxide`, and `git`. Development version stays **0.0.1**.
