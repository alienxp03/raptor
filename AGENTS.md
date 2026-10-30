# Current development scope

- Focus on the terminal UI (`internal/picker`) for now, including on macOS.
- Do not change, rebuild, or install the native Mac app unless the user explicitly requests it.
- Shared backend changes are allowed when needed for the terminal flow.
- Use `make test` for checks and `make install-cli` to install terminal changes.
- Preserve existing native-app changes. Do not revert them without approval.
