# Raptor

A session and project launcher for [Rex](https://www.superlogical.com/rex/docs). Resume a session or open a project directory — as a session, tab, pane split, or the current shell — and create Git worktrees or open GitHub pull requests without leaving the keyboard.

Native Mac picker over one shared Swift backend — a bare host process spawned under Rex (the resh model: no app bundle, no TCC prompts).

<p align="center">
  <img width="72%" src="docs/screenshots/directories.png" alt="Raptor session launcher">
</p>

| | |
| --- | --- |
| ![](docs/screenshots/pr.png) | ![](docs/screenshots/create-worktree.png) |
| *Open a pull request* | *Create a worktree* |

More screenshots in the [gallery](docs/screenshots/README.md).

## Features

- **Resume, don't re-pick** — the launcher opens on your most-recent other session; `⌘P` returns to the last one. Live sessions and frequent directories from every connected host in one searchable list.
- **Open anywhere** — a session, new tab, the current shell, or a pane split (`Ctrl+P`, then `H J K L`).
- **Worktrees** — create from a searchable base branch with a validated destination preview. `⌃⇧N` skips the form entirely: a two-word branch, a new tab, and a fresh agent.
- **Pull requests** — paste any GitHub PR URL and confirm; Raptor clones or reuses the repo and opens the PR worktree. Closed PRs with deleted branches still open from the PR commit.
- **Safe by default** — nothing is created without Enter, project hooks always ask for approval, and a failed open offers retry instead of creating twice.

## Install

Requires macOS 14+, [Rex](https://www.superlogical.com/rex/docs), Git, [zoxide](https://github.com/ajeetdsouza/zoxide), [Worktrunk](https://github.com/bvdeenen/worktrunk), and [gh](https://cli.github.com/) for pull requests. Homebrew installs zoxide, Worktrunk, and gh for you.

```sh
brew install alienxp03/tap/raptor
raptor init
rex config reload
```

`raptor init` adds a small managed block to your Rex config — plugin, setup, and these bindings. Rerun it any time; edit the block like any other Rex config.

| Key | Action |
| --- | --- |
| `⇧⌘O` | Open the launcher |
| `⇧⌘N` | Create a worktree (form) |
| `⌃⇧N` | Instant agent worktree (pi, no form) |

## Usage

Sessions come first (the current one marked), then directories by frequency. `Enter` switches to a session or opens a directory; the target row shows where it will open.

| Key | Action |
| --- | --- |
| Type | Filter |
| `↑`/`↓`, `Ctrl+J`/`Ctrl+K` | Move through results |
| `Ctrl+O` | Change where the item opens |
| `Enter` | Switch or open |
| `Ctrl+P`, then `H J K L` | Open in a pane split |
| `⇧⌘P` | Open a pull request (or paste a PR URL) |
| `Esc` | Clear filter, then dismiss |

Optional bindings for your managed block: `cmd+p` → `raptor_session_last`, `shift+cmd+p` → `raptor_pr_open`.

### Worktrees

`⇧⌘N` opens the create form: a suggested branch name, searchable base branch, destination preview, and open target. Enter creates and opens in one step. Worktrunk owns where worktrees live:

```toml
# ~/.config/worktrunk/config.toml
worktree-path = "~/workspace/worktrees/{{ repo }}/{{ branch | sanitize }}"
```

If the project has setup hooks, they run visibly in the destination terminal. `wt list` and `wt remove` manage existing worktrees.

### Instant agent worktree

`⌃⇧N` skips the form: a two-word branch (`otter-falcon`) is created from the repo's HEAD, a new tab opens, and `pi` starts. The CLI equivalent is `raptor task`.

### Pull requests

`⇧⌘P`, or paste a PR URL into search, then confirm. Raptor reuses a matching local clone or clones the repo, creates the worktree, and opens it in a session or tab. Requires `gh auth login`.

## Configuration

All optional.

```toml
# ~/.config/raptor/config.toml
enter = "session"
targets = ["session", "tab", "here", "pane_right", "pane_below"]
```

```lua
require("raptor").setup{
  bounds = { x = 0.28, y = 0.14, w = 0.44, h = 0.40 },
}
```

Skip the picker entirely: `rex do raptor target=tab dir=/path/to/project`.

## How it works

The Rex plugin talks to a Swift backend that keeps the panel and its data warm between opens, so reopening takes about 125 ms. Session order follows shared recency history, including sidebar switches. Details: [sessions](docs/sessions.md), [the native app](docs/native-app.md), [packaging](packaging/macos.md).

## Development

```sh
git clone https://github.com/alienxp03/raptor ~/.config/rex/raptor
cd ~/.config/rex/raptor && make install
```

On Mac this installs the bare host/CLI as `~/.local/bin/raptor` and the Rex plugin under `~/.config/rex/raptor`. The native picker spawns under Rex on demand, inheriting Rex's file-access grants. Other systems install the CLI only.

Track `master` without a checkout (builds from source; Xcode 26+):

```sh
brew install --HEAD alienxp03/tap/raptor
```

A previous `~/.local/bin/raptor` shadows the Homebrew CLI on PATH; remove it
to use the managed one.

```sh
make test         # All Swift tests, 16 isolated workers, then Lua checks
make test-macos   # Native host checks, with cached builds
make install      # dist/raptor + plugin (release build)
```

Use `make test TEST_WORKERS=4` to limit local CPU use. Native checks cache
binaries by source contents, compiler and flags under `aux/native-test-cache/`.
Delete that directory to force a fresh compile. Each run still executes all
checks with new runtime fixtures; production request timeouts stay unchanged.

## License

[MIT](LICENSE)
