# Local macOS packaging

Run from any directory. Requires macOS, Xcode command-line tools with the macOS
14+ SDK, and Go compatible with `go.mod`. `GO` selects a Go executable; normal
`GOTOOLCHAIN` behavior is kept. No sandbox: the backend needs Rex CLI access.
No entitlements are needed. No network icon downloads.

```sh
scripts/build-macos.sh                   # host architecture, ad-hoc signature
VERSION=0.0.1 scripts/package-macos.sh --universal
scripts/install-macos.sh                 # explicit local install, never automatic
```

App: `dist/Raptor.app`. ZIP: `dist/Raptor-VERSION-ARCH.zip`, with a `.sha256`
sidecar. ARCH is `arm64`, `x86_64`, or `universal`, read from both executables.
Universal builds compile Swift and Go separately for each architecture, then
combine each executable with `lipo`. Go uses `CGO_ENABLED=0`; macOS minimum is 14.
Tests on both hardware architectures are still needed.

Overrides:

- `VERSION`: numeric major.minor.patch, default `0.0.1`.
- `DIST_DIR`: output directory. Relative paths resolve from the caller's directory.
- `ARCH` or `--arch arm64|x86_64`, or `--universal`: target architecture.
- `GO`: executable path, including paths with spaces (not a command plus flags).
- `APP_SIGN_IDENTITY`: signing identity; default `-` (ad hoc).
- `NOTARY_PROFILE`: opt-in `notarytool` keychain profile. Package script only.
- `APP_DESTINATION`: app install directory, default `$HOME/Applications`.
- `PREFIX`: CLI install prefix, default `$HOME/.local`.
- `REX_PLUGIN_DIR`: default `$HOME/.config/rex/raptor`.

Signing proceeds inside out: Go backend, then app. No `--deep` signing; deep,
strict verification is used. A configured identity enables hardened runtime and
a secure timestamp. Use a **Developer ID Application** identity for distribution.
The script never creates certificates or stores credentials.

With credentials already set up, this command explicitly submits to Apple:

```sh
APP_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAM)' \
NOTARY_PROFILE='YOUR_EXISTING_PROFILE' \
VERSION=0.0.1 scripts/package-macos.sh --universal
```

Submission waits for success, staples the app, validates the ticket and Gatekeeper,
and recreates the ZIP before computing its checksum. `--skip-build` packages an
existing signed app; `VERSION` must match it. Set `APP_SIGN_IDENTITY` as well when
notarizing an existing app. Ad-hoc builds are local artifacts, not notarized
releases. Gatekeeper can block downloaded copies. No bypass is applied.

The Mac UI stays running while hidden. Quit it with Cmd+Q before an upgrade. Build and install scripts refuse to replace a running copy.

Installer does not run the app or change Rex config/bindings. Existing plugin
customized files and directory symlinks are kept. Installer-owned plugin copies
are upgraded only when their recorded SHA-256 still matches. Existing untracked
plugin copies are kept; review updates manually. A checkout symlink already uses
that checkout's plugin. CLI/app destination
symlinks are rejected. Only an existing app with Raptor's bundle ID is replaced.
Custom CLI prefix requires a matching plugin `setup{bin = "/path/to/raptor"}`.
Use `make install-cli` for terminal-only or remote-server use.

Make targets:

- `make app`: build the local app.
- `make package`: build, ZIP, and checksum the local app.
- `make install`: build/install app plus CLI on Mac; CLI only elsewhere.
- `make install-app`: build/install the Mac app plus CLI explicitly.
- `make test-macos`: run native model/transport tests and strict Swift UI checks.

`homebrew/raptor.rb.in` is an unfilled cask template, not a working release.
Fill VERSION, ARCH, SHA256, and RELEASE_BASE_URL only after an explicit upload.
Use the checksum for that exact ZIP and add an architecture constraint for a
single-architecture release. Cask installation does not configure the Rex plugin.
No publishing workflow is included.
