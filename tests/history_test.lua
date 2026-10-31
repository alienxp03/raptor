-- Run from the repository root: lua tests/history_test.lua
local actions, files, calls = {}, {}, {}
local records, next_record = {}, 0
local failure
local cache = os.getenv("XDG_CACHE_HOME")
if cache == nil or cache == "" then
	cache = os.getenv("HOME") .. "/.cache"
end
local session_path = cache .. "/rex/raptor-last"
local pane_path = cache .. "/rex/raptor-last-pane"
local ctx = { client_id = "client", session_id = "current-session", block_id = "current-pane" }

local real_open = io.open
io.open = function(path, mode)
	if mode == "rb" and path:match("/opt/raptor/bin/raptor$") then
		return nil
	end
	assert(path == session_path or path == pane_path, "unexpected file")
	if mode == "r" and files[path] == nil then
		return nil
	end
	return {
		read = function()
			return files[path]
		end,
		write = function(_, data)
			files[path] = data
			return true
		end,
		close = function() end,
	}
end

rex = {
	action = function(action)
		actions[action.name] = action.run
	end,
	json = {
		encode = function(record)
			next_record = next_record + 1
			local key = "record-" .. next_record
			records[key] = record
			return key
		end,
		decode = function(data)
			return records[data]
		end,
	},
	exec = function()
		error("history actions must not start subprocesses")
	end,
	call = function(method)
		assert(method == "session.list")
		return { sessions = { { session_id = "previous-session" } } }
	end,
	client = {
		queue = function(action, args)
			assert(action == "session.select")
			calls[#calls + 1] = { action = action, args = args }
		end,
	},
	session = {
		attach = function(args)
			assert(args.session_id == "previous-session")
			if failure == "attach" then
				return nil, "session removed"
			end
			return { view = {} }
		end,
		describe_block = function(args)
			if failure == "describe" then
				return nil, "pane closed"
			end
			assert(args.block_id == "previous-pane")
			return { block = { window_id = "moved-window" } }
		end,
		focus_block = function(args)
			if failure == "focus" then
				return nil, "focus failed"
			end
			calls[#calls + 1] = { action = "focus", args = args }
			return { revision = 1 }
		end,
	},
}

dofile("init.lua").setup({})
assert(actions.raptor_last == nil, "legacy session alias must not be registered")
assert(actions.raptor_last_session == nil, "legacy session name must not be registered")
assert(actions.raptor_last_pane == nil, "legacy pane alias must not be registered")

local function seed(session)
	files[session_path] = "previous-session\n"
	files[pane_path] = rex.json.encode({ session_id = session or "previous-session", block_id = "previous-pane" })
	calls = {}
	failure = nil
end

seed()
local result = actions.raptor_session_last(ctx)
assert(result.selected == "previous-session")
assert(files[session_path] == "current-session\n")
assert(rex.json.decode(files[pane_path]).block_id == "current-pane")

for _, session in ipairs({ "current-session", "previous-session" }) do
	seed(session)
	result = actions.raptor_pane_last(ctx)
	assert(result.selected == "previous-pane")
	assert(calls[1].action == "focus")
	assert(calls[2].args.window_id == "moved-window")
	assert(calls[2].args.session_id == session)
	assert(rex.json.decode(files[pane_path]).block_id == "current-pane")
	assert(files[session_path] == (session == ctx.session_id and "previous-session\n" or "current-session\n"))
end

for _, stage in ipairs({ "attach", "describe", "focus" }) do
	seed()
	local before = files[pane_path]
	failure = stage
	assert(not pcall(actions.raptor_pane_last, ctx))
	assert(files[pane_path] == before, "failed navigation changed pane history")
	assert(files[session_path] == "previous-session\n")
end

seed()
files[pane_path] = nil
assert(not pcall(actions.raptor_pane_last, ctx))
files[pane_path] = rex.json.encode({ session_id = ctx.session_id, block_id = ctx.block_id })
assert(not pcall(actions.raptor_pane_last, ctx))
files[session_path] = ctx.session_id
assert(not pcall(actions.raptor_session_last, ctx))
assert(not pcall(actions.raptor_pane_last, {}))
assert(not pcall(actions.raptor_session_last, {}))

io.open = real_open
print("history actions: passed (no subprocesses)")
