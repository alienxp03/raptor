# Local macOS packaging

Run from any directory. Requires macOS, Xcode command-line tools with the macOS
26+ SDK (Xcode 26+). Swift builds both binaries from Package.swift; normal
No sandbox: the backend needs Rex CLI access.
No entitlements are needed. No network icon downloads.

```sh
scripts/build-macos.sh                   # host architecture, ad-hoc signature
VERSION=0.0.1 scripts/package-macos.sh --universal
scripts/install-macos.sh                 # explicit local install, never automatic
```

App: `dist/Raptor.app`. ZIP: `dist/Raptor-VERSION-ARCH.zip`, with a `.sha256`
sidecar. ARCH is `arm64`, `x86_64`, or `universal`, read from both executables.
Universal builds compile the UI and the Swift package separately for each architecture, then
combine each executable with `lipo`; macOS minimum is 14.
Tests on both hardware architectures are still needed.

Overrides:

- `VERSION`: numeric major.minor.patch for the app bundle, default `0.0.1`.
- `CLI_VERSION`: CLI version text; defaults to `VERSION`. Homebrew sets its HEAD revision.
- `RAPTOR_EXTERNAL_SANDBOX=1`: only for an already-sandboxed caller such as Homebrew;
  prevents Swift macro plugins from trying to nest a second sandbox. The outer
  Homebrew sandbox stays enabled.
- `DIST_DIR`: output directory. Relative paths resolve from the caller's directory.
- `ARCH` or `--arch arm64|x86_64`, or `--universal`: target architecture.
- `APP_SIGN_IDENTITY`: signing identity; default `-` (ad hoc).
- `NOTARY_PROFILE`: opt-in `notarytool` keychain profile. Package script only.
- `APP_DESTINATION`: app install directory, default `$HOME/Applications`.
- `PREFIX`: CLI install prefix, default `$HOME/.local`.
- `REX_PLUGIN_DIR`: default `$HOME/.config/rex/raptor`.

Signing proceeds inside out: backend, then app. No `--deep` signing; deep,
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
notarizing an existing app. Ad-hoc builds are not Apple-notarized.
Homebrew formula installs normally do not set browser-download quarantine flags.
Gatekeeper can block browser-downloaded copies. No bypass is applied.

The Mac UI stays running while hidden. Quit it with Cmd+Q before an upgrade. Build and install scripts refuse to replace a running copy.

Installer does not run the app or change Rex config/bindings. Existing plugin
customized files and directory symlinks are kept. Installer-owned plugin copies
are upgraded only when their recorded SHA-256 still matches. Existing untracked
plugin copies are kept; review updates manually. A checkout symlink already uses
that checkout's plugin. CLI/app destination
symlinks are rejected. Only an existing app with Raptor's bundle ID is replaced.
Custom standalone CLI prefixes can use an explicit plugin `setup{bin = "/path/to/raptor"}` override. Normal installs run `raptor init` (one managed Rex config block); the plugin discovers packaged CLI/app pairs automatically, and Launch Services resolves a registered standalone app by bundle ID even outside Applications directories.
Use `make install-cli` for a standalone CLI (development; the launcher itself needs the Mac app).

Make targets:

- `make app`: build the local app.
- `make package`: build, ZIP, and checksum the local app.
- `make install`: build/install the app, its matching bundled CLI, and an unchanged installer-owned Rex plugin on Mac; CLI only elsewhere.
- `make install-app`: build/install the Mac app plus CLI explicitly.
- `make test-macos`: run native model/transport tests and strict Swift UI checks.

## Prebuilt Homebrew releases

`.github/workflows/release.yml` builds a universal app on a `vMAJOR.MINOR.PATCH`
tag from `master`. It runs Swift, Lua, native Mac, and formula-generation checks;
then creates a **draft** GitHub release with the ZIP, SHA-256 checksum, and
`raptor.rb` formula. Both Intel and Apple Silicon executables are included;
the runner tests only its host architecture. No Apple credentials are needed.

To release:

1. Merge and test the release commit on `master`.
2. Push a version tag, for example `v0.1.0`.
3. Review the draft assets and test the app on Intel and Apple Silicon.
4. Ensure archive downloads are publicly accessible, then publish the draft.
5. Copy the release's `raptor.rb` asset to the tap's `Formula/raptor.rb`, and to
   `packaging/homebrew/raptor.rb` in this repository. Test the formula before
   publishing the tap update.

```sh
brew install alienxp03/tap/raptor
brew test alienxp03/tap/raptor
```

Stable installs need neither build tools nor Xcode. The formula installs `Raptor.app`,
its bundled CLI, and its bundled Rex plugin. It does not remove quarantine
attributes, disable Gatekeeper, or change user configuration. Keeping the `.app`
bundle is intentional. This is not Apple notarization or a guarantee that every
macOS security check will accept the app.

Stable releases use ordinary public archive URLs. Publish the draft release
(the draft keeps assets private until you publish it) before pushing the
stable tap entry, so downloads always work without authentication.

Generate a formula locally from a real package:

```sh
VERSION=0.1.0 scripts/package-macos.sh --universal
ruby scripts/release-formula.rb 0.1.0 dist > aux/raptor.rb
bash scripts/test-release.sh
```

## Homebrew HEAD package

`homebrew/raptor.rb` retains source builds with `--HEAD`, also published as
`alienxp03/homebrew-tap/Formula/raptor.rb`. Keep both copies identical.

```sh
brew install --HEAD alienxp03/tap/raptor
brew upgrade --fetch-HEAD alienxp03/tap/raptor
brew test --HEAD alienxp03/tap/raptor
```

The formula builds from source with the Xcode toolchain (needed for the Swift
package and the guarded macOS 26 glass API; the app still targets macOS 14+).

The package owns only Homebrew paths:
- `opt/raptor/libexec/Raptor.app`: signed native app and bundled backend.
- `opt/raptor/bin/raptor`: link to that same backend.
- `opt/raptor/share/raptor/init.lua`: Rex plugin.

It does not run the local installer, replace checkout symlinks, write user config,
or overwrite `~/Applications/Raptor.app`. Rex's Lua search path must include the
packaged plugin for a fresh install; see the README or `brew info` caveats.
An updated plugin automatically selects the Homebrew app and CLI through stable
`opt` paths. Run `raptor init` to generate a direct `dofile("/installed/plugin/init.lua").setup{}` load and named key bindings. No Lua search-path edits or cache resets are needed: `rex config reload` reads the plugin again. A standalone plugin prefers the local CLI installation; a Homebrew plugin stays paired with its package. Explicit `bin` overrides remain supported for intentional development/custom installs.

This formula layout is the distribution contract: one app bundle owns the backend, `bin/raptor` links to that same backend, and the Lua module resolves the package as a pair. Do not independently discover arbitrary CLI and app copies by filename, or store versioned Cellar paths in user config. Homebrew's `opt` symlink follows upgrades. A cask can be considered later for a standalone drag-and-drop app, but is not required for the CLI-first tap.

Quit the app before upgrading, then reopen it to start the new backend. A
manual CLI earlier on PATH (such as `~/.local/bin/raptor`) shadows the
package; remove it to use the managed one.

`homebrew/raptor.rb.in` is an unused cask template. Prebuilt releases use a
formula, not a cask. Until the first stable release, the working formula is
HEAD-only.
