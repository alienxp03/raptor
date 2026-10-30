-- Raptor Rex plugin. Keep key bindings in the user's init.lua.
--
--   require("raptor").setup{}
--   rex.bind("shift+cmd+o", "raptor")
--   rex.bind("shift+cmd+t", "raptor_wt")

local M = {}

function M.setup(options)
	local cfg = {
		bounds = { x = 0.28, y = 0.14, w = 0.44, h = 0.40 },
		mobile_bounds = { x = 0.04, y = 0.10, w = 0.92, h = 0.78 },
		bin = os.getenv("HOME") .. "/.local/bin/raptor",
		ui = "auto", -- Native Mac app when installed; terminal on mobile.
		app = "", -- Optional Raptor.app path; otherwise search standard locations.
	}
	for key, value in pairs(options or {}) do
		if cfg[key] == nil then
			error("raptor: unknown option " .. tostring(key), 0)
		end
		cfg[key] = value
	end

	if cfg.ui ~= "auto" and cfg.ui ~= "terminal" then
		error("raptor: ui must be auto or terminal", 0)
	end

	local function client_platform(ctx)
		if ctx.client_id == nil then
			return nil
		end
		local clients = rex.call("client.list")
		for _, client in ipairs(clients and clients.clients or {}) do
			if client.client_id == ctx.client_id and client.info ~= nil then
				return client.info.platform, client.principal ~= nil and client.principal.transport == "unix"
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
			rex.client.queue("session.select", {
				session_id = ctx.session_id,
				window_id = win_id,
			})
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

	local function show_picker(ctx, mode)
		local platform, local_client = client_platform(ctx)
		if cfg.ui == "auto" and platform == "macos" and local_client then
			local apps = cfg.app ~= "" and { cfg.app }
				or { os.getenv("HOME") .. "/Applications/Raptor.app", "/Applications/Raptor.app" }
			for _, app in ipairs(apps) do
				local info = io.open(app .. "/Contents/Info.plist", "r")
				if info ~= nil then
					info:close()
					-- Do not use -n: Launch Services reuses the warm Mac app. The
					-- URL delivers fresh context even when the app is already open.
					local cmd = { "/usr/bin/open", "-g", "-a", app, picker_url(ctx, mode) }
					local result = rex.exec(cmd, { timeout = 5 })
					if result ~= nil and result.ok then
						return { ui = "native" }
					end
				end
			end
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
		description = "Fuzzy-find a zoxide directory; open as session, tab, pane, or cd here.",
		category = "Navigate",
		keywords = "zoxide sesh fzf picker project directory",
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
		name = "raptor_wt",
		title = "Raptor Worktrees",
		description = "Browse local worktrees or create one with a branch name and full path preview.",
		category = "Navigate",
		keywords = "worktree git local branch create",
		run = function(ctx)
			if ctx.session_id == nil then
				error("raptor: no session context", 0)
			end
			return show_picker(ctx, "wt")
		end,
	})

	rex.action({
		name = "raptor_create",
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

	-- History shortcuts stay in Lua: no binary startup or nested Rex CLI calls.
	local cache = os.getenv("XDG_CACHE_HOME")
	if cache == nil or cache == "" then
		cache = os.getenv("HOME") .. "/.cache"
	end
	local history_path = cache .. "/rex/raptor-last"
	local pane_path = cache .. "/rex/raptor-last-pane"

	local function read_history(path)
		local file = io.open(path, "r")
		if file == nil then
			error("raptor: no previous location recorded; navigate with Raptor first", 0)
		end
		local data = file:read("*a")
		file:close()
		return data
	end

	local function write_history(path, data)
		local file, err = io.open(path, "w")
		if file == nil then
			error("raptor: " .. tostring(err), 0)
		end
		local ok, write_err = file:write(data)
		file:close()
		if ok == nil then
			error("raptor: " .. tostring(write_err), 0)
		end
	end

	local function remember_pane(ctx)
		if ctx.session_id ~= nil and ctx.block_id ~= nil then
			write_history(pane_path, rex.json.encode({ session_id = ctx.session_id, block_id = ctx.block_id }))
		end
	end

	local function last_session(ctx)
		if ctx.client_id == nil or ctx.session_id == nil then
			error("raptor: no client or session context", 0)
		end
		local sid = read_history(history_path):match("^%s*(.-)%s*$")
		if sid == ctx.session_id then
			error("raptor: previous session is already selected; switch sessions with Raptor first", 0)
		end
		local sessions, err = rex.call("session.list")
		if sessions == nil then
			error(err, 0)
		end
		local found = false
		for _, session in ipairs(sessions.sessions or {}) do
			if session.session_id == sid then
				found = true
				break
			end
		end
		if not found then
			error("raptor: previous session is gone", 0)
		end
		rex.client.queue("session.select", { session_id = sid })
		write_history(history_path, ctx.session_id .. "\n")
		remember_pane(ctx)
		return { selected = sid }
	end

	local function last_pane(ctx)
		if ctx.client_id == nil or ctx.session_id == nil or ctx.block_id == nil then
			error("raptor: no client, session, or pane context", 0)
		end
		local pane = rex.json.decode(read_history(pane_path))
		if type(pane) ~= "table" or type(pane.session_id) ~= "string" or type(pane.block_id) ~= "string" then
			error("raptor: invalid previous pane record", 0)
		end
		if pane.session_id == ctx.session_id and pane.block_id == ctx.block_id then
			error("raptor: previous pane is already focused; open another pane with Raptor first", 0)
		end
		if pane.session_id ~= ctx.session_id then
			local attached, attach_err = rex.session.attach({ session_id = pane.session_id })
			if attached == nil then
				error("raptor: previous session is unavailable: " .. tostring(attach_err), 0)
			end
		end
		local description, err = rex.session.describe_block({ session_id = pane.session_id, block_id = pane.block_id })
		if description == nil then
			error("raptor: previous pane is unavailable: " .. tostring(err), 0)
		end
		local window_id = description.block and description.block.window_id
		if window_id == nil then
			error("raptor: previous pane is not in a window", 0)
		end
		local focused, focus_err = rex.session.focus_block({ session_id = pane.session_id, block_id = pane.block_id })
		if focused == nil then
			error(focus_err, 0)
		end
		rex.client.queue("session.select", { session_id = pane.session_id, window_id = window_id })
		remember_pane(ctx)
		if pane.session_id ~= ctx.session_id then
			write_history(history_path, ctx.session_id .. "\n")
		end
		return { selected = pane.block_id }
	end

	for _, name in ipairs({ "raptor_last_session", "raptor_last" }) do
		rex.action({
			name = name,
			title = "Raptor: Last Session",
			description = "Toggle the session Raptor left. Manual Rex navigation does not update history.",
			category = "Navigate",
			keywords = "last session back toggle",
			run = last_session,
		})
	end
	rex.action({
		name = "raptor_last_pane",
		title = "Raptor: Last Pane",
		description = "Toggle the pane Raptor left, even across sessions. No background watcher.",
		category = "Navigate",
		keywords = "last pane block back toggle",
		run = last_pane,
	})
end

return M
