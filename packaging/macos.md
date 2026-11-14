# macOS distribution

Raptor ships as one native picker/host binary plus its Rex plugin. Homebrew
installs both; there is no separate terminal UI or `.app` bundle. Stable
archives are universal (Apple Silicon and Intel) and are not Apple-notarized.

## Build and package

Requires macOS and Xcode 26+.

```sh
scripts/build-macos.sh --arch arm64
VERSION=0.1.0 scripts/package-macos.sh --universal
```

`build-macos.sh` writes `dist/raptor` and `dist/init.lua`.
`package-macos.sh` creates `dist/Raptor-VERSION-universal.zip` and its SHA-256
sidecar. The ZIP contains only the binary and plugin.

- `VERSION`: numeric `major.minor.patch`; defaults to `0.1.0`.
- `CLI_VERSION`: version shown by `raptor version`; defaults to `VERSION`.
  Build packaging injects it and restores the development source afterward.
  Homebrew HEAD builds set it to Homebrew's `HEAD-…` revision.
- `DIST_DIR`: output directory (default `dist`).

## Stable release

Push a version tag from tested `master`, e.g. `v0.1.0`. The release workflow
runs Swift, Lua, native Mac, and formula checks, builds the universal archive,
and creates a **draft** GitHub release containing the ZIP, checksum, and
Homebrew formula. It verifies the binary reports the tag's version.

Before publishing the draft:

1. Download and inspect the archive/checksum; test the package and formula.
2. Publish the GitHub release so the archive URL is public.
3. Copy its generated `raptor.rb` asset to `alienxp03/homebrew-tap/Formula/raptor.rb`;
   run `brew test` before pushing the tap. Keep the source formula template here unchanged.
4. Verify a fresh `brew install alienxp03/tap/raptor` can download and run it.

Stable Homebrew installs do not need Xcode. The formula installs the binary to
`opt/raptor/bin` and the plugin to `opt/raptor/share/raptor`. It does not modify
Rex configuration. Use `raptor init` to add or refresh the managed config block,
then `rex config reload`. Homebrew does not remove quarantine flags or change
Gatekeeper settings.

## Homebrew HEAD

`brew install --HEAD alienxp03/tap/raptor` builds from source and requires Xcode.
Keep the HEAD formula in `packaging/homebrew/raptor.rb` in sync with the tap.
`brew test alienxp03/tap/raptor` checks the installed version, plugin, and API
entry point. `scripts/test-release.sh` validates release-formula generation.
