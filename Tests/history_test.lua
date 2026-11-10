-- Run from the repository root: lua tests/history_test.lua
local actions, commands = {}, {}
local failure
local ctx = { client_id = "client", session_id = "current-session", block_id = "current-pane" }
rex = {
	action = function(action) actions[action.name] = action.run end,
	exec = function(command)
		commands[#commands + 1] = command
		if failure == "spawn" then return nil, "could not start backend" end
		return { ok = failure == nil, stdout = failure and "" or "previous-session\n", stderr = failure and "selection failed" or "" }
	end,
	session = {
		describe_block = function()
			return { block = { owner = "owner-client" } }
		end,
	},
}
dofile("init.lua").setup({ bin = "/test/raptor" })
assert(actions.raptor_pane_last == nil, "Last Pane must not be registered")
assert(actions.raptor_last_pane == nil, "legacy Last Pane must not be registered")
local result = actions.raptor_session_last(ctx)
assert(result.selected == "previous-session")
assert(table.concat(commands[1], " ") == "/test/raptor -session current-session -block current-pane -client client last-session")
result = actions.raptor_session_last({ session_id = "current-session", block_id = "current-pane" })
assert(result.selected == "previous-session")
assert(table.concat(commands[2], " "):find("-client owner-client", 1, true))
for _, stage in ipairs({ "spawn", "select" }) do
	failure = stage
	assert(not pcall(actions.raptor_session_last, ctx), "backend failure must be reported")
end
assert(not pcall(actions.raptor_session_last, {}))
print("history actions: passed (shared backend, no Last Pane)")
