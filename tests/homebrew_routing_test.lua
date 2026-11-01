-- A package upgrade must use stable opt paths, without editing user config.
local real_open, real_getenv = io.open, os.getenv
for _, prefix in ipairs({ "/opt/homebrew", "/usr/local", "/custom/homebrew" }) do
	local actions, command, launched = {}, nil, nil
	local app = prefix .. "/opt/raptor/libexec/Raptor.app"
	local bin = prefix .. "/opt/raptor/bin/raptor"
	os.getenv = function(key)
		if key == "HOMEBREW_PREFIX" then
			return prefix == "/custom/homebrew" and prefix or nil
		end
		return real_getenv(key)
	end
	io.open = function(path)
		if path == bin or path == app .. "/Contents/Info.plist" or path == "/custom/Raptor.app/Contents/Info.plist" then
			return { close = function() end }
		end
		return nil
	end
	rex = {
		action = function(action)
			actions[action.name] = action.run
		end,
		call = function()
			return {
				clients = { { client_id = "C", info = { platform = "macos", kind = "app" }, principal = { transport = "unix" } } },
			}
		end,
		block = {
			call = function()
				return { title = "terminal" }
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
				return { block = { window_id = "W" } }
			end,
			new_layer = function(options)
				command = options.layout.options.command
				return { block_ids = {} }
			end,
		},
		exec = function(args)
			launched = args
			return { ok = true }
		end,
	}
	local ctx = { session_id = "S", block_id = "B", client_id = "C" }
	local plugin = dofile("init.lua")
	plugin.setup({ ui = "terminal" })
	assert(actions.raptor(ctx, {}).ui == "terminal" and command[1] == bin)
	plugin.setup({})
	assert(actions.raptor(ctx, {}).ui == "native" and launched[1] == bin and launched[2] == "panel",
		"Native open must use the stable opt CLI over IPC")
	plugin.setup({ ui = "terminal", bin = "/custom/raptor" })
	actions.raptor(ctx, {})
	assert(command[1] == "/custom/raptor", "Explicit CLI must override package discovery")
	plugin.setup({ app = "/custom/Raptor.app" })
	actions.raptor(ctx, {})
	assert(launched[1] == bin and launched[2] == "panel",
		"Explicit app must override package discovery for the Launch Services fallback")
	plugin.setup({ app = "/custom/Raptor.app", bin = "/custom/raptor" })
	local host_down = rex.exec
	rex.exec = function(args)
		launched = args
		if args[2] == "panel" then return { ok = false } end
		return { ok = true }
	end
	actions.raptor(ctx, {})
	assert(launched[4] == "/custom/Raptor.app", "Panel failure must fall back to the explicit app")
	rex.exec = host_down
end
io.open, os.getenv = real_open, real_getenv
print("Homebrew routing: passed (Apple Silicon, Intel, custom prefix, explicit overrides)")
