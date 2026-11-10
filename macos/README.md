# Raptor native picker

Native macOS 14+ accessory app. No Dock window. One floating `NSPanel` hosts SwiftUI. The approved Rex-inspired layout is 640 points wide with system fonts, 13-point list text, theme-derived selection, and content-sized height. It follows system appearance, uses real Liquid Glass on macOS 26+, and falls back to native menu material on older systems. The panel anchors 72 points below the active screen's usable top edge. Dismissal hides the window. The resident host keeps its backend warm; a non-resident picker stops it after pending work ends. Cmd+Q hides a resident picker and exits a non-resident app unless work is pending. Clicking outside Raptor dismisses the panel without consuming the click. Picker popovers and confirmation dialogs count as inside; focus changes alone do not dismiss. Pending operations continue, and recovery is preserved. Alerts keep their native keyboard handling.

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
Raptor --mode sessions|dirs|wt-create|pr --session SID --block BID --client CID --title TITLE [--repo PATH]
```

The launcher is one flat session/directory list. New worktree creation has searchable base branches; Instant Pi worktrees, PR checkout, and session activity indicators integrate with the same shared backend.

Normal Rex invocations use the resident panel socket. Launch Services fallback delivers `raptor://picker?mode=dirs&session=SID&block=BID&client=CID` with a package-paired app path or `open -g -b com.alienxp03.raptor` for a registered standalone app installed elsewhere. Launch Services reuses the existing app. The URL parser accepts picker context only and rejects duplicate/unknown keys and oversized requests; it cannot dispatch an action automatically.

Context is fixed during each picker operation. The resident host reuses its model and backend, sets new context through the `context` request, and can show cached same-origin rows immediately. Non-resident invocations create a fresh model and backend. A mutation or removal confirmation in progress keeps its current context and must finish before a different request can replace it. The child receives `--session SID --block BID --client CID --title TITLE api`, in that order. The app keeps one NDJSON process connection. Process launch and request writes use one private serial queue. A separate reader drains stdout even when no request is pending. Each request has an integer ID, a 30-second timeout (180 seconds for PR Resolve/Open; 600 seconds for PR Prepare), and an 8 MB response limit. Backend errors remain visible. EOF, invalid envelopes, mismatched IDs, malformed JSON and transport failures close the connection. Close and reopen the app to reconnect. A timeout can leave an operation outcome unknown; check before retrying.

Go owns search, repository resolution, target availability, branch validation, destination paths, worktree operations and dispatch. Swift only displays results and sends explicit requests. Search and preview requests have separate debounce timers and generation checks. Old results cannot replace new results. Mutation buttons and keyboard submission are blocked while a mutation runs.

## Native pull requests

Cmd+Shift+P opens the PR form. A GitHub PR URL in main search adds one selectable `Open PR #N — owner/repo` row. Enter opens the form; paste alone makes no API call. A clickable `⇧⌘P PR` footer hint opens the same form from the launcher. The Return action shows only `↵`, with an accessible Open label and tooltip. No PR browser is added. `--mode pr`, panel mode `pr`, and picker URL mode `pr` open the form directly. The CLI and Rex action route to this mode outside the native app.

The native form accepts GitHub PR URLs and normalizes them to `https://github.com/OWNER/REPO/pull/N`. Trailing slashes, query strings, fragments, and PR tabs (`changes`, `files`, `commits`, `checks`) are stripped. Bare PR numbers are rejected, even with ambient repository context. On opening an empty form, a valid GitHub PR URL from the clipboard is prefilled; unrelated clipboard contents are ignored and explicit input takes priority. The empty field shows a dimmed URL example. Title, Status, Repo, Branch, and Destination use matching read-only rows, with Branch directly below Repo. URL requests omit the ambient repository; the URL defines its own repository. HTTP, bare hosts, unrelated paths, credentials and ports are rejected. It resolves metadata asynchronously and rejects stale replies after input/context changes. Repo and Destination are read-only backend paths; `clone_required` adds `Will clone to …`. Session is recommended and selected by default; Tab is the only other target. Here and split targets are not offered.

For a closed or merged PR whose source branch was deleted, the action is **Check out PR commit…**. A confirmation explains that this creates an editable worktree on isolated local branch `pr/N`, without restoring or pushing the deleted branch. Cancel and Escape do nothing to Git. Only confirmation sends `checkout_commit:true`; retries reuse a preserved worktree. Other PRs retain the normal Open action. Errors show their final diagnostic line, with **Details…** for selectable, scrollable full output and **Copy error**.

