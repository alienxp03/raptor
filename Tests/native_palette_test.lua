-- Rex owns rendering/filtering; the shared backend owns catalog and paths.
local real_open = io.open
io.open = function() return nil end
local ctx = { session_id = "S", block_id = "B", client_id = "C" }
local function check(case)
 local actions, requests, queued, commands = {}, {}, {}, {}
 local values, serial = {}, 0
 local function encode(value)
  serial = serial + 1
  local key = "json:" .. serial
  values[key] = value
  return key
 end
 local rows = case.rows or {
  { kind = "session", session_id = "other", label = "Other", host = "mac", is_local = true, is_pinned = true, pin_slot = 2 },
  { kind = "dir", path = "/projects/demo", label = "Demo", host = "mac", is_local = true },
  { kind = "session", session_id = "remote", label = "Other", host = "linux", is_local = false },
 }
 rex = {
  action = function(action) actions[action.name] = action.run end,
  json = { encode = encode, decode = function(value) return values[value] end },
  client = { queue = function(name, args) queued[#queued + 1] = { name = name, args = args } end },
  call = function() return { clients = {{ client_id = "C", info = { kind = "app", platform = "macos" }, principal = { transport = "unix" } }} } end,
  ui = { pick = function(options)
   assert(options.title == "Raptor" and options.allow_other)
   assert(#options.items <= 2000)
   assert(options.items[#options.items].id == "full-picker")
   if not case.rows then
    assert(options.items[1].icon == "star" and options.items[1].detail == "Pin 2")
    assert(options.items[2].icon == "folder")
    assert(options.items[1].id ~= options.items[3].id)
   end
   return case.choice, case.why
  end },
  exec = function(args, options)
   commands[#commands + 1] = args
   if args[#args - 3] == "--mode" or args[8] == "panel" then return { ok = true } end
   assert(args[#args] == "api" and options.timeout == 30)
   local request = values[options.stdin:gsub("\n$", "")]
   assert(request.id == 1)
   requests[#requests + 1] = request
   if case.exec_error then return nil, "cannot launch" end
   if case.bad_reply then return { ok = true, stdout = "bad" } end
   local result = {}
   if request.method == "sessions" then result = { items = rows }
   elseif request.method == "directories.resolve" then
    assert(request.params.query == "~/demo")
    result = { items = {{ path = "/home/test/demo", label = "demo" }} }
   elseif request.method == "sessions.create" then
    assert(request.params.defer_select == true)
    result = { session_id = "created" }
   elseif request.method == "sessions.jump" then
    assert(request.params.host == "linux" and request.params.session_id == "remote")
   else error(request.method) end
   return { ok = true, stdout = encode({ id = 1, result = result, error = case.backend_error }) }
  end,
 }
 dofile("init.lua").setup({ bin = "/test/raptor" })
 local ok, result = pcall(actions.raptor, ctx, {})
 if case.error then
  assert(not ok and tostring(result):find(case.error, 1, true), tostring(result))
  assert(#queued == 0)
 else
  assert(ok, tostring(result))
  if case.selected then
   assert(#queued == 1 and queued[1].name == "session.select")
   assert(queued[1].args.session_id == case.selected)
  else assert(#queued == 0) end
 end
 assert(#requests == (case.requests or 1))
 if case.full then assert(result.ui == "native" and #commands == 2) end
end
check { choice = "row:1", selected = "other" }
check { choice = "row:2", selected = "created", requests = 2 }
check { choice = "row:3", requests = 2 }
check { choice = { text = "~/demo" }, selected = "created", requests = 3 }
check { why = "cancelled" }
check { why = "busy", error = "busy" }
check { why = "unsupported", error = "unsupported" }
check { exec_error = true, error = "cannot launch" }
check { bad_reply = true, error = "invalid backend response" }
check { backend_error = "catalog failed", error = "catalog failed" }
check { choice = "not-a-row", error = "unknown picker result" }
check { choice = "full-picker", full = true }
local many = {}
for i = 1, 2100 do many[i] = { kind = "session", label = "Session", session_id = "s" .. i, is_local = true } end
check { rows = many, why = "cancelled" }
io.open = real_open
print("Native palette: passed (catalog, local/remote navigation, typed paths, cancellation, errors, rich fallback, row limit)")
