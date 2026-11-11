-- Discovery is setup-time, paired, upgrade-safe, and independent of Rex's PATH.
-- Routing is native-only: a client viewing this Mac gets the bare host picker;
-- anything else gets a clear error. No terminal layers, no app bundle, no ui
-- option, no Launch Services fallback.
local real_open, real_getenv, real_debug, real_searchpath = io.open, os.getenv, debug, package.searchpath
local file = assert(real_open("init.lua", "r"))
local source = file:read("*a")
file:close()
local ctx = { session_id = "S", block_id = "B", client_id = "C" }
local home = "/test/home"
local function check(case)
	local actions, commands = {}, {}
	local files = case.files or {}
	os.getenv = function(key)
		if key == "HOME" then return home end
		if key == "HOMEBREW_PREFIX" then return case.prefix end
		-- Restricted Rex environment: neither PATH nor shell tools are needed.
		return nil
	end
	io.open = function(path)
		if files[path] then return { close = function() end } end
		return nil
	end
	if case.no_debug then
		debug = nil
		package.searchpath = function(name)
			assert(name == "raptor")
			return case.source
		end
	end
	rex = {
		action = function(action)
			assert(action.name ~= "raptor_agents" and action.name ~= "raptor_worktree_list" and action.name ~= "raptor_launcher")
			actions[action.name] = action.run
		end,
		call = function()
			return { clients = {{ client_id = "C", info = { platform = case.platform or "macos", kind = case.kind or "app" }, principal = { transport = case.transport or "unix" } }} }
		end,
		layout = { block = function() error("no terminal layers", 0) end },
		client = { queue = function() end },
		session = {
			new_layer = function() error("the terminal picker was removed", 0) end,
		},
		exec = function(args, options)
			assert(options.timeout == 5)
			commands[#commands + 1] = args
			if args[8] == "panel" then return { ok = case.ipc == true } end
			assert(args[1] == "/usr/bin/open", "Discovery must not invoke brew, a shell, or PATH tools")
			if case.nil_launch then return nil end
			return { ok = case.launch == true }
		end,
	}
	local plugin = assert(load(source, "@" .. (case.source or "/checkout/init.lua")))()
	if case.unknown_option then
		local ok, err = pcall(plugin.setup, case.unknown_option)
		assert(not ok and tostring(err):find("unknown option", 1, true), case.name .. ": " .. tostring(err))
		io.open, os.getenv, debug, package.searchpath = real_open, real_getenv, real_debug, real_searchpath
		return
	end
	plugin.setup(case.options or {})
	local ok, result = pcall(actions.raptor, ctx, {})
	if case.error then
		assert(not ok and tostring(result):find(case.error, 1, true), case.name .. ": " .. tostring(result))
	else
		assert(ok and result.ui == "native", case.name .. ": " .. tostring(result))
	end
	assert(#commands == (case.commands or 0), case.name .. ": unexpected launch count " .. #commands)
	if case.panel_bin then
		assert(commands[1] and commands[1][1] == case.panel_bin and commands[1][8] == "panel", case.name .. ": IPC must be first and paired")
	end
	io.open, os.getenv, debug, package.searchpath = real_open, real_getenv, real_debug, real_searchpath
end

for _, prefix in ipairs({ "/opt/homebrew", "/usr/local", "/custom/homebrew" }) do
	local root = prefix .. "/opt/raptor"
	local bin = root .. "/bin/raptor"
	local files = { [bin] = true }
	local env = prefix == "/custom/homebrew" and prefix or nil
	check { name = prefix .. " IPC", prefix = env, files = files, ipc = true, commands = 1, panel_bin = bin }
	check { name = prefix .. " host missing still errors clearly", prefix = env, files = files, ipc = false, commands = 1, panel_bin = bin,
		error = "the native picker could not be opened" }
	check { name = prefix .. " iPhone client", prefix = env, files = files, platform = "ios", error = "requires the native picker" }
	check { name = prefix .. " remote Mac client", prefix = env, files = files, transport = "tls", error = "requires the native picker" }
	check { name = prefix .. " server CLI client", prefix = env, files = files, kind = "cli", error = "requires the native picker" }
	-- Loaded module wins over env and standard prefixes, including resolved Cellar paths.
	for _, location in ipairs({ root .. "/share/raptor/init.lua", prefix .. "/Cellar/raptor/1.2.3/share/raptor/init.lua" }) do
		local competing = { ["/opt/homebrew/opt/raptor/bin/raptor"] = true, [bin] = true }
		check { name = location, source = location, prefix = "/other/brew", files = competing, commands = 1, panel_bin = bin, ipc = true }
		check { name = location .. " restricted Lua", source = location, no_debug = true, files = competing, commands = 1, panel_bin = bin, ipc = true }
	end
end
check { name = "missing module package cannot select another install", source = "/custom/opt/raptor/share/raptor/init.lua", files = { ["/opt/homebrew/opt/raptor/bin/raptor"] = true }, commands = 1, panel_bin = "/custom/opt/raptor/bin/raptor", error = "could not be opened" }
local standalone = home .. "/.local/bin/raptor"
check { name = "standalone CLI IPC spawns the host on demand", commands = 1, panel_bin = standalone, ipc = true }
check { name = "standalone CLI host failure errors clearly", commands = 1, panel_bin = standalone, ipc = false, error = "could not be opened" }
check { name = "app option removed", unknown_option = { app = "/somewhere/Raptor.app" } }
check { name = "ui option removed", unknown_option = { ui = "terminal" } }
check { name = "explicit bin", files = { ["/opt/homebrew/opt/raptor/bin/raptor"] = true }, options = { bin = "/custom/cli" }, commands = 1, panel_bin = "/custom/cli", ipc = true }
print("Homebrew routing: passed (stable opt, module-relative/custom prefix, standalone CLI, overrides, IPC, native-only routing, removed options)")
