-- Instant task uses the shared backend; no picker or app routing involved.
local actions, executions = {}, {}
local failure = false
local pending = false
local queued = {}
rex = {
 action = function(a) actions[a.name] = a.run end,
 session = { describe_block = function() return { block = { owner = "iphone" } } end },
 json = { decode = function(value)
  assert(value == "task-result")
  return { session_id = "new-session", branch = "otter" }
 end },
 call = function(method)
  assert(method == "session.list")
  return { sessions = pending and { { session_id = "new-session", label = "Starting agent…" } } or {} }
 end,
 client = { queue = function(action, args)
  assert(action == "session.select")
  queued[#queued+1] = args.session_id
 end },
 exec = function(command, opts)
  assert(opts.timeout == 30)
  executions[#executions+1] = command
  return { ok = not failure, stdout = failure and "" or "task-result", stderr = failure and "pi missing" or "" }
 end,
}
dofile("init.lua").setup({ bin = "/demo/raptor" })
local run = actions.raptor_worktree_agent
assert(run ~= nil)
local result = run({ session_id = "session", block_id = "origin" })
assert(result.branch == "otter")
local command = executions[#executions]
assert(table.concat(command, "|") == "/demo/raptor|-session|session|-block|origin|-client|iphone|task")
run({ session_id = "session", block_id = "origin", client_id = "mac" })
assert(executions[#executions][7] == "mac")
local count = #executions
pending = true
local duplicate = run({ session_id = "session", block_id = "origin", client_id = "mac" })
assert(duplicate.pending and duplicate.session_id == "new-session")
assert(#executions == count and queued[#queued] == "new-session", "repeat press must focus pending session, not create again")
pending = false
assert(not pcall(run, {}))
assert(not pcall(run, { session_id = "session" }))
assert(#executions == count, "missing context must not start creation")
failure = true
local ok,err = pcall(run,{ session_id = "session", block_id = "origin" })
assert(not ok and tostring(err):find("pi missing",1,true))
print("Instant task action: passed (shared backend, owner fallback, pending-session deduplication, error reporting)")
