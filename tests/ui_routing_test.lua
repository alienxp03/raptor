-- Native app routing must never replace the mobile terminal picker.
local real_open = io.open
local function check(case)
	local actions, executions, layers = {}, {}, {}
	local title_calls = 0
	local app = "/demo/Application Support/Raptor.app"
	io.open = function(path)
		if case.installed and path == app .. "/Contents/Info.plist" then
			return { close = function() end }
		end
		return nil
	end
	rex = {
		action = function(action)
			actions[action.name] = action.run
		end,
		call = function(method)
			assert(method == "client.list")
			return {
				clients = {
					{
						client_id = "demo-client",
						info = { platform = case.platform },
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
		client = { queue = function() end },
		session = {
			describe_block = function()
				return { block = { window_id = "demo-window" } }
			end,
			new_layer = function(options)
				layers[#layers + 1] = options
				return { block_ids = { "picker-block" } }
			end,
			set_block_label = function() end,
			focus_block = function() end,
		},
		exec = function(args, opts)
			assert(opts.timeout == 5)
			executions[#executions + 1] = args
			return { ok = not case.launch_failure }
		end,
	}
	dofile("init.lua").setup({ app = app, ui = case.ui or "auto" })
	local ctx = { session_id = "session:demo&safe", block_id = "block:demo space", client_id = "demo-client" }
	for _, mode in ipairs({ "dirs", "wt" }) do
		local action = mode == "dirs" and "raptor" or "raptor_wt"
		local result = actions[action](ctx, {})
		assert(result.ui == case.expected, case.name .. ": incorrect UI")
		if result.ui == "native" then
			local command = executions[#executions]
			assert(command[1] == "/usr/bin/open" and command[2] == "-g" and command[3] == "-a" and command[4] == app)
			assert(
				command[5]
					== "raptor://picker?mode="
						.. mode
						.. "&session=session%3Ademo%26safe&block=block%3Ademo%20space&client=demo-client"
			)
			assert(
				#command == 5 and title_calls == 0,
				"native launch must reuse the app and skip terminal-title lookups"
			)
		else
			local layer = layers[#layers]
			local command = layer.layout.options.command
			assert(command[#command] == mode)
			local mobile = case.platform == "ios" or case.platform == "ipados"
			assert(layer.bounds[1] == (mobile and 0.04 or 0.28))
		end
	end
	if case.platform ~= "macos" or case.ui == "terminal" or not case.installed or case.transport == "tls" then
		assert(#executions == 0, case.name .. ": native process unexpectedly started")
	end
end

for _, case in ipairs({
	{ name = "Mac native", platform = "macos", installed = true, expected = "native" },
	{ name = "remote Mac", platform = "macos", transport = "tls", installed = true, expected = "terminal" },
	{ name = "iPhone", platform = "ios", installed = true, expected = "terminal" },
	{ name = "iPad", platform = "ipados", installed = true, expected = "terminal" },
	{ name = "unknown client", installed = true, expected = "terminal" },
	{ name = "missing app", platform = "macos", expected = "terminal" },
	{ name = "launch failed", platform = "macos", installed = true, launch_failure = true, expected = "terminal" },
	{ name = "terminal override", platform = "macos", installed = true, ui = "terminal", expected = "terminal" },
}) do
	check(case)
end
io.open = real_open
print("UI routing: passed (Mac native, mobile terminal, missing/failed app fallback)")
