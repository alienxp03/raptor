# Raptor

A compact directory and worktree picker for [Rex](https://www.superlogical.com/rex/docs), built with Go and Bubble Tea.

## Directory picker

`raptor dirs` searches your zoxide directories. A single-column list shows home-relative paths, with a soft selection highlight. Long paths shorten on the left to keep the destination visible. Long queries scroll to keep the cursor visible.

- Type to fuzzy-filter; arrows or Ctrl+J/K navigate.
- Tab / Shift+Tab cycle the target: session, tab, pane right, pane below, or cd here.
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

Copy `rex/raptor.lua` to `~/.config/rex/raptor.lua`, then add `require("raptor")` to `init.lua` and run `rex config reload`.

- **Cmd+Shift+O** / **Raptor**: directory picker.
- **Ctrl+Shift+W** / **Raptor Worktrees**: worktree picker.
- **Raptor: Last Session**: toggle between sessions switched through the picker.

Direct mode: `rex do raptor target=tab dir=/path/to/project`.

The Lua wrapper opens a focused floating terminal layer. Its binary path and popup bounds are configurable there.

## Configuration

Optional `~/.config/raptor/config.toml`:

```toml
worktree_root = "~/Workspace/worktrees"
slug_len = 24
enter = "tab"
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