Native API contract:

```text
pullrequests.resolve {repo?: path, input: string, checkout_commit?: boolean}
pullrequests.prepare {repo?: path, input: string, checkout_commit?: boolean}
  -> {input?, url?, number?, title?, branch?, state?, head_deleted?, head_oid?, repo?, path?, clone_required?, existing?, error?}
pullrequests.open {path: string, target: "session" | "tab"}
  -> {path?, session_id?, window_id?, block_id?, error?}
```

All fields are flat. `number` is an integer; flags are booleans. `repo` is the local repository path, not `owner/repo`. Resolve is read-only. Prepare can take up to ten minutes. The backend owns clone, Worktrunk paths, resource reuse and visible setup in the destination terminal. Native progress is `Resolving`, `Preparing repository and worktree`, then `Opening session`.

Prepare stores any returned path before checking a structured error or sending Open. Open failure preserves the path and exposes Retry opening; retry sends only Open, never Prepare. If the connection closed, Retry reconnects the same model with its original launch context. Resident reopen can also reconnect in place. Both retain the path, target and error; no unrelated invocation context replaces recovery. Go owns durable destination IDs and path reconciliation. Structured result `error` takes priority over apparent request success. Backend envelope errors also remain visible. Backend must reconcile partial destination IDs by path on Open retry. Hide/reopen and changed launch contexts retain in-flight prepare/open and committed recovery. Discard recovery forgets only the UI, never deletes resources. Escape before mutation restores the prior main query/selection; direct launch Escape hides the form.

Tests: `NativeChecks.swift` covers URL recognition/action, no paste mutation, number context, stale resolution, target policy, progress/layout, structured errors, preserved recovery, and open retry without prepare. Queued transport cancellation includes Resolve; issued requests still drain matching IDs and mutations are not cancelled.

## Live Rex activity

The resident host keeps its model and backend while hidden. AppKit presentation/dismissal hooks call `setPresented`; SwiftUI appearance is not a visibility signal for a resident view.

`BackendClient.setChangeHandler` has a no-op default (`false`) for demo/test clients. `ProcessBackend` sends Raptor's NDJSON `events.subscribe` request with `{enabled:true/false}`; this is not a Rex server method. Go owns the native Rex event subscription. Swift does not open a separate Rex connection or calculate activity projection. Subscribe completes before cold list requests. Cached warm rows stay usable immediately; subscription then requests a fresh snapshot to cover changes missed while hidden.

The idle reader accepts `{"event":"rex.changed"}` without an ID, between normal responses. Requests remain serial, with strict response IDs/envelopes and the existing 30-second timeout. Invalid events, EOF and malformed responses close the connection. Closing wakes blocked requests and stops the reader/child.

Visible notifications coalesce for 40 ms. Changes during a refresh cause one follow-up. There is no recurring activity poll. Swift re-requests the current filtered Sessions rows; Go owns projection and cache invalidation. Live updates preserve target, query, selection/scroll identities, busy state, forms, popovers and split mode. Row ordering stays stable during an open presentation. Fresh opens and cached reopens use Go's preferred `selected_id` to select a non-current MRU session, falling back to a directory before the current session. Create forms ignore activity notifications.

Hide unsubscribes without cancelling mutations. Presentation, context and query generations reject old callbacks and responses. Close stops the connection. Reopening a failed resident connection uses the existing host recovery path; Go owns Rex notification reconnection. The existing theme refresh timer is separate and unchanged.

Tests: `macos/Tests/TransportFixture.swift` and `macos/Tests/NativeChecks.swift` cover idle/interleaved events, subscribe ordering, burst/in-flight coalescing, stable rows/groups/state, hidden/context/close isolation, worktree/Create preservation and transport failures. Run `make test-macos`.

## Private Rex focus adapter

`RexFocusTracker.swift` reads `Workspace.lastFocusedSession` from
`~/Library/Preferences/com.superlogical.rex.plist`. The value is plist Data
with JSON `{sessionID: ...}`. `FocusFileWatcher.swift` watches the file and
parent directory, including atomic replacement and deletion/recreation.
NSWorkspace activation notifications supply frontmost-app changes. No polling
or UserDefaults loop is used.

Only a frontmost `com.superlogical.rex` app can supply an observation. The
adapter sends its PID and full session ID through the current model's existing
backend, even while the panel is hidden or context changes:

```text
sessions.visit {session_id: string, client_pid: string,
                observed_at: fractional ISO8601 string, initial: boolean} -> {}
```

