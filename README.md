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
- **Worktrees** — create from a searchable base branch with a validated destination preview. `⌘⌥N` skips the form entirely: a two-word branch, a new session, and a fresh agent.
- **Pull requests** — paste any GitHub PR URL and confirm; Raptor clones or reuses the repo and opens the PR worktree. Closed PRs with deleted branches still open from the PR commit.
- **Safe by default** — nothing is created without Enter, project hooks always ask for approval, and a failed open offers retry instead of creating twice.

## Install

Requires macOS 14+, [Rex](https://www.superlogical.com/rex/docs), Git, [zoxide](https://github.com/ajeetdsouza/zoxide), [Worktrunk](https://github.com/bvdeenen/worktrunk), and [gh](https://cli.github.com/) for pull requests. Homebrew installs zoxide, Worktrunk, and gh for you.

Deletion checks use Bash, Git, find, base64, and Worktrunk on the selected host. Each worktree uses one batched check for Git identity, status, nested repositories, and Worktrunk branch integration. Dependency contents are not read or hashed. Failed checks do not enable deletion.

```sh
brew install alienxp03/tap/raptor
raptor init
rex config reload
```

`raptor init` writes one plugin load and ordinary named key bindings into your Rex config. It finds the installed plugin automatically; no Lua search paths, cache resets, or callback wrappers. Rerun it after changing installation locations.

| Key | Action |
| --- | --- |
| `⇧⌘O` | Open Raptor |
| `⇧⌘C` | Checkout pull request |
| `⇧⌘N` | Create a worktree (form) |
| `⌘⌥N` | Instant agent worktree (pi, no form) |
| `⌃⌘1`–`⌃⌘9` | Jump directly to pinned session slot 1–9, Rex-wide (no picker) |

The plugin registers `raptor_pin_1` through `raptor_pin_9`; bindings live in your Rex config, not plugin setup. `raptor init` adds these defaults to its managed block; custom bindings outside that block stay untouched. Plain `⌘1`–`⌘9` are unchanged.

## Usage

Pinned session slots are persisted independently of picker order and search. New session pins take the lowest free slot from 1–9; unpinning frees that slot without renumbering others. Additional pins remain pinned without a shortcut. Legacy session pins receive available slots in saved order. Only session pins use slots; directory pins do not. Each jump validates the exact stored session ID on its stored host using a fresh host-native listing. Warm local jumps use a direct server call, with no process launches; changing the saved pin file clears the resolved-identity cache. Empty slots, closed sessions, or offline hosts report an error: no picker, replacement session, or automatic repinning. The equivalent CLI is `raptor [context flags] pinned-session <1..9>`; context flags (such as `-client`) precede the command.

Session activity: working `...`, unread result marked by a tiny themed icon dot, seen result no completion indicator. Working and unread can show together. Rex owns seen receipts; Raptor does not mark results seen. The local Mac preference adapter is client-specific; unavailable receipt data hides the dot.

Pinned rows come first: sessions in saved pin order, then local directories in their separately saved pin order. Unpinning and pinning again moves that item to the end of its pin group; fixed shortcut slots do not change for other sessions. The current session follows, then other sessions and directories by frequency. Session pins persist with their host identity; local directory pins persist too. Opening selects the current session, even below pinned rows. Search puts matching open sessions before directories. Each match must fit within a name, path, or hostname; it cannot span fields. `Enter` switches to a session or opens a directory; the target row shows where it will open.

| Key | Action |
| --- | --- |
| Type | Filter |
| `⌘/` | Search keyboard shortcuts; `Esc` returns to the picker |
| `↑`/`↓`, `Ctrl+J`/`Ctrl+K` | Move through results |
| `Ctrl+O` | Change where the item opens |
| `Ctrl+R` | Rename the selected session; `Enter` saves, `Esc` cancels |
| `Ctrl+X` | Close the selected session; keep all worktrees and branches |
| `Cmd+Shift+X` | Review and delete selected worktrees, with consent to close the session |
| `Enter` | Switch or open |
| `Ctrl+P`, then `H J K L` | Open in a pane split |
| `⇧⌘P` | Pin/unpin the selected session or local directory |
| `⇧⌘C` | Checkout pull request (or paste a PR URL) |
| `Esc` | Clear filter, then dismiss |

The **Shortcuts** footer button opens the same help page. Search action names or keys, such as `rename`, `ctrl r`, or `split`. Use `↑`/`↓` or `Ctrl+J`/`Ctrl+K` to move through shortcuts. The selected row uses the picker theme and stays visible. Help lists Raptor actions only, with action names and keys. Split directions and form keys appear only in their active context. Help never runs an action, and returning preserves the picker search and selection. `?` also opens help when no text field is active; in a text field it stays normal text.

Close uses inline confirmation: `Enter` confirms, `Esc` cancels. Delete first lists pane directories from Rex, then checks them one at a time and merges duplicates by Git worktree. Each row shows its own progress or error; Retry checks a failed row without clearing completed results. These initial checks read Git metadata only, not dependency contents. Deletable worktrees start selected; primary checkouts, unknown directories, and parents containing another reviewed checkout stay locked. Opening Delete automatically verifies worktrees on that same page. Select worktrees, review the inline results, then consent and choose **Delete selected**. There is no Continue or Verify action. The title, worktree list and close-session consent stay in place while verification runs; consent and Delete remain disabled until it finishes. All eligible worktrees get automatic safety checks, with up to two worktrees verified in parallel and progress shown on both active rows. Checkboxes remain editable during and after verification. Results are merged into the review after each batch; a failed check keeps its successful sibling, and Retry skips completed rows. Verified rows warn only about uncommitted changes and unmerged commits. Ignored files follow normal Git status rules: they are not reported as problems and do not require Force. A selected-worktree Force warning appears during verification and before deletion confirmation, not only after a failed Delete. Actual deletion stays sequential. Worktrunk may move a removed worktree into its trash directory; this expected cwd change does not stop later removals. Host identity, session identity, pane membership and directories of all panes not yet removed remain checked. Worktrunk determines branch integration, including squash merges and patch-ID matches; Raptor does not require a strict ancestor relationship. Checks compare Git identity and status, not exact file contents; final removal safety is enforced by Worktrunk. Nothing is deleted during preparation. After verification, explicitly consent to closing the whole session, including tabs for unselected repos. Changing checkboxes reuses completed verification without restarting checks, but clears close-session consent. The backend freezes the verified pool; final deletion may use only a verified subset. A Force offer remains bound to its exact selection. Use `↑`/`↓`, `Ctrl+J`/`Ctrl+K`, or `Tab`/`Shift+Tab` to move between available controls; `Space` toggles the focused checkbox. `Cmd+Enter` confirms **Delete selected** from any focus, after automatic checks and explicit close-session consent. `Enter` on checked consent confirms instead of unticking it. Only `Space` toggles checkboxes. `Enter` on Cancel still cancels. Focus follows the keyboard and scrolls into view. Unselected worktrees and remote branches stay unchanged. Dirty worktrees or unmerged commits need a separate Force confirmation (`Cmd+Shift+X` or **Force delete…**, then `Enter`); Force can discard files and commits. The Force confirmation starts on Cancel. Open it explicitly first, then activate the final button or press `Cmd+Enter`; held keys cannot confirm it. `Cmd+Enter` never upgrades a refused normal Delete to Force by itself. The picker’s origin session stays protected. Partial failures report removed worktrees and keep the session open without automatic retry.

Optional Rex binding: `cmd+p` → `raptor_session_last`. Rerun `raptor init` to add the direct `shift+cmd+c` → `raptor_pr_open` binding. This replaces the old optional PR binding inside the managed block only; bindings outside that block stay unchanged.

### Worktrees

`⇧⌘N` opens the create form: a suggested branch name, searchable base branch, destination preview, and open target. A separate **Agent launch** section selects Pi, Codex, or No agent; model and reasoning show the resolved launch values, not a generic Default label. `⌃⌥O` cycles agents, `⌃⌥M` cycles models, and `⌃⌥R` cycles reasoning levels. **Save as default** stores these selections for new forms. Enter creates and opens in one step. Worktrunk owns where worktrees live:

```toml
# ~/.config/worktrunk/config.toml
worktree-path = "~/workspace/worktrees/{{ repo }}/{{ branch | sanitize }}"
```

If the project has setup hooks, they run visibly in the destination terminal. `wt list` and `wt remove` manage existing worktrees.

### Instant agent worktree

`⌘⌥N` skips the form and switches immediately to a new session showing setup progress. A two-word branch (`otter-falcon`) is created from the repo's HEAD, the session takes its branch name, and `pi` starts. Repeat presses while creation is pending focus that session instead of creating duplicates. Setup failures retain their output and a usable shell. The CLI equivalent is `raptor task`.

### Pull requests

`Cmd+Shift+C` opens **Checkout pull request** directly from Rex or inside the picker. You can also paste a PR URL into search, then confirm. Raptor reuses a matching local clone or clones the repo, creates the worktree, and opens it in a session or tab. Requires `gh auth login`.

## Configuration

All optional.

```toml
# ~/.config/raptor/config.toml
enter = "session"
targets = ["session", "tab", "here", "pane_right", "pane_below"]
```

The generated Rex setup looks like this (the plugin path is discovered by `raptor init`):

```lua
dofile("/path/to/raptor/init.lua").setup{}
rex.bind("shift+cmd+o", "raptor")
rex.bind("shift+cmd+c", "raptor_pr_open")
```

Direct loading also picks up plugin upgrades when you run `rex config reload`.

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
