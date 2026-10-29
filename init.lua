-- Raptor Rex plugin. Keep key bindings in the user's init.lua.
--
--   require("raptor").setup{}
--   rex.bind("shift+cmd+o", "raptor")
--   rex.bind("shift+ctrl+w", "raptor_wt")

local M = {}

function M.setup(options)
	local cfg = {
		bounds = { x = 0.28, y = 0.14, w = 0.44, h = 0.40 },
		mobile_bounds = { x = 0.04, y = 0.10, w = 0.92, h = 0.78 },
		bin = os.getenv("HOME") .. "/.local/bin/raptor",
	}
	for key, value in pairs(options or {}) do
		if cfg[key] == nil then
			error("raptor: unknown option " .. tostring(key), 0)
		end
		cfg[key] = value
	end

	local function basename(p)
		return (p:gsub("(.*/)(.-)$", "%2"))
	end

	local function base_cmd(ctx)
		local args = { cfg.bin }
		-- Keep the sidebar title when focus moves into the floating picker.
		local title
		if ctx.block_id then
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
		if ctx.client_id ~= nil then
			local clients = rex.call("client.list")
			for _, client in ipairs(clients and clients.clients or {}) do
				if client.client_id == ctx.client_id and client.info ~= nil then
					local platform = client.info.platform
					if platform == "ios" or platform == "ipados" then
						bounds = cfg.mobile_bounds
					end
					break
				end
			end
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

	rex.action({
		name = "raptor",
		title = "Raptor",
		description = "Fuzzy-find a zoxide directory or session; open as session, tab, pane, or cd here.",
		category = "Navigate",
		keywords = "zoxide sesh fzf picker project session switch",
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

			local cmd = base_cmd(ctx)
			table.insert(cmd, "dirs")
			open_layer(ctx, cmd)
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
			local cmd = base_cmd(ctx)
			table.insert(cmd, "wt")
			open_layer(ctx, cmd)
		end,
	})

	rex.action({
		name = "raptor_last",
		title = "Raptor: Last Session",
		description = "Jump back to the session the picker switched you away from. Press again to toggle.",
		category = "Navigate",
		keywords = "zoxide sesh last session back toggle",
		run = function(ctx)
			local cmd = base_cmd(ctx)
			table.insert(cmd, "last")
			local r, err = rex.exec(cmd, { timeout = 15 })
			if r == nil then
				error(err, 0)
			end
			if not r.ok then
				error("raptor: " .. r.stdout .. r.stderr, 0)
			end
			return { selected = r.stdout }
		end,
	})
end

return M
