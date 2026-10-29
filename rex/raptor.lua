-- raptor — sesh-style zoxide + worktree picker for Rex (Go + Bubble Tea).
--
--   shift+cmd+p     dir picker (zoxide + sessions; tab cycles target,
--                    Ctrl+W on a git repo opens the worktree flow)
--   shift+ctrl+w     worktree picker for the current repo
--   palette          "Raptor", "Raptor Worktrees", "Raptor: Last Session"
--
-- Head-less: rex do raptor target=tab dir=~/some/project

local cfg = {
  open_key = "shift+cmd+p",
  wt_key   = "shift+ctrl+w",

  -- popup rectangle, as fractions of the current window (x, y, w, h)
  bounds = { x = 0.25, y = 0.20, w = 0.50, h = 0.60 },

  -- the Go binary (github.com/alienxp03/raptor)
  bin = os.getenv("HOME") .. "/.local/bin/raptor",
}

local function basename(p)
  return (p:gsub("(.*/)(.-)$", "%2"))
end

local function base_cmd(ctx)
  local args = { cfg.bin }
  local flags = {
    { "-session", ctx.session_id },
    { "-block",   ctx.block_id },
    { "-client",  ctx.client_id },
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
    local d = rex.session.describe_block{ block_id = ctx.block_id }
    if d ~= nil and d.block ~= nil then win_id = d.block.window_id end
  end

  local layer, err = rex.session.new_layer{
    window_id = win_id,
    bounds = { cfg.bounds.x, cfg.bounds.y, cfg.bounds.w, cfg.bounds.h },
    focus  = true,
    layout = rex.layout.block{
      flavor   = "com.superlogical.terminal.shell",
      options  = {
        command = args,
        shell   = "none",
      },
    },
  }
  if layer == nil then error(err, 0) end

  if layer.block_ids ~= nil and layer.block_ids[1] ~= nil then
    rex.session.set_block_label{ block_id = layer.block_ids[1], label = "raptor" }
    rex.session.focus_block{ block_id = layer.block_ids[1] }
  end
  if ctx.client_id ~= nil and win_id ~= nil then
    rex.client.queue("session.select", {
      session_id = ctx.session_id,
      window_id  = win_id,
    })
  end
end

rex.action{
  name        = "raptor",
  title       = "Raptor",
  description = "Fuzzy-find a zoxide directory or session; open as session, tab, pane, or cd here.",
  category    = "Navigate",
  keywords    = "zoxide sesh fzf picker project session switch",
  args        = { target = "string?", dir = "string?" },
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
      if r == nil then error(err, 0) end
      if not r.ok then error("raptor: " .. r.stdout .. r.stderr, 0) end
      return { target = args.target or "session", dir = args.dir }
    end

    local cmd = base_cmd(ctx)
    table.insert(cmd, "dirs")
    open_layer(ctx, cmd)
  end,
}

rex.action{
  name        = "raptor_wt",
  title       = "Raptor Worktrees",
  description = "Browse local worktrees or create one with a branch name and full path preview.",
  category    = "Navigate",
  keywords    = "worktree git local branch create",
  run = function(ctx)
    if ctx.session_id == nil then
      error("raptor: no session context", 0)
    end
    local cmd = base_cmd(ctx)
    table.insert(cmd, "wt")
    open_layer(ctx, cmd)
  end,
}

rex.action{
  name        = "raptor_last",
  title       = "Raptor: Last Session",
  description = "Jump back to the session the picker switched you away from. Press again to toggle.",
  category    = "Navigate",
  keywords    = "zoxide sesh last session back toggle",
  run = function(ctx)
    local cmd = base_cmd(ctx)
    table.insert(cmd, "last")
    local r, err = rex.exec(cmd, { timeout = 15 })
    if r == nil then error(err, 0) end
    if not r.ok then error("raptor: " .. r.stdout .. r.stderr, 0) end
    return { selected = r.stdout }
  end,
}

rex.bind(cfg.open_key, "raptor")
rex.bind(cfg.wt_key, "raptor_wt")
