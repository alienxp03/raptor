-- Discovery is setup-time, paired, upgrade-safe, and independent of Rex's PATH.
local real_open, real_getenv, real_debug, real_searchpath = io.open, os.getenv, debug, package.searchpath
local file = assert(real_open("init.lua", "r"))
local source = file:read("*a")
file:close()
local ctx = { session_id = "S", block_id = "B", client_id = "C" }
local home = "/test/home"
local function check(case)
	local actions, commands, layers = {}, {}, {}
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
			assert(action.name ~= "raptor_agents" and action.name ~= "raptor_worktree_list")
			actions[action.name] = action.run
		end,
		call = function()
			return { clients = {{ client_id = "C", info = { platform = case.platform or "macos", kind = "app" }, principal = { transport = "unix" } }} }
		end,
		block = { call = function() return { title = "terminal" } end },
		layout = { block = function(options) return options end },
		client = { queue = function() end },
		session = {
			describe_block = function() return { block = { window_id = "W" } } end,
			new_layer = function(options)
				layers[#layers + 1] = options.layout.options.command
				return { block_ids = {} }
			end,
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
	plugin.setup(case.options or {})
	local ok, result = pcall(actions.raptor, ctx, {})
	if case.error then
		assert(not ok and tostring(result):find("GUI requested", 1, true), case.name)
		assert(#layers == 0)
	else
		assert(ok and result.ui == (case.native and "native" or "terminal"), case.name .. ": " .. tostring(result))
	end
	assert(#commands == (case.commands or 0), case.name .. ": unexpected launch count " .. #commands)
	if case.panel_bin then
		assert(commands[1][1] == case.panel_bin and commands[1][8] == "panel", case.name .. ": IPC must be first and paired")
	end
	if case.open then
		local command = commands[#commands]
		assert(command[3] == case.open[1] and command[4] == case.open[2], case.name .. ": wrong app")
		assert(command[5] == "raptor://picker?mode=dirs&session=S&block=B&client=C")
		assert(#command == 5 and command[2] == "-g")
	end
	if #layers > 0 then assert(layers[1][1] == case.bin, case.name .. ": wrong terminal CLI") end
	io.open, os.getenv, debug, package.searchpath = real_open, real_getenv, real_debug, real_searchpath
end

for _, prefix in ipairs({ "/opt/homebrew", "/usr/local", "/custom/homebrew" }) do
	local root = prefix .. "/opt/raptor"
	local bin, app = root .. "/bin/raptor", root .. "/libexec/Raptor.app"
	local files = { [bin] = true, [app .. "/Contents/Info.plist"] = true }
	local env = prefix == "/custom/homebrew" and prefix or nil
	check { name = prefix .. " IPC", prefix = env, files = files, ipc = true, native = true, commands = 1, panel_bin = bin }
	check { name = prefix .. " paired launch", prefix = env, files = files, launch = true, native = true, commands = 2, panel_bin = bin, open = { "-a", app } }
	check { name = prefix .. " terminal", prefix = env, files = files, options = { ui = "terminal" }, bin = bin }
	check { name = prefix .. " mobile", prefix = env, files = files, platform = "ios", bin = bin }
	check { name = prefix .. " launch failure", prefix = env, files = files, commands = 2, panel_bin = bin, open = { "-a", app }, bin = bin }
	check { name = prefix .. " missing paired app", prefix = env, files = { [bin] = true }, commands = 1, panel_bin = bin, bin = bin }
	-- Loaded module wins over env and standard prefixes, including resolved Cellar paths.
	for _, location in ipairs({ root .. "/share/raptor/init.lua", prefix .. "/Cellar/raptor/1.2.3/share/raptor/init.lua" }) do
		local competing = { ["/opt/homebrew/opt/raptor/bin/raptor"] = true, [bin] = true, [app .. "/Contents/Info.plist"] = true }
		check { name = location, source = location, prefix = "/other/brew", files = competing, commands = 2, panel_bin = bin, native = true, launch = true, open = { "-a", app } }
		check { name = location .. " restricted Lua", source = location, no_debug = true, files = competing, commands = 1, panel_bin = bin, native = true, ipc = true }
	end
end
check { name = "missing module package cannot select another install", source = "/custom/opt/raptor/share/raptor/init.lua", files = { ["/opt/homebrew/opt/raptor/bin/raptor"] = true }, commands = 1, panel_bin = "/custom/opt/raptor/bin/raptor", bin = "/custom/opt/raptor/bin/raptor" }
local standalone = home .. "/.local/bin/raptor"
check { name = "relocated app via bundle ID", commands = 2, panel_bin = standalone, launch = true, native = true, open = { "-b", "com.alienxp03.raptor" } }
check { name = "resident IPC before discovery", commands = 1, panel_bin = standalone, ipc = true, native = true }
check { name = "missing app", commands = 2, panel_bin = standalone, bin = standalone, nil_launch = true }
check { name = "forced GUI failure", commands = 2, panel_bin = standalone, options = { ui = "gui" }, error = true }
check { name = "terminal standalone", options = { ui = "terminal" }, bin = standalone }
check { name = "explicit bin", files = { ["/opt/homebrew/opt/raptor/bin/raptor"] = true }, options = { bin = "/custom/cli" }, commands = 2, panel_bin = "/custom/cli", open = { "-b", "com.alienxp03.raptor" }, native = true, launch = true }
local app = "/somewhere/Not The App Name.app"
local app_files = { [app .. "/Contents/Info.plist"] = true, ["/opt/homebrew/opt/raptor/bin/raptor"] = true }
check { name = "explicit app never uses unrelated package IPC", files = app_files, options = { app = app }, commands = 1, open = { "-a", app }, launch = true, native = true }
app_files[app .. "/Contents/MacOS/raptor-cli"] = true
check { name = "explicit app paired IPC", files = app_files, options = { app = app }, commands = 1, panel_bin = app .. "/Contents/MacOS/raptor-cli", ipc = true, native = true }
check { name = "explicit app paired fallback", files = app_files, options = { app = app }, commands = 2, panel_bin = app .. "/Contents/MacOS/raptor-cli", open = { "-a", app }, launch = true, native = true }
check { name = "explicit bin and app", files = app_files, options = { bin = "/custom/cli", app = app }, commands = 2, panel_bin = "/custom/cli", open = { "-a", app }, launch = true, native = true }
check { name = "missing explicit app never launches another app", options = { app = app }, bin = standalone }
check { name = "failed explicit app never launches another app", files = { [app .. "/Contents/Info.plist"] = true }, options = { app = app }, commands = 1, open = { "-a", app }, bin = standalone }
check { name = "empty explicit app disables app fallback", options = { app = "" }, bin = standalone }
print("Homebrew routing: passed (paired stable opt, module-relative/custom prefix, overrides, IPC, bundle ID, failures, terminal)")
