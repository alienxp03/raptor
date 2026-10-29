# Native macOS showcase

Real Raptor UI, captured at 2× over an illustrative workspace. All project names, paths, and terminal output are synthetic. The screenshots use demo mode; no live Rex sessions or Git worktrees were changed.

| Screenshot | Feature notes |
| --- | --- |
| [Directory picker](directories.png) | Filter saved folders. Choose a new tab, matching session, or current shell. Ctrl+O changes the target. |
| [Worktree picker](worktrees.png) | Browse local branches and paths. Removal keeps the branch; primary and dirty worktrees stay protected. |
| [Split mode](split-mode.png) | Ctrl+P starts directional splitting. Use H/J/K/L or arrows; Escape cancels. Works with folders and worktrees. |
| [Create worktree](create-worktree.png) | Enter a branch, search local base branches, and check the destination. Create also opens the worktree; a failed open retries without creating again. |

The Mac UI uses native glass, system fonts, and keyboard controls. Mac and terminal interfaces share the same Go search, worktree, and Rex action logic.

Open [index.html](index.html) locally for a self-contained gallery.
