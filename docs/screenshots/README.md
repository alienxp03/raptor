# Native macOS showcase

Synthetic Raptor UI rendered at 2× for documentation. Project/session names, hosts, paths, branches, pull requests, and status output are fictional. Captures use the demo backend; they do not read live Rex sessions or modify Git worktrees.

| Screenshot | Feature |
| --- | --- |
| [Session search](search.png) | Filter sessions and directories across hosts; open the selected result in the chosen target. |
| [Pinned sessions](sessions.png) | Keep favorite sessions in fixed jump slots and see live activity at a glance. |
| [Worktrunk worktrees](worktrees.png) | Browse the repo’s primary checkout and branches managed by Worktrunk. |
| [Create worktree](worktree-create.png) | Preview branch, base, destination, open target, and optional agent launch. |
| [Safe deletion review](delete-review.png) | Review verified worktrees, locked primary checkouts, and force warnings before removal. |
| [Pull request checkout](pull-request.png) | Resolve a fictional PR and preview its branch and destination before opening. |
| [Pane split](split-mode.png) | Choose a split direction with the keyboard. |

Regenerate on macOS with `scripts/capture-showcase.sh`. Open [index.html](index.html) for the image gallery.