Go owns asynchronous PID validation,
visit storage, stale-timestamp rejection and presentation ranking. Swift does
not change row order on focus delivery. Duplicate focus pairs are suppressed;
missing/corrupt metadata does not clear history or suppress same-ID recovery.
Pending observations keep their original timestamps on backend/model recovery.
A bounded queue preserves distinct focus transitions while delivery is busy.
The watcher runs for the app lifetime and stops at termination.

`Tests/RexFocusChecks.swift` uses temporary files under `aux/`, an injected
frontmost provider and a private notification center. It covers decoding,
atomic replacement, deletion/recreation, corrupt recovery, gating, stale and
duplicate samples, failed-delivery retry, payloads, hidden/context-changing
models, rapid distinct visits, timestamp precision and close safety. It never
writes user preferences. Live integration requires a frontmost Rex app and a
matching local app peer; validate it with isolated history storage.

## Keys

| Key | Action |
| --- | --- |
| Up / Down, Ctrl+K / Ctrl+J | Select row |
| Enter | Switch session or create from a directory |
| Tab / Shift+Tab | Move keyboard focus; move through enabled form controls |
| Ctrl+O / Ctrl+Shift+O | Cycle open target forward / backward |
| Cmd+Enter in the creation form | Create and open; retry opening if creation already succeeded |
| Ctrl+P | Enter or cancel split mode |
| Split ⌃P in the footer | Enter split mode |
| J/Down or L/Right in split mode | Open below or right |
| Esc in split mode | Cancel split mode |
| Cmd+Shift+P | Show pull request form |
| Cmd+Enter in the PR form | Prepare and open PR; retry Open with the preserved path |
| Esc | Dismiss a popover/split mode first; hide the launcher or return from a nested page |
| Cmd+Q | Hide the resident picker; quit a non-resident app when no mutation is pending |

Creation groups the branch name, searchable local **From branch** picker, read-only Go destination preview, and **Open in** target. Validation waits for branch input. **Create** sends creation, then dispatch. A failed dispatch leaves **Retry opening**, which reuses the created path. Completed branch/base fields stay read-only until Back. Enter in the branch field opens the base picker; Enter in that popover selects only, and Escape dismisses only the popover and restores focus. Tab / Shift+Tab traverses enabled controls. Cmd+Enter submits from the form, never from the popover. Focus callbacks bind to each new model when the warm app reopens.

Use Worktrunk directly for worktree administration. Creation and PR flows use the shared safety checks.

## Synthetic demo

For manual UI QA, launch a packaged app with `--demo` and optional `--mode sessions|dirs|wt-create|pr`, `--repo`, and context flags. This is a separate in-memory backend. It does not start a Process, call Rex or change files. Fixed demo directories, local branches and destination previews support screenshots and keyboard checks. Create changes only in-memory demo data; Open shows a demo notice rather than dispatching or closing.

Important accessibility identifiers:

- `raptor-panel`, `picker-search`, `picker-results`, `path-row:<full path>`
- `open-target`, `open-selected`, `open-pull-request`, `toggle-split`, `keyboard-hint`
- `new-worktree`
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
  macos/Sources/Raptor/FocusFileWatcher.swift \
  macos/Sources/Raptor/RexFocusTracker.swift \
  macos/Sources/Raptor/RexTheme.swift \
  macos/Tests/RexFocusChecks.swift \
  macos/Sources/Raptor/PathDisplay.swift \
  macos/Sources/Raptor/PickerStyle.swift \
  macos/Sources/Raptor/TextEditingShortcuts.swift \
  macos/Sources/Raptor/OutsideClickMonitor.swift \
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

These checks verify persistent requests, partial reads, idle/interleaved notifications, unsubscribe, error recovery, ID mismatch, malformed JSON, EOF, invalid envelopes, blocked-request shutdown and the real 30-second timeout.

## Validation limits

`make test-macos` runs strict Swift 6 headless checks and UI type-checking. `make app` separately builds the packaged executable with production settings. Synthetic tests do not switch user Rex sessions or write user preferences. Intel execution and Apple notarization are not verified.

The resident panel and backend stay warm on dismissal. Outside mouse clicks dismiss it; keyboard focus changes alone do not. Outside dismissal closes popovers and cancels unconfirmed dialogs, never an issued operation. Hide and reopen after a backend transport failure. Cmd+Q hides a resident picker; stop the host with `raptor service stop`. `make install` stops and restarts the host automatically.
