-- Direct pinned jumps never inspect clients, show a panel, or bind keys.
local actions, executions = {}, {}
local failure, missing, owner = false, false, "owner-client"
rex = {
 action = function(a) actions[a.name] = a.run end,
 bind = function() error("setup must not bind keys") end,
 call = function() error("no client or directory scans") end,
 session = { describe_block = function(args)
  assert(args.block_id == "origin")
  return { block = { owner = owner } }
 end },
 exec = function(command, options)
  assert(options.timeout == 30)
  assert(command[#command - 1] == "pinned-session", "must not open panel")
  executions[#executions + 1] = command
  if missing then return nil, "exec unavailable" end
  return { ok = not failure, stdout = failure and "" or "session:target\n", stderr = failure and "slot closed" or "" }
 end,
}
dofile("init.lua").setup({ bin = "/demo/raptor" })
for slot = 1, 9 do
 local run = assert(actions["raptor_pin_" .. slot])
 local ctx = { session_id = "session", block_id = "origin" }
 assert(run(ctx).selected == "session:target")
 assert(ctx.client_id == nil, "owner resolution must not mutate original context")
 assert(table.concat(executions[#executions], "|") ==
  "/demo/raptor|-session|session|-block|origin|-client|owner-client|pinned-session|" .. slot)
 run({ session_id = "session", block_id = "origin", client_id = "explicit" })
 assert(executions[#executions][7] == "explicit")
end
local run = actions.raptor_pin_1
local count = #executions
for _, ctx in ipairs({ {}, { session_id = "session" }, { client_id = "client" }, { session_id = "", client_id = "client" } }) do
 local ok, err = pcall(run, ctx)
 assert(not ok and tostring(err):find("context", 1, true))
end
owner = nil
assert(not pcall(run, { session_id = "session", block_id = "origin" }))
assert(#executions == count)
failure = true
local ok, err = pcall(run, { session_id = "session", client_id = "client" })
assert(not ok and tostring(err):find("slot closed", 1, true))
missing = true
ok, err = pcall(run, { session_id = "session", client_id = "client" })
assert(not ok and tostring(err):find("exec unavailable", 1, true))
print("Pinned session actions: passed (9 slots, owner context, failures, no picker/bindings)")
