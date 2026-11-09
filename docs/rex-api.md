# Rex API integration

Raptor uses the installed Rex CLI and public APIs. Shared Go code owns discovery, activity projection, and actions. Both pickers use the same data rules.

## Live activity

A persistent `rex do --all` subscription uses public `rex.on` events for each host. It calls `session.attach_all` before reporting readiness, so initial snapshots cannot miss the subscription startup. A change queues a single background snapshot refresh. Usable cached rows remain available; the completed snapshot is published before the UI receives a change notification. Once a snapshot is available, queries only copy and filter the in-memory catalog. Warm queries do not start Rex, SSH, or status scans. This is not periodic status polling. Animation timers only draw working indicators.

The plain `rex events --all --json` command also streams events, but exposes no readiness acknowledgement. The Lua adapter uses the supported attach API instead of a startup-delay timer.

Snapshots use `session.list`, `session.attach`, terminal `program_status`, `title`, and `process`. The Lua batch calls these public APIs in one CLI process. It does not parse terminal output or scan OS processes.

Rex owns status-record lifetime. Raptor does not infer record removal from a separate process snapshot. `done` and `error` remain idle rows until Rex removes the record.

Native program-status titles take priority. The optional Pi name bridge only fills an absent title for a matching local process. A remote PID never reads local Pi name files.

## Custom logic still needed

The installed API has no replacement for these functions:

- **UI theme:** no active UI-palette getter. Keep Go's preference/bundle resolver and fallback. `set_theme` is a setter, not a getter.
- **Exact Pi session name:** no Pi-name lookup. Keep the optional local fallback when no native record title exists. Do not parse status messages as names.
- **Directory history:** `list_dir` browses a directory; it does not return zoxide history or visit scores.
- **Git/worktrees, pins, fuzzy search, target order:** Raptor workflow rules, not Rex server data.
- **Last-session/pane history:** no equivalent MRU-toggle API.
- **Session recent-use order:** no last-used timestamp or selected-session event. An isolated Mac file observer reads the private focus preference. Go validates and stores actual visits; agent `updated_at` is never a proxy for user activity.
- **Native panel lifecycle, geometry, and IPC:** platform integration outside the Rex server API.

Session/tab/split creation, focus, rename, close, and client selection already use supported Rex commands or API methods. A Lua wrapper around those methods is not a separate protocol.

## Audit

Checked the installed API revision 11, CLI help, terminal block schemas, and Mac client actions. Do not infer capability from an undocumented preference or a method name. Query `rex api describe METHOD --json` before adding a new integration. Client labels are not unique, and display hostnames are not server identity.
