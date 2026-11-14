-- Validate via the backend once; warm local jumps must not spawn processes.
local actions, executions, queued = {}, {}, {}
local failure, missing, owner, host = false, false, "owner-client", ""
local source, live, listingFailure = "pins-v1", true, false
local scans = 0
local real_open = io.open
io.open = function(path, mode)
 if path == os.getenv("HOME") .. "/Library/Application Support/raptor/state.json" then
  if not source then return nil end
  return { read = function() return source end, close = function() end }
 end
 return real_open(path, mode)
end
rex = {
 action = function(a) actions[a.name] = a.run end,
 bind = function() error("setup must not bind keys") end,
 call = function(method)
  assert(method == "session.list", "no client or directory scans")
  scans = scans + 1
  if listingFailure then return nil, "server unavailable" end
  return { sessions = live and { { session_id = "session:target" } } or { { session_id = "session:target-other" } } }
 end,
 session = { describe_block = function(args)
  assert(args.block_id == "origin")
  return { block = { owner = owner } }
 end },
 json = { decode = function(value)
  if value == "resolved-pin" then return { sessionID = "session:target", host = host } end
  local slot = tonumber(value:match("pins%-v(%d+)")) or 1
  return { session_pins = { { sessionID = "session:target", host = "", slot = slot } } }
 end },
 client = { queue = function(action, args)
  assert(action == "session.select")
  assert(args.session_id == "session:target")
  queued[#queued + 1] = args
 end },
 exec = function(command, options)
  assert(options.timeout == 30)
  local resolve = command[#command] == "--resolve"
  assert(command[#command - (resolve and 2 or 1)] == "pinned-session", "must not open panel")
  if host == "" then assert(resolve, "local selection must not call back into the waiting client") end
  executions[#executions + 1] = table.concat(command, "|")
  if missing then return nil, "exec unavailable" end
  return { ok = not failure, stdout = failure and "" or (resolve and "resolved-pin" or "session:target\n"), stderr = failure and "slot closed" or "" }
 end,
}
dofile("init.lua").setup({ bin = "/demo/raptor" })
for slot = 1, 9 do
 local run = assert(actions["raptor_pin_" .. slot])
 local ctx = { session_id = "session", block_id = "origin" }
 assert(run(ctx).selected == "session:target")
 assert(ctx.client_id == nil, "owner resolution must not mutate original context")
 assert(executions[#executions] ==
  "/demo/raptor|-session|session|-block|origin|-client|owner-client|pinned-session|" .. slot .. "|--resolve")
 local count = #executions
 run({ session_id = "session", block_id = "origin", client_id = "explicit" })
 assert(#executions == count, "warm jumps must spawn no processes")
end
assert(#executions == 9 and scans == 9 and #queued == 18)
local run = actions.raptor_pin_1
local ctx = { session_id = "session", client_id = "client" }
local function fails(message)
 local count = #queued
 local ok, err = pcall(run, ctx)
 assert(not ok and tostring(err):find(message, 1, true), tostring(err))
 assert(#queued == count, "failures must never queue selection")
end
live = false
fails("closed or missing")
listingFailure = true
fails("server unavailable")
live, listingFailure = true, false
assert(#executions == 9, "liveness failures must not spawn a replacement or picker")

-- Recency edits preserve the cache; changes to pins invalidate it.
source = "recency-only"
run(ctx)
assert(#executions == 9, "recency changes must not invalidate pinned-session identities")
source = "pins-v2"
run(ctx)
assert(#executions == 10)
source, failure = nil, true
fails("slot closed")
source, failure = "pins-v3", false
run(ctx)
assert(#executions == 12)
missing, source = true, "pins-v4"
fails("exec unavailable")
missing = false

-- Remote routing is not cached and must retain its host-specific behavior.
host, source = "remote", "remote-pins"
local before, queueCount = #executions, #queued
run(ctx)
run(ctx)
assert(#executions == before + 4)
assert(executions[#executions]:match("|pinned%-session|1$"))
assert(#queued == queueCount, "remote routing must not select a local session")
host = ""

local count = #executions
for _, invalid in ipairs({ {}, { session_id = "session" }, { client_id = "client" }, { session_id = "", client_id = "client" } }) do
 local ok, err = pcall(run, invalid)
 assert(not ok and tostring(err):find("context", 1, true))
end
owner = nil
assert(not pcall(run, { session_id = "session", block_id = "origin" }))
assert(#executions == count)
io.open = real_open
print("Pinned session actions: passed (9 slots, zero-process warm jumps, fresh liveness, pin-only invalidation, remote routing, failures)")
