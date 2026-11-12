-- Raptor Rex plugin. The picker renders in a bare native host process
-- spawned under Rex (the resh model); keep key bindings in the user's
-- init.lua.
--
--   dofile("/path/to/raptor/init.lua").setup{}  -- written by raptor init
--   rex.bind("shift+cmd+o", "raptor")
--   rex.bind("shift+cmd+c", "raptor_pr_open")
--   rex.bind("shift+cmd+n", "raptor_worktree_new")

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
	-- Packaged plugins stay paired with their package. A standalone plugin
	-- prefers the local installer location over an unrelated Homebrew copy.
	local standalone_bin = os.getenv("HOME") .. "/.local/bin/raptor"
	local local_bin = not module_root and exists(standalone_bin) and standalone_bin
	local brew_bin
	local roots = module_root and { module_root } or {}
	if not module_root then
		for _, prefix in ipairs({ os.getenv("HOMEBREW_PREFIX") or "", "/opt/homebrew", "/usr/local" }) do
			if prefix ~= "" then roots[#roots + 1] = prefix .. "/opt/raptor" end
		end
	end
	for _, root in ipairs(roots) do
		local bin = root .. "/bin/raptor"
		if module_root or exists(bin) then
			brew_bin = bin
			break
		end
	end
	local cfg = {
		bounds = { x = 0.28, y = 0.14, w = 0.44, h = 0.40 },
		bin = local_bin or brew_bin or standalone_bin,
		-- Legacy options from the app era: accepted so existing configs keep
		-- loading, and ignored — the bare host positions its own panel.
		mobile_bounds = { x = 0.08, y = 0.15, w = 0.84, h = 0.60 },
	}
	for key, value in pairs(options) do
		if cfg[key] == nil then
			error("raptor: unknown option " .. tostring(key), 0)
		end
		cfg[key] = value
	end
	local panel_bin = cfg.bin

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

	local function base_cmd(ctx)
		local args = { cfg.bin }
		local flags = {
			{ "-session", ctx.session_id },
			{ "-block", ctx.block_id },
			{ "-client", ctx.client_id },
		}
		for _, f in ipairs(flags) do
			if f[2] ~= nil and f[2] ~= "" then
				table.insert(args, f[1])
				table.insert(args, f[2])
			end
		end
		return args
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
		-- The native picker renders in the bare host process, which only a
		-- client viewing this Mac can show. CLI clients may serve remote
		-- viewers, so their platform/transport alone is not proof.
		local platform, local_client = client_platform(ctx)
		if platform ~= "macos" or not local_client then
			error("raptor: requires the native picker on this Mac", 0)
		end
		-- The resident panel host answers over a local socket. When the host
		-- is missing, the panel client spawns it detached under this process
		-- chain, so its fd scan inherits Rex's file-access grants. No app,
		-- no Launch Services, no TCC prompts.
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
		if mode == "pr" then
			error("raptor: Opening a pull request requires the native picker", 0)
		end
		error("raptor: the native picker could not be opened; run "
			.. (panel_bin or cfg.bin) .. " serve and try again", 0)
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
				local cmd = base_cmd(ctx)
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
		description = "Open the create-worktree form for the origin pane's repository in the native picker.",
		category = "Navigate",
		run = function(ctx)
			if ctx.session_id == nil then
				error("raptor: no session context", 0)
			end
			return show_picker(ctx, "wt-create")
		end,
	})

	rex.action({
		name = "raptor_pr_open",
		title = "Checkout pull request",
		description = "Open a GitHub pull request in a Worktrunk worktree. Native picker only.",
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
		name = "raptor_worktree_agent",
		title = "Raptor: Instant Agent Worktree",
		description = "Auto-name a branch and worktree from HEAD, open a tab, and start a fresh agent (pi) without a prompt.",
		category = "Navigate",
		keywords = "agent pi task instant branch worktree tab",
		run = function(ctx)
			if ctx.session_id == nil or ctx.block_id == nil then
				error("raptor: instant task needs a session and origin pane", 0)
			end
			ctx = resolve_context(ctx)
			if ctx.client_id == nil then error("raptor: cannot identify the app client", 0) end
			local command = base_cmd(ctx)
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
			local command = base_cmd(ctx)
			table.insert(command, "last-session")
			local result, err = rex.exec(command, { timeout = 30 })
			if result == nil then error(err, 0) end
			if not result.ok then error("raptor: " .. result.stdout .. result.stderr, 0) end
			return { selected = result.stdout:match("^%s*(.-)%s*$") }
		end,
	})


	return M
end

return M
