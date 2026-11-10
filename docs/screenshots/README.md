# Native macOS showcase

Native Raptor views rendered at 2× with synthetic project names, paths, and data. The screenshots use demo mode; no live Rex sessions or Git worktrees were changed.

| Screenshot | Feature notes |
| --- | --- |
| [Session launcher](directories.png) | Search live sessions and saved folders. The most-recent non-current session is selected by default. Ctrl+O changes the open target. |
| [Split mode](split-mode.png) | Ctrl+P starts directional splitting. Use H/J/K/L or arrows; Escape cancels. Works with selected folders. |
| [Create worktree](create-worktree.png) | Enter a branch, search local base branches, and check the destination. Create also opens the worktree; a failed open retries without creating again. |

The Mac UI uses native glass, system fonts, and keyboard controls. Mac and terminal interfaces share the same Go search, worktree, and Rex action logic.

Open [index.html](index.html) locally for the gallery.
