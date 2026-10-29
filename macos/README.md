# Raptor native picker

Native macOS 14+ accessory app. No Dock window. One floating `NSPanel` hosts SwiftUI. The approved Rex-inspired layout is 440 points wide with system fonts, 14-point list text, green selection, and content-sized height. It follows system appearance, uses real Liquid Glass on macOS 26+, and falls back to native menu material on older systems. The panel anchors 72 points below the active screen's usable top edge. Dismissal hides the window and stops its child backend; the Mac UI stays warm. Cmd+Q exits the app. Focus loss does not dismiss the panel. Alerts keep their native keyboard handling.

## Build

From the repository root, write build outputs under `aux/`:

```sh
mkdir -p aux/native-check
swiftc -parse-as-library -target arm64-apple-macosx14.0 \
  macos/Sources/Raptor/*.swift -o aux/native-check/Raptor \
  -framework SwiftUI -framework AppKit
```

Strict check: add `-swift-version 6 -warnings-as-errors`.

Packaging places this executable at `Raptor.app/Contents/MacOS/Raptor` and the Go backend at `Raptor.app/Contents/MacOS/raptor-cli`. Distinct names are required on case-insensitive macOS volumes. The app does not search PATH or accept a backend executable override. Use `make app`, `make package`, and `make test-macos`; see [packaging](../packaging/macos.md).

## Launch contract

```text
Raptor --mode dirs|wt --session SID --block BID --client CID --title TITLE [--repo PATH]
```

Normal Rex invocations deliver `raptor://picker?mode=dirs&session=SID&block=BID&client=CID` with `open -g -a Raptor.app`. Launch Services reuses the existing app. The URL parser accepts picker context only and rejects duplicate/unknown keys and oversized requests; it cannot dispatch an action automatically.

Context is immutable within each picker invocation. Reopening creates a fresh model, search/form state, and Go backend; the previous backend is not reused. A mutation or removal confirmation in progress keeps its current context and must finish before a different request can replace it. The child receives `--session SID --block BID --client CID --title TITLE api`, in that order. The app keeps one NDJSON process connection. All process launch, pipe reads and writes run on a private queue. Each request has an integer ID, a 30-second timeout, and an 8 MB response limit. Backend errors remain visible. EOF, invalid envelopes, mismatched IDs, malformed JSON and transport failures close the connection. Close and reopen the app to reconnect. A timeout can leave an operation outcome unknown; check before retrying.

Go owns search, repository resolution, target availability, branch validation, destination paths, worktree operations and dispatch. Swift only displays results and sends explicit requests. Search and preview requests have separate debounce timers and generation checks. Old results cannot replace new results. Mutation buttons and keyboard submission are blocked while a mutation runs.

## Keys

| Key | Action |
| --- | --- |
| Up / Down, Ctrl+K / Ctrl+J | Select row |
| Enter | Open selected directory/worktree; choose a repository in the fallback chooser |
| Tab / Shift+Tab | Move keyboard focus; skip disabled creation controls |
| Ctrl+O / Ctrl+Shift+O | Cycle open target forward / backward |
| Cmd+Enter in the creation form | Create and open; retry opening if creation already succeeded |
| Ctrl+T | Show worktrees for the selected directory |
| Ctrl+P | Enter or cancel split mode |
| Split ⌃P in the footer | Enter split mode |
| H/J/K/L or arrows in split mode | Open left/below/above/right |
| Esc in split mode | Cancel split mode |
| Cmd+N / Ctrl+N in worktrees | Show creation form |
| Cmd+Backspace / Ctrl+X in worktrees | Ask to remove a non-main worktree |
| Esc | Clear search, then back, then hide |
| Cmd+Q | Quit explicitly, including during an operation |

Creation groups the branch name, searchable local **From branch** picker, read-only Go destination preview, and **Open in** target. Validation waits for branch input. **Create** sends creation, then dispatch. A failed dispatch leaves **Retry opening**, which reuses the created path. Completed branch/base fields stay read-only until Back. Enter in the branch field opens the base picker; Enter in that popover selects only, and Escape dismisses only the popover and restores focus. Tab / Shift+Tab traverses enabled controls. Cmd+Enter submits from the form, never from the popover. Focus callbacks bind to each new model when the warm app reopens.

