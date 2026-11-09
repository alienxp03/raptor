# Pull request flow

Public API:

```go
Resolve(repo, input string) (Info, error) // read-only; repo is local context
Prepare(repo, input string) (Info, error) // clone base + wt switch --no-hooks
Ready(path string) bool // registered instance + bound setup journal permit Open
Open(path, target string, ctx rex.Ctx) (OpenResult, error)
Setup(path string, retry bool) error
```

`Info` has flat JSON fields: `input`, `url`, `number`, `title`, `branch`, `repo`,
`path`, `clone_required`, `existing`. `repo` is the primary local clone.
`path` is empty until a clone exists and Worktrunk can compute its destination.
Pass the original selected repository/worktree context to Prepare, not the returned
primary `Info.Repo`, when the source worktree hook context must be preserved.
`OpenResult` retains path and all known IDs on error. Its optional `error` field
matches the returned error. Do not discard either result on error.

## Parent CLI contract

Wire `raptor setup --path PATH [--retry]` to `Setup`. Return a nonzero status on
error, without replacing the process with Setup. Open starts this command through
an explicit shell wrapper:

```text
trap ':' INT; <os.Executable()> setup --path PATH; exec "${SHELL:-/bin/sh}" -l
```

Thus setup success, refusal, failure, or terminal interrupt ends in a usable login shell.
Use `Ready`, not registration alone, before offering recovery through Open. False
means Prepare must run first (or another operation holds the journal lock). Ready
is a snapshot; Open checks the instance again under lock. An unbound journal from
a crash between switch and save must be resumed through Prepare. No command
is injected into an existing shell. Session/tab creation records IDs before
selection. Setup starts in the destination terminal and waits for a durable gate.
Open releases the gate after the selection request succeeds. Selection is queued;
this is not proof of visual focus. The gate waits at most two minutes. If it times
out, retry Open, then run the printed setup retry command in that terminal.

Only `session` and `tab` are accepted. Supply `ctx.Client`; tabs also require
`ctx.Session`. A repeated Open reuses recorded IDs, checks their worktree cwd,
and requests selection. It never finds a destination by label.

## State and hooks

State: `$XDG_STATE_HOME/raptor/pullrequest` or
`~/.local/state/raptor/pullrequest`. JSON and advisory locks use the canonical
worktree path, including symlink ancestors before creation. Files are private;
updates use sync + atomic rename. Locks prevent concurrent setup. A preparation
journal precedes worktree creation. An interrupted creation keeps setup pending.
A failed switch that returns a worktree still records that resource. Bound journals
include the Git registration identity, not just its path. Prepare resets stages,
completion, gate, and Rex IDs for a replacement registration. Open and Setup reject
stale registrations. An unbound pre-switch journal retains pending creation hooks
when Prepare resumes after a crash.

New worktree: foreground `pre-start`, background `post-start`, background
`post-switch`. Existing worktree: `post-switch` only. Completed setup is not run
again. A retry resumes the failed stage, not resource creation. An interrupted
foreground stage requires explicit retry. An uncertain background launch is not
replayed automatically: inspect `wt config state logs` and recover manually.
Background launch success is not a server-health check.

Manual hooks use terminal stdio and never `--yes`. Approval state is checked after
each stage; declined project hooks are not reported as success. Source branch,
source path, destination, and PR variables are passed through `--var`. Verified
with installed Worktrunk v0.81.0: the deprecated explicit form binds unused
variables without forwarding them into `{{ args }}`. The newer `--KEY=VALUE`
form changes hook arguments when a variable is unused, so it is not used here.

## Explicit safety limits

- GitHub HTTPS PR URLs only; a number requires local repository context.
- Non-bare clones with a matching GitHub `origin` only. Discover through context,
  current directory, agreed clone destination, then zoxide. No directory scan.
- The base repository comes from `gh api`; metadata comes from `gh pr view`.
  A supplied context with a different origin is rejected, including fork clones.
- Missing clones use `~/workspace/<owner>/<repo>`. Claim the directory atomically
  and persist directory ownership before cloning. An unchanged owned empty
  directory can be retried. Birth-time identity also permits retry after Git
  removes its own failed clone files; older Linux filesystems without birth time
  fail closed on directory changes. A discovered clone must have matching origin
  and a valid HEAD before preparation resumes. Never remove partial or unrelated
  data. Other partial clones require manual inspection. Commands have a two-minute
  bound, process-group cancellation, and bounded pipe drain on macOS/Linux.
- REST requests explicitly select `github.com`; clone URLs also name that host.
- Prepare cannot prompt safely before a destination terminal exists. Any configured
  source `pre-switch` hook causes refusal before worktree creation. Run Worktrunk
  interactively first; do not move that hook after mutation or bypass approval.
- Deferred source and destination project configs must match byte-for-byte.
  Source project and effective user/system config must remain unchanged since
  Prepare. Effective paths come from `wt config show --format=json`, including
  `WT_PROJECT_CONFIG_PATH`; stamps include metadata and file content. Otherwise
  stop for manual setup, rather than run with changed trust or
  config semantics. Source context includes the selected linked worktree.
- A lost Rex create response is reconciled only if exactly one terminal has the
  canonical worktree cwd. Scan all reported blocks; missing listing/cwd data is
  uncertain. Zero/multiple matches stop for inspection; no second create is
  attempted for a crash, timeout, or malformed success response. A completed
  explicit create failure without returned IDs permits retry only after a full
  authoritative zero-match scan. A closed destination or changed cwd also stops.
  Resources are never destroyed or silently replaced. Reconciliation can select
  an already present terminal; use the printed setup command if no runner remains.
- Crash-safe state is not transactional execution of arbitrary shell hooks. A
  foreground retry can repeat commands that ran before failure. Background hooks
  remain Worktrunk-managed and report their log location.

## Checks

Tests use local Git fixtures and fake `gh`, `wt`, and `rex`; no network or live Rex
mutation. They cover resolution, origin checks, base cloning, occupied paths,
source context, new/existing setup, partial switch, selection recovery, canonical
identity, locking, declined approval, config mismatch, and interrupted background
launches.

```sh
go test -race ./internal/pullrequest
go vet ./internal/pullrequest
go build ./...
```
