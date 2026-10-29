# zpick

sesh-style session picker for [Rex](https://www.superlogical.com/rex/docs), written in Go with Bubble Tea. Picks from your zoxide list, live Rex sessions, and git worktrees — then opens the pick as a session, tab, split pane, or `cd` in place.

## Flows

**`zpick dirs`** — directories & sessions.

```
  zpick   dirs & sessions
> castty        ~/Workspace/Projects     │ master ●
  dotfiles      ~/Workspace/Projects     │ ├── apps
                                      …  │ └── docs
  open as: [session] tab pane→ pane↓ cd here
  tab⇄ target · w worktrees · enter open · esc quit
```

- type to fuzzy-filter, `tab`/`shift+tab` cycle the open-as target
- `w` on a git repo row bridges into the worktree flow
- live sessions are marked `●` and switch directly

**`zpick wt [repo]`** — worktrees for a repo (auto-detected from the
current pane, else a repo picker). Existing worktrees with dirty state,
open issues/PRs via `gh` (enter creates the worktree + session), and a
ghost row when you type an issue number. `x` removes a worktree (+branch,
+session), `o` opens it in the browser, `esc` returns to dirs.

New worktrees are created under `worktree_root` as
`<repo>/<number>-<slug>` with branch `<number>-<slug>`; sessions are named
`<repo>#<number>` so re-opening is just Enter.

## Rex integration

Run through a small `init.lua` wrapper (see `rex/zpick.lua` in my
dotfiles) that opens the binary in a floating layer:

- `zpick` — ⇧⌃N or palette, the dir picker
- `zpick_wt` — ⇧⌃W or palette, the worktree picker
- `zpick_last` — jump back to the previous session (A↔B toggle)
- `rex do zpick target=tab dir=~/proj` — head-less open

Works from the command palette on the iOS app too.

Actions `zpick` (⇧⌃N), `zpick_wt` (⇧⌃W), `zpick_last` (jump back to the
previous session, A↔B toggle) run the binary in a floating layer and work
from the command palette — including the iOS app.

## Config

`~/.config/zpick/config.toml`:

```toml
worktree_root = "~/Workspace/worktrees"
slug_len      = 24
enter         = "session"          # default target for Enter
targets       = ["session", "tab", "pane", "pane_below", "here"]
```

## Build

```sh
make            # builds to ./zpick
make install    # builds to ~/.local/bin/zpick
```

Requires `rex`, `zoxide` on PATH; `gh` for issue rows; `eza` optional for previews.