Removal is a secondary action. Main worktrees cannot be selected for removal. The confirmation defaults to Cancel, not Remove. Go performs the final safety checks.

## Synthetic demo

For manual UI QA, launch a packaged app with `--demo` and optional `--mode dirs|wt`, `--repo`, and context flags. This is a separate in-memory backend. It does not start a Process, call Rex or change files. Fixed demo directories, worktrees, local branches and destination previews support screenshots and keyboard checks. Create/remove change only in-memory demo data; Open shows a demo notice rather than dispatching or closing.

Important accessibility identifiers:

- `raptor-panel`, `picker-search`, `picker-results`, `path-row:<full path>`
- `open-target`, `open-selected`, `show-worktrees`, `toggle-split`, `keyboard-hint`
- `new-worktree`, `remove-worktree`, `confirm-remove`
- `create-branch`, `create-base`, `create-destination`, `create-validation`
- `base-search`, `base-results`, `base-option:<branch>`, `base-error`
- `create-submit`, `open-created`, `create-back`, `close-picker`
- `picker-error`, `picker-notice`, `demo-indicator`

## Headless checks

Run `make test-macos` for all headless model, transport, URL-parsing checks and strict UI type-checking. These checks do not show a panel, call Rex or perform live worktree operations:

```sh
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -target arm64-apple-macosx14.0 \
  macos/Sources/Raptor/Backend.swift \
  macos/Sources/Raptor/DemoBackend.swift \
  macos/Sources/Raptor/PickerModel.swift \
  macos/Sources/Raptor/PathDisplay.swift \
  macos/Sources/Raptor/PickerStyle.swift \
  macos/Tests/NativeChecks.swift \
  -o aux/native-check/NativeChecks -framework SwiftUI -framework AppKit
aux/native-check/NativeChecks
```

Checks cover launch flags, snake-case decoding, repository fallback, stale query and preview responses, selection, target cycle, split cancellation, removal confirmation, main-worktree protection, create-and-open, dispatch-only retry, quiet initial validation, backend branch search, popover isolation, and duplicate submission.

Run the transport checks against the synthetic Swift peer, never a live backend:

```sh
mkdir -p aux/native-check/Fixture.app/Contents/MacOS
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -target arm64-apple-macosx14.0 macos/Tests/TransportFixture.swift \
  -o aux/native-check/Fixture.app/Contents/MacOS/raptor-cli
cp aux/native-check/NativeChecks aux/native-check/Fixture.app/Contents/MacOS/NativeChecks
aux/native-check/Fixture.app/Contents/MacOS/NativeChecks --transport-fixture
```

These checks verify persistent requests, partial reads, error recovery, ID mismatch, malformed JSON, EOF, invalid envelopes and shutdown during a blocked request.

## Validation limits

Built with installed Xcode 27.1 tools for arm64 and x86_64/macOS 14. Swift 6 strict checks and headless model/transport tests pass. The native app was tested through keyboard/accessibility automation: search, split cancellation, create-and-open, enabled-control Tab/Shift+Tab traversal, searchable base selection, popover Escape/Return isolation, Ctrl+O targets, removal confirmation/cancellation, navigation, and closing. Warm-model focus callbacks and fuzzy base search were also checked through the bundled Go backend in a temporary Git repository, with Rex calls blocked. An additional test used the real bundled Go backend, a temporary Git repository, and a fake Rex CLI to check dispatch/history, creation, and safe removal. No live user Rex view was switched during these checks. Intel execution and Apple notarization are not verified. Warm-reopen integration checks also verified same-process reuse, new Go child/context per invocation, top-anchor preservation, child shutdown on dismissal, and full exit with Cmd+Q. The panel does not auto-dismiss on focus loss. Backend reconnection requires hiding and reopening the picker.
