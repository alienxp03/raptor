# Raptor

A keyboard-first launcher for [Rex](https://www.superlogical.com/rex/docs). Find a session or project, then switch to it or open it where you want to work.

| Search and switch | Pinned sessions |
| --- | --- |
| ![Search sessions and projects](docs/screenshots/search.png) | ![Pinned session shortcuts](docs/screenshots/sessions.png) |

| Pull request form | Worktree form |
| --- | --- |
| ![Pull request checkout form](docs/screenshots/pull-request.png) | ![Create a Worktrunk worktree](docs/screenshots/worktree-create.png) |

[More screenshots](docs/screenshots/README.md) · [Usage and design notes](docs/native-app.md) · [Session behavior](docs/sessions.md)

## Why Raptor

- **Find and switch fast.** Search live sessions and project directories across Rex hosts. Open as a session, tab, shell, or pane split; open a directory to start a session there.
- **Keep favorites close.** Pin sessions and directories. Jump to pinned sessions from anywhere in Rex with `⌃⌘1`–`⌃⌘9`.
- **Work in parallel.** Create and open Git worktrees using [Worktrunk](https://github.com/bvdeenen/worktrunk) for branch-aware paths and cleanup. `⇧⌘N` opens the form; `⌘⌥N` instantly creates a worktree, switches to its new session, and starts Pi.
- **Review PRs in context.** Paste a GitHub pull-request URL to create or reuse its worktree and open it in a session or tab.
- **Stay safe.** Worktree deletion checks status and branch integration before removal; closing a session requires explicit consent.

## Install

Requires macOS 14+, Rex, Git, [zoxide](https://github.com/ajeetdsouza/zoxide), [Worktrunk](https://github.com/bvdeenen/worktrunk), and [gh](https://cli.github.com/) for pull requests. Homebrew installs zoxide, Worktrunk, and gh for you.

```sh
brew install alienxp03/tap/raptor
raptor init
rex config reload
```

`raptor init` adds the plugin and default Rex bindings to your config.

## Shortcuts

| Key | Action |
| --- | --- |
| `⇧⌘O` | Open Raptor |
| `⇧⌘C` | Check out a pull request |
| `⇧⌘N` | Create a worktree (form) |
| `⌘⌥N` | Instant Pi worktree in a new session |
| `⇧⌘P` | Pin or unpin the selected session or directory |
| `⌃⌘1`–`⌃⌘9` | Jump to a pinned session, Rex-wide |
| `⌃P`, then `H J K L` | Choose a pane split |

In the picker, type to search; `↑`/`↓` or `Ctrl+J`/`Ctrl+K` moves through results. `Ctrl+O` changes the open target. `⌘/` shows searchable shortcuts.

## Worktrunk paths

Worktrunk controls where Raptor creates worktrees. For example:

```toml
# ~/.config/worktrunk/config.toml
worktree-path = "~/workspace/worktrees/{{ repo }}/{{ branch | sanitize }}"
```

Use `wt list` and `wt remove` to manage worktrees outside Raptor. Project setup hooks run visibly in the destination terminal.

## Development

```sh
git clone https://github.com/alienxp03/raptor ~/.config/rex/raptor
cd ~/.config/rex/raptor && make install
make test
make test-macos
```

On macOS, `make install` installs the CLI/backend and Rex plugin. To refresh the synthetic screenshots, run `scripts/capture-showcase.sh`.

[MIT License](LICENSE)
