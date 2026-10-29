# Raptor

A compact directory and worktree picker for [Rex](https://www.superlogical.com/rex/docs), built with Go and Bubble Tea.

## Directory picker

`raptor dirs` searches your zoxide directories. Paths use `~`, with a soft selection highlight and no preview.

- Type to fuzzy-filter; arrows or Ctrl+J/K navigate.
- Tab / Shift+Tab cycle the target: session, tab, pane right, pane below, or cd here.
- Enter opens the selection. Session mode reuses a matching session label or creates one.
- W on a git repository opens its worktrees.
- Esc clears the query, then closes the picker.

`here` only sends a cd command when the origin pane's foreground process is a shell.

## Worktree picker

`raptor wt --repo /path/to/repo` shows existing worktrees and open GitHub issues/PRs through `gh`. Without `--repo`, it detects the repository from the origin pane, falling back to a repository picker.

- Enter opens an existing worktree or creates one for the selected issue number.
- Type an issue number to offer a new worktree.
- X offers removal of a worktree and its associated session/branch. Review the confirmation carefully: dirty worktrees can be force-removed.
- O opens an issue/PR in the browser.
- Esc clears the query, then returns to directories.

New worktrees use `<worktree_root>/<repo>/<number>-<slug>` and sessions use `<repo>#<number>`. Creation currently branches from the local checkout; selecting a PR does not check out its remote head.

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

Requires `rex`, `zoxide`, and `git`; `gh` adds issue/PR discovery. Development version stays **0.0.1**.
