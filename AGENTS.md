# Native Mac app

- The picker is the native Mac app (`macos`) over the shared Go backend. The terminal UI was removed; do not reintroduce terminal renderings of picker flows.
- Keep UI logic in the Go backend; Swift draws and confirms but does not calculate, validate, or dispatch.
- Run `make test` and `make test-macos` for shared changes. Check the changed UI layouts too.
- After finishing any code change, rebuild so the user can test immediately. On macOS use `make install` (app + bundled CLI).
- Preserve existing changes. Do not revert them without approval.
