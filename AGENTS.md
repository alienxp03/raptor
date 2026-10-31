# Terminal and Mac app parity

- Maintain both the terminal UI (`internal/picker`) and native Mac app (`macos`). Neither is secondary.
- For each workflow or behavior change, check both interfaces and update both when applicable. Do not leave one behind.
- Keep UI routing, target choices and order, shortcuts, direct Create, cancellation, loading, and Repo/Destination paths in sync.
- Keep shared logic in the Go backend. Use platform-specific controls, but keep their meaning and actions consistent.
- Run `make test` and `make test-macos` for shared workflow changes. Check the changed UI layouts too.
- After finishing any code change, rebuild so the user can test immediately. Use `make install` for shared or macOS-affected changes; use `make build` (or `make install-cli`) for terminal-only changes.- When installing shared changes on macOS, rebuild and install both the app and bundled CLI with `make install`. Use `make install-cli` only for terminal-only installs.
- Preserve existing changes. Do not revert them without approval.
