-- Native app routing must never replace the mobile terminal picker.
local real_open = io.open
local function check(case)
	local actions, executions, layers, native_results = {}, {}, {}, {}
	local title_calls = 0
	local picker_open = false
	local queued = {}
	local app = "/demo/Application Support/Raptor.app"
	local bin = os.getenv("HOME") .. "/.local/bin/raptor"
	io.open = function(path)
		if case.installed and path == app .. "/Contents/Info.plist" then
			return { close = function() end }
		end
		return nil
	end
	rex = {
		action = function(action)
			assert(action.name ~= "raptor_agents" and action.name ~= "raptor_worktree_list",
				"Obsolete browsers must not be registered")
			actions[action.name] = action.run
		end,
		call = function(method, args)
			if method == "client.perform" then
				assert(case.function_binding and args.client_id == "demo-client")
				assert(args.action == "session.select" and args.block_id == "picker-block")
				queued[#queued + 1] = { action = args.action, args = args.args }
				return { performed_by = args.client_id }
			end
			assert(method == "client.list")
			return {
				clients = {
					{
						client_id = "demo-client",
						info = { platform = case.platform, kind = case.kind or "app" },
						principal = { transport = case.transport or "unix" },
					},
				},
			}
		end,
		block = {
			call = function()
				title_calls = title_calls + 1
				return { title = "demo terminal" }
			end,
		},
		layout = {
			block = function(options)
				return options
			end,
		},
		client = {
			queue = function(action, args)
				queued[#queued + 1] = { action = action, args = args }
			end,
		},
		session = {
			describe_block = function()
				return { block = { window_id = "demo-window", label = picker_open and "raptor" or "shell", owner = case.function_binding and "demo-client" or nil } }
			end,
			new_layer = function(options)
				layers[#layers + 1] = options
				return { block_ids = { "picker-block" } }
			end,
			set_block_label = function() end,
			focus_block = function() end,
		},
		native_ok = function(args)
			if args[8] == "panel" then
				-- The resident host needs its app; a stale install cannot serve.
				if case.panel_failure then return false end
				return (case.host_running or case.installed) and not case.launch_failure
			end
			return case.installed and not case.launch_failure
		end,
		exec = function(args, opts)
			assert(opts.timeout == 5)
			executions[#executions + 1] = args
			local ok = rex.native_ok(args)
			native_results[#executions] = ok
			return { ok = ok }
		end,
	}
	dofile("init.lua").setup({ bin = bin, app = app, ui = case.ui or "auto" })
	assert(actions.raptor_wt == nil, "Legacy worktree list must not clutter the palette")
	assert(actions.raptor_create == nil, "Legacy create must not clutter the palette")
	local ctx = { session_id = "session:demo&safe", block_id = "block:demo space", client_id = "demo-client" }
	if case.function_binding then ctx.client_id = nil end
	assert(actions.raptor_sessions == nil, "The launcher must have one action")
	for _, mode in ipairs({ "dirs", "wt-create", "pr" }) do
		local action = ({ dirs = "raptor", ["wt-create"] = "raptor_worktree_new", pr = "raptor_pr_open" })[mode]
		local ok, result = pcall(actions[action], ctx, {})
		if mode == "pr" and case.expected ~= "native" then
			assert(not ok and tostring(result):find("native Mac app", 1, true), case.name .. ": PR must stay native-only")
			assert(#layers == 2, "PR must not add a terminal layer")
			break
		end
		if case.expected_error then
			assert(not ok and tostring(result):find("GUI requested", 1, true), case.name .. ": expected GUI error")
			assert(#layers == 0, "Forced GUI must not fall back to terminal")
			return
		end
		assert(ok, tostring(result))
		assert(result.ui == case.expected, case.name .. ": incorrect UI")
		if result.ui == "native" then
			local command = executions[#executions]
			if case.panel_failure then
				assert(
					command[1] == "/usr/bin/open" and command[2] == "-g" and command[3] == "-a" and command[4] == app,
					"panel failure must fall back to Launch Services"
				)
				assert(
					command[5]
						== "raptor://picker?mode="
							.. mode
							.. "&session=session%3Ademo%26safe&block=block%3Ademo%20space&client=demo-client"
				)
				assert(#command == 5)
			else
				-- Fast path: resident panel host over IPC.
				assert(command[1] == bin, "native open must try IPC first")
				assert(command[2] == "-session" and command[3] == ctx.session_id)
				assert(command[4] == "-block" and command[5] == ctx.block_id)
				assert(command[6] == "-client" and command[7] == "demo-client")
				assert(command[8] == "panel", "global context must precede the subcommand")
				assert(command[9] == "--mode" and command[10] == mode)
				assert(#command == 10, "native IPC must omit unsupported open argument, title and repo flags")
			end
			assert(title_calls == 0, "native launch must skip terminal-title lookups")
		else
			local layer = layers[#layers]
			local command = layer.layout.options.command
			if mode == "wt-create" then
				assert(command[#command - 1] == "wt" and command[#command] == "--create")
			else
				assert(command[#command] == mode)
			end
			assert(command[3] == ctx.session_id and command[5] == ctx.block_id)
			local mobile = case.platform == "ios" or case.platform == "ipados"
			assert(layer.bounds[1] == (mobile and 0.04 or 0.28))
		end
	end
	local launcher = actions.raptor_launcher(ctx, {})
	assert(launcher.ui == "terminal", "Experimental launcher must stay terminal-only")
	local launcher_command = layers[#layers].layout.options.command
	assert(launcher_command[#launcher_command] == "launcher")
	local layer_count = #layers
	picker_open = true
	actions.raptor_worktree_new(ctx)
	assert(#layers == layer_count, "Ctrl+N inside a picker must not nest layers")
	assert(queued[#queued].action == "pane.send_key" and queued[#queued].args.key == "ctrl+n")
	if case.ui ~= "gui" and (case.platform ~= "macos" or case.kind == "cli" or case.ui == "terminal" or (not case.installed and not case.host_running) or case.transport == "tls") then
		for _, ok in ipairs(native_results) do
			assert(not ok, case.name .. ": native process unexpectedly started")
		end
	end
end

for _, case in ipairs({
	{ name = "Mac native", platform = "macos", installed = true, expected = "native" },
	{ name = "Mac function binding without client ID", platform = "macos", installed = true, function_binding = true, expected = "native" },
	{ name = "Mac native panel failure falls back to Launch Services", platform = "macos", installed = true, panel_failure = true, expected = "native" },
	{ name = "resident host without app bundle", platform = "macos", host_running = true, expected = "native" },
	{ name = "Mac-hosted CLI is not a viewing app", platform = "macos", kind = "cli", installed = true, expected = "terminal" },
	{ name = "remote Mac", platform = "macos", transport = "tls", installed = true, expected = "terminal" },
	{ name = "iPhone", platform = "ios", installed = true, expected = "terminal" },
	{ name = "iPhone function binding without client ID", platform = "ios", installed = true, function_binding = true, expected = "terminal" },
	{ name = "iPad", platform = "ipados", installed = true, expected = "terminal" },
	{ name = "iPad function binding without client ID", platform = "ipados", installed = true, function_binding = true, expected = "terminal" },
	{ name = "remote Mac function binding without client ID", platform = "macos", transport = "tls", installed = true, function_binding = true, expected = "terminal" },
	{ name = "unknown client", installed = true, expected = "terminal" },
	{ name = "missing app", platform = "macos", expected = "terminal" },
	{ name = "launch failed", platform = "macos", installed = true, launch_failure = true, expected = "terminal" },
	{ name = "terminal override", platform = "macos", installed = true, ui = "terminal", expected = "terminal" },
	{ name = "forced GUI from CLI", platform = "macos", kind = "cli", installed = true, ui = "gui", expected = "native" },
	{ name = "forced GUI from iPhone", platform = "ios", transport = "tailscale", installed = true, ui = "gui", expected = "native" },
	{ name = "forced GUI without app", platform = "macos", ui = "gui", expected_error = true },
	{ name = "forced GUI launch failure", platform = "macos", installed = true, launch_failure = true, ui = "gui", expected_error = true },
}) do
	check(case)
end
io.open = real_open
print("UI routing: passed (resident IPC, Launch Services fallback, mobile terminal, missing/failed app fallback)")
