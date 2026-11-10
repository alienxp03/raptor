-- PR opening is native-only by design; with the terminal picker removed the
-- whole action errors outside a local Mac app client.
local real_open = io.open
io.open = function() return nil end
for _, case in ipairs({
 { platform = "macos", transport = "unix", available = true, native = true },
 { platform = "macos", transport = "unix", available = false, error = "native Mac app" },
 { platform = "ios", transport = "tls", available = true, error = "requires the Raptor Mac app" },
 { platform = "macos", transport = "tls", available = true, error = "requires the Raptor Mac app" },
 { platform = "macos", transport = "unix", available = true, kind = "cli", error = "requires the Raptor Mac app" },
}) do
 local actions, commands = {}, {}
 rex = {
  action = function(action) actions[action.name] = action.run end,
  call = function(method)
   assert(method == "client.list")
   return { clients = {{ client_id = "client", info = { platform = case.platform, kind = case.kind or "app" }, principal = { transport = case.transport } }} }
  end,
  session = { new_layer = function() error("PR must not open a terminal layer", 0) end },
  exec = function(args)
   commands[#commands + 1] = args
   return { ok = case.available }
  end,
 }
 dofile("init.lua").setup({ bin = "/demo/raptor" })
 local run = actions.raptor_pr_open
 assert(run ~= nil)
 local ok, result = pcall(run, { session_id = "session", block_id = "block", client_id = "client" })
 if case.native then
  assert(ok and result.ui == "native")
  assert(table.concat(commands[1], "|") == "/demo/raptor|-session|session|-block|block|-client|client|panel|--mode|pr")
 else
  assert(not ok and tostring(result):find(case.error, 1, true), tostring(result))
 end
 assert(not pcall(run, {}))
end
io.open = real_open
print("PR action: passed (native route, non-Mac clients error, missing context)")
