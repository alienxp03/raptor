# Resh Model — dropping the .app

Decision record and migration plan. Status: **implemented** — the host lives in the raptor binary (`raptor serve`), the app bundle, LaunchAgent, and `raptor service` are deleted, and the plugin spawns nothing: the panel client spawns the host on demand under Rex's process chain.

## Problem

The fd directory scan (never-visited project discovery) works in the CLI but
prompts macOS TCC dialogs when served from `Raptor.app`:

- The app's backend (`raptor-cli`, spawned by the bundle) enumerates
  `~/Desktop`, `~/Documents`, `~/Downloads` — TCC-protected folders. macOS
  prompts once per folder, naming `Raptor.app`.
- Ad-hoc signing gives the binary a **new code identity on every rebuild**, so
  TCC forgets each Allow and re-prompts. Development became unusable.

## Investigation

Checked resh (the prior-generation Rex session helper) as the counterexample:

- `resh` is a **bare Mach-O Swift binary** (arm64, links AppKit/Carbon/
  Combine/QuartzCore) with a resource bundle — **no `.app`**, signed ad-hoc
  (`io.github.CruelAddict.resh`). The `/opt/homebrew/bin/resh` shim execs it.
- It renders **native macOS UI** from that non-bundled executable and runs an
  **fd Find option** over the home directory.
- Zero TCC prompts, ever.

Why: TCC attributes file access to the nearest ancestor app ("responsible
process"). resh is spawned inside Rex's terminal → fd inherits **Rex's
grants** (granted long ago, or Full Disk Access). A bare binary with no
granted ancestor doesn't even get prompts — macOS silently denies (EPERM).

Raptor's backend is the *top* of its own process chain (spawned by the app
bundle / LaunchAgent), so it faces TCC as itself — and ad-hoc rebuilds reset
its identity each time.

Two claims made during investigation were corrected by these findings:

1. ~~"A CLI can't render native panels"~~ — false; resh is the proof.
2. ~~"resh avoids prompts because it never scans the filesystem"~~ — false;
   it runs fd and stays prompt-free purely via ancestry.

## Decision

**Adopt the resh model.** No use case requires the current independent-app
model (launch-at-login, pre-Rex operation, survival across Rex restarts).
Drop `Raptor.app`; spawn everything from Rex like resh does. TCC and signing
complexity is deleted at the root: ad-hoc forever, zero prompts, Rex's grants
cover the fd scan automatically.

Consequences accepted:

- Backend lifetime couples to Rex (restarts with it).
- No standalone launch before Rex runs.
- No Dock/menu presence for the picker itself.

Remote hosts are unaffected: hades is Linux — TCC never applied there.

## Delete list

- `Raptor.app` target and `macos/Sources/Raptor` app-shell code (Backend
  spawn, service lifecycle, LaunchAgent).
- `scripts/install-macos.sh` app install path; `raptor service` subcommand.
- Formula app bundling — becomes a plain `bin.install "raptor"` (resh's
  formula is the template).
- The Developer-ID Makefile default added during investigation (revert).
- The whole signing/TCC discussion.

## Survives unchanged

- fd scan, typed-path open, zoxide graduation (`RaptorRex`/`RaptorCatalog`/
  `RaptorAPI` — model-agnostic; the scan inherits Rex's grants).
- `raptor api` stdio wire protocol, dispatch, worktrees, pull requests,
  recency, LauncherUpdates overlay — already CLI-shaped.
- Panel socket protocol (ownership moves to the Rex-spawned backend).
- Remote-host flows over SSH.

## Migration phases

1. **Backend under Rex** — the Rex plugin spawns `raptor serve` directly
   (resh.lua pattern) instead of the app/LaunchAgent. Panel socket unchanged.
   Largest risk: backend restarts with Rex; verify recency cache and event
   pumps reattach cleanly.
2. **Picker goes bare-binary** — port the SwiftUI picker into the resh-style
   non-bundled NSApplication setup (window, key handling, and outside-click
   monitor already exist as code; the app shell is what disappears).
3. **Delete the app** — packaging, formula, install script, and
   `scripts/test-macos.sh` app fixtures move to the bare-binary layout.

## Sequencing with pending work

Land the model-independent fixes on master first so the tree is green, then
branch `resh-model` for phases above. The v0.2.0 tag waits: no point shipping
a build scheduled for restructure.

Pending fixes (from the fd-flow session, uncommitted at decision time):

- `PipeInput.readChunk` POSIX-read fix — `NSFileHandle.availableData` raises
  an uncatchable ObjC exception on closed-pipe reads; this aborted the
  bundled backend (4 crash reports) and surfaced as "Backend connection is
  closed". In the resh model the spawn parent changes, but the fix is correct
  for any stdio child.
- Remote dir scan: single SSH round trip (`command -v fd && fd … || find …`)
  — hosts without fd cost one attempt, not five (15s → ~1.4s to hades).
- `RAPTOR_DISABLE_DIR_SCAN` test isolation + `APITestCase.setUp` — fixture
  tests stub zoxide via PATH, which the scan's real commands bypass.
- `scripts/test-release.sh` anchor greps updated to the sealed-bundle formula
  (`libexec.install app`, `cp -p` plugin) — unblocks release CI, which failed
  for v0.1.0 and v0.2.0 on stale anchors.
- Known open: `LauncherUpdatesTests.testCreatedSessionVisibleOnFirstWarmRead`
  fails under parallel load on the fd branch (passes in isolation, passes on
  master). Scan lag masking an overlay race — resolve before tagging.

## Homebrew note

The formula loses `libexec.install "Raptor.app"`, the CLI symlink into the
bundle, and the pkgshare plugin copy — `raptor` becomes a normal brew binary
carrying its own resources (resh-style `libexec/` layout works). `brew test`
exercises the api path; the sealed-bundle `cp -p` reasoning disappears with
the bundle.
