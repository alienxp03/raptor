# Native macOS showcase

Native Raptor views rendered at 2× with synthetic project names, paths, and data. The screenshots use demo-style backends; no live Rex sessions or Git worktrees were changed.

| Screenshot | Feature notes |
| --- | --- |
| [Session launcher](directories.png) | Search live sessions and saved folders. The most-recent non-current session is selected by default. Ctrl+O changes the open target. |
| [Pull request](pr.png) | Paste any GitHub PR URL. Raptor resolves metadata, previews the destination, and opens the worktree in a session or tab. |
| [Split mode](split-mode.png) | Ctrl+P starts directional splitting. Use H/J/K/L or arrows; Escape cancels. |
| [Create worktree](create-worktree.png) | Choose a branch and base, preview the destination, then create and open. Opening can be retried without creating again. |

The Mac UI uses system fonts, native glass, and keyboard controls. Mac and terminal interfaces share the same Go search, worktree creation, and Rex action logic.

Open [index.html](index.html) locally for the gallery.
