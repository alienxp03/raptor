-- PR opening is native-only: never create an unsupported terminal form.
local real_open = io.open
io.open = function() return nil end
for _, case in ipairs({
 { platform = "macos", transport = "unix", ui = "auto", available = true, native = true },
 { platform = "macos", transport = "unix", ui = "auto", available = false },
 { platform = "macos", transport = "unix", ui = "terminal", available = true },
 { platform = "ios", transport = "tls", ui = "auto", available = true },
 { platform = "macos", transport = "tls", ui = "auto", available = true },
 { platform = "ios", transport = "tls", ui = "gui", available = true, native = true },
}) do
 local actions, commands = {}, {}
 rex = {
  action = function(action) actions[action.name] = action.run end,
  call = function(method)
   assert(method == "client.list")
   return { clients = {{ client_id = "client", info = { platform = case.platform, kind = "app" }, principal = { transport = case.transport } }} }
  end,
  session = { new_layer = function() error("PR must not open a terminal layer") end },
  exec = function(args)
   commands[#commands + 1] = args
   return { ok = case.available }
  end,
 }
 dofile("init.lua").setup({ ui = case.ui, bin = "/demo/raptor" })
 local run = actions.raptor_pr_open
 assert(run ~= nil)
 local ok, result = pcall(run, { session_id = "session", block_id = "block", client_id = "client" })
 if case.native then
  assert(ok and result.ui == "native")
  assert(table.concat(commands[1], "|") == "/demo/raptor|-session|session|-block|block|-client|client|panel|--mode|pr")
 else
  assert(not ok and tostring(result):find("native Mac app", 1, true))
 end
 assert(not pcall(run, {}))
end
io.open = real_open
print("PR action: passed (native route, no terminal fallback, missing context)")
