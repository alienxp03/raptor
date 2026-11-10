-- Raptor Rex plugin. Keep key bindings in the user's init.lua.
--
--   require("raptor").setup{}
--   rex.bind("shift+cmd+o", "raptor")
--   rex.bind("ctrl+n", "raptor_worktree_new")

local M = {}

-- Capture the loaded module, not the caller of setup. Rex may omit debug;
-- searchpath provides the same location in restricted Lua environments.
local source = debug and debug.getinfo and debug.getinfo(1, "S").source
if source and source:sub(1, 1) == "@" then
	source = source:sub(2)
elseif package and package.searchpath then
	source = package.searchpath("raptor", package.path)
else
	source = nil
end
local module_root = source and source:match("^(/.*)/share/raptor/init%.lua$")
if module_root then
	-- A resolved Cellar path must still track upgrades through stable opt.
	local prefix = module_root:match("^(/.*)/Cellar/raptor/[^/]+$")
	if prefix then module_root = prefix .. "/opt/raptor" end
end

local function exists(path)
	local file = io.open(path, "rb")
	if not file then return false end
	file:close()
	return true
end

function M.setup(options)
	options = options or {}
	-- Prefer this plugin's package over another Homebrew installation. Never
	-- mix its CLI/app with a different prefix, even if its CLI is missing.
	local brew_bin, brew_app
	local roots = module_root and { module_root } or {}
	if not module_root then
		for _, prefix in ipairs({ os.getenv("HOMEBREW_PREFIX") or "", "/opt/homebrew", "/usr/local" }) do
			if prefix ~= "" then roots[#roots + 1] = prefix .. "/opt/raptor" end
		end
	end
	for _, root in ipairs(roots) do
		local bin = root .. "/bin/raptor"
		if module_root or exists(bin) then
			brew_bin, brew_app = bin, root .. "/libexec/Raptor.app"
			break
		end
	end
	local cfg = {
		bounds = { x = 0.28, y = 0.14, w = 0.44, h = 0.40 },
		mobile_bounds = { x = 0.04, y = 0.10, w = 0.92, h = 0.78 },
		bin = brew_bin or (os.getenv("HOME") .. "/.local/bin/raptor"),
		ui = "auto", -- auto, terminal, or gui (force the server's Mac app).
		app = brew_app or "", -- Explicit options override automatic package discovery.
	}
	for key, value in pairs(options) do
		if cfg[key] == nil then
			error("raptor: unknown option " .. tostring(key), 0)
		end
		cfg[key] = value
	end

	-- A CLI override must not silently launch a different package's app.
	if options.bin ~= nil and options.app == nil and options.bin ~= brew_bin then
		cfg.app = ""
	end
	-- An app override is authoritative. Prefer its own backend over the
	-- discovered package's IPC client; explicit bin+app remains an escape hatch.
	local panel_bin = cfg.bin
	if options.app ~= nil and options.bin == nil then
		local bundled_bin = cfg.app .. "/Contents/MacOS/raptor-cli"
		panel_bin = cfg.app ~= "" and exists(bundled_bin) and bundled_bin or nil
	end

	if cfg.ui ~= "auto" and cfg.ui ~= "terminal" and cfg.ui ~= "gui" then
		error("raptor: ui must be auto, terminal, or gui", 0)
	end

	local function client_platform(ctx)
		if ctx.client_id == nil then
			return nil
		end
		local clients = rex.call("client.list")
		for _, client in ipairs(clients and clients.clients or {}) do
			if client.client_id == ctx.client_id and client.info ~= nil then
				-- A CLI runs on the server even when invoked from an iPhone.
				-- Its platform/transport do not identify the viewing app.
				return client.info.platform,
					client.info.kind == "app" and client.principal ~= nil and client.principal.transport == "unix"
			end
		end
		return nil
	end

	local function basename(p)
		return (p:gsub("(.*/)(.-)$", "%2"))
	end

	local function base_cmd(ctx, with_title)
		local args = { cfg.bin }
		-- Keep the sidebar title when focus moves into the floating picker.
		local title
		if with_title ~= false and ctx.block_id then
			local ok, r = pcall(rex.block.call, "com.superlogical.terminal", "title", { block_id = ctx.block_id })
			if ok and r ~= nil then
				title = r.title
			end
		end
		local flags = {
			{ "-session", ctx.session_id },
			{ "-block", ctx.block_id },
			{ "-client", ctx.client_id },
			{ "-title", title },
		}
		for _, f in ipairs(flags) do
			if f[2] ~= nil and f[2] ~= "" then
				table.insert(args, f[1])
				table.insert(args, f[2])
			end
		end
		return args
	end

	local function open_layer(ctx, args)
		-- anchor the picker over the window the user is looking at
		local win_id
		if ctx.block_id then
			local d = rex.session.describe_block({ block_id = ctx.block_id })
			if d ~= nil and d.block ~= nil then
				win_id = d.block.window_id
			end
		end

		local bounds = cfg.bounds
		local platform = client_platform(ctx)
		if platform == "ios" or platform == "ipados" then
			bounds = cfg.mobile_bounds
		end

		local layer, err = rex.session.new_layer({
			window_id = win_id,
			bounds = { bounds.x, bounds.y, bounds.w, bounds.h },
			focus = true,
			layout = rex.layout.block({
				flavor = "com.superlogical.terminal.shell",
				options = {
					command = args,
					shell = "none",
				},
			}),
		})
		if layer == nil then
			error(err, 0)
		end

		if layer.block_ids ~= nil and layer.block_ids[1] ~= nil then
			rex.session.set_block_label({ block_id = layer.block_ids[1], label = "raptor" })
			rex.session.focus_block({ block_id = layer.block_ids[1] })
		end
		if ctx.client_id ~= nil and win_id ~= nil then
			local selection = { session_id = ctx.session_id, window_id = win_id }
			if ctx.owner_client then
				-- queue targets the original caller, whose identity is absent in
				-- this path. Explicitly target the recovered terminal owner.
				rex.call("client.perform", {
					client_id = ctx.client_id,
					action = "session.select",
					args = selection,
					session_id = ctx.session_id,
					block_id = layer.block_ids and layer.block_ids[1],
				})
			else
				rex.client.queue("session.select", selection)
			end
		end
	end

	local function picker_url(ctx, mode)
		local function encode(value)
			return (
				value:gsub("[^A-Za-z0-9%-%._~]", function(byte)
					return string.format("%%%02X", string.byte(byte))
				end)
			)
		end
		local parts = { "mode=" .. encode(mode) }
		for _, pair in ipairs({ { "session", ctx.session_id }, { "block", ctx.block_id }, { "client", ctx.client_id } }) do
			if pair[2] ~= nil and pair[2] ~= "" then
				table.insert(parts, pair[1] .. "=" .. encode(pair[2]))
			end
		end
		return "raptor://picker?" .. table.concat(parts, "&")
	end

	local function resolve_context(ctx)
		-- Function key bindings can omit client_id. The origin terminal's
		-- owner is the client controlling its input/size, not a random viewer.
		if ctx.client_id == nil and ctx.block_id then
			local origin = rex.session.describe_block({ block_id = ctx.block_id })
			if origin and origin.block and origin.block.owner then
				local resolved = {}
				for key, value in pairs(ctx) do resolved[key] = value end
				resolved.client_id = origin.block.owner
				resolved.owner_client = true
				ctx = resolved
			end
		end
		return ctx
	end

	local function show_picker(ctx, mode)
		ctx = resolve_context(ctx)
		local platform, local_client = client_platform(ctx)
		if mode ~= "launcher" and (cfg.ui == "gui" or (cfg.ui == "auto" and platform == "macos" and local_client)) then
			-- Fast path: the resident panel host answers over a local socket.
			-- No process spawn, no app activation, no flicker. Failure falls
			-- back to Launch Services, which starts the host when installed.
			local panel_args = { panel_bin or cfg.bin }
			for _, pair in ipairs({
				{ "-session", ctx.session_id },
				{ "-block", ctx.block_id },
				{ "-client", ctx.client_id },
			}) do
				if pair[2] ~= nil and pair[2] ~= "" then
					table.insert(panel_args, pair[1])
					table.insert(panel_args, pair[2])
				end
			end
			-- Global context flags must precede the panel subcommand.
			table.insert(panel_args, "panel")
			table.insert(panel_args, "--mode")
			table.insert(panel_args, mode)
			local panel_result = panel_bin and rex.exec(panel_args, { timeout = 5 })
			if panel_result ~= nil and panel_result.ok then
				return { ui = "native" }
			end
			-- Do not use -n: reuse the resident host and deliver fresh context.
			-- Explicit/package paths stay authoritative (including launch failure).
			-- Only unpaired discovery uses the bundle ID, so relocated dev apps
			-- work without guessing a name, scanning disks, or invoking brew.
			local cmd
			if cfg.app ~= "" then
				if exists(cfg.app .. "/Contents/Info.plist") then
					cmd = { "/usr/bin/open", "-g", "-a", cfg.app, picker_url(ctx, mode) }
				end
			elseif options.app == nil then
				cmd = { "/usr/bin/open", "-g", "-b", "com.alienxp03.raptor", picker_url(ctx, mode) }
			end
			local result = cmd and rex.exec(cmd, { timeout = 5 })
			if result ~= nil and result.ok then
				return { ui = "native" }
			end
		end
		if mode == "pr" then
			error("raptor: Open pull request requires the native Mac app; no terminal PR form is available", 0)
		end
		if cfg.ui == "gui" and mode ~= "launcher" then
			error("raptor: GUI requested, but Raptor.app was not found or could not be launched", 0)
		end
		local args = base_cmd(ctx)
		if mode == "wt-create" then
			table.insert(args, "wt")
			table.insert(args, "--create")
		else
			table.insert(args, mode)
		end
		open_layer(ctx, args)
		return { ui = "terminal" }
	end

	rex.action({
		name = "raptor",
		title = "Raptor",
		description = "Resume a recent session or find a project directory; open as session, tab, pane, or cd here.",
		category = "Navigate",
		keywords = "sessions resume recent zoxide sesh fzf picker project directory",
		args = { target = "string?", dir = "string?" },
		run = function(ctx, args)
			if ctx.session_id == nil then
				error("raptor: no session context; run from a key or inside a session", 0)
			end

			-- direct mode: open a known directory without the picker
			if args.dir then
				local cmd = base_cmd(ctx, false)
				table.insert(cmd, "direct")
				table.insert(cmd, args.target or "session")
				table.insert(cmd, args.dir)
				local r, err = rex.exec(cmd, { timeout = 30 })
				if r == nil then
					error(err, 0)
				end
				if not r.ok then
					error("raptor: " .. r.stdout .. r.stderr, 0)
				end
				return { target = args.target or "session", dir = args.dir }
			end

			return show_picker(ctx, "dirs")
		end,
	})

	rex.action({
		name = "raptor_worktree_new",
		title = "Raptor: Create Worktree",
		description = "Open the create-worktree form for the origin pane's repository using the configured UI.",
		category = "Navigate",
		run = function(ctx)
			if ctx.session_id == nil then
				error("raptor: no session context", 0)
			end
			if ctx.block_id then
				local origin = rex.session.describe_block({ block_id = ctx.block_id })
				if origin and origin.block and origin.block.label == "raptor" then
					-- Let an existing picker handle Ctrl+N instead of nesting layers.
					rex.client.queue("pane.send_key", { key = "ctrl+n" })
					return { ui = "terminal" }
				end
			end
			return show_picker(ctx, "wt-create")
		end,
	})

	rex.action({
		name = "raptor_pr_open",
		title = "Raptor: Open Pull Request",
		description = "Open a GitHub pull request in a Worktrunk worktree. Mac app only.",
		category = "Navigate",
		keywords = "github pull request pr worktree",
		run = function(ctx)
			if ctx.session_id == nil then
				error("raptor: no session context", 0)
			end
			return show_picker(ctx, "pr")
		end,
	})

	rex.action({
		name = "raptor_launcher",
		title = "Raptor: Experimental Launcher",
		description = "Search paths, then choose an action. Terminal-only preview.",
		category = "Navigate",
		run = function(ctx)
			if ctx.session_id == nil then error("raptor: no session context", 0) end
			return show_picker(ctx, "launcher")
		end,
	})

	rex.action({
		name = "raptor_task_new",
		title = "Raptor: Instant Pi Worktree",
		description = "Auto-name a branch/worktree from HEAD, open a tab, and start fresh Pi without a prompt.",
		category = "Navigate",
		keywords = "task pi instant branch worktree tab",
		run = function(ctx)
			if ctx.session_id == nil or ctx.block_id == nil then
				error("raptor: instant task needs a session and origin pane", 0)
			end
			ctx = resolve_context(ctx)
			if ctx.client_id == nil then error("raptor: cannot identify the app client", 0) end
			local command = base_cmd(ctx, false)
			table.insert(command, "task")
			local result, err = rex.exec(command, { timeout = 30 })
			if result == nil then error(err, 0) end
			if not result.ok then error("raptor: " .. result.stdout .. result.stderr, 0) end
			return rex.json.decode(result.stdout)
		end,
	})

	-- Use the Go backend so shortcuts and both pickers share validated history.
	rex.action({
		name = "raptor_session_last",
		title = "Raptor: Last Session",
		description = "Switch to the most recent live session.",
		category = "Navigate",
		keywords = "last session back toggle",
		run = function(ctx)
			ctx = resolve_context(ctx)
			if ctx.client_id == nil or ctx.session_id == nil then
				error("raptor: no client or session context", 0)
			end
			local command = base_cmd(ctx, false)
			table.insert(command, "last-session")
			local result, err = rex.exec(command, { timeout = 30 })
			if result == nil then error(err, 0) end
			if not result.ok then error("raptor: " .. result.stdout .. result.stderr, 0) end
			return { selected = result.stdout:match("^%s*(.-)%s*$") }
		end,
	})

	-- Direct keybinding entry points. Unlike actions, these never touch the
	-- server's action registry, so they keep working on servers that have not
	-- restarted since the module gained an action.
	function M.open(mode)
		return function(ctx)
			if ctx.session_id == nil then
				error("raptor: no session context; run from a key or inside a session", 0)
			end
			return show_picker(resolve_context(ctx), mode)
		end
	end

	return M
end

return M
