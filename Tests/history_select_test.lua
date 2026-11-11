-- Execute the exact Lua sent by the Swift local-history fast path.
local file = assert(io.open("Sources/RaptorRex/History.swift", "r"))
local source = file:read("*a")
file:close()
local script = assert(source:match('static let localHistoryScript = #"""(.-)"""#'))
local run = assert((loadstring or load)(script))
local original_print = print
local calls, printed, selected
local function check(candidates, sessions, failure)
	calls, printed, selected = {}, nil, nil
	rex = {
		args = { client = "client:app", sessions = candidates },
		call = function(method, args)
			calls[#calls + 1] = method
			if method == "session.list" then
				if failure == "list" then return nil, "host unavailable" end
				if failure == "malformed" then return {} end
				return { sessions = sessions }
			end
			assert(method == "client.perform")
			assert(args.client_id == "client:app" and args.action == "session.select")
			selected = args.args.session_id
			if failure == "select" then return nil, "selection failed" end
			return { performed_by = "client:app" }
		end,
	}
	print = function(value) printed = value end
	local ok = pcall(run)
	print = original_print
	return ok
end
local live = { { session_id = "previous" }, { session_id = "older" } }
assert(check({ "deleted", "previous", "older" }, live))
assert(selected == "previous" and printed == "previous" and #calls == 2)
assert(check({ "older", "previous" }, live))
assert(selected == "older" and printed == "older")
assert(check({ "deleted" }, live))
assert(selected == nil and printed == nil and #calls == 1)
for _, failure in ipairs({ "list", "malformed", "select" }) do
	assert(not check({ "previous", "older" }, live, failure))
	assert(printed == nil, "Never report success before the app accepts the switch")
end
print("local history: passed (one Rex process, deleted candidates, MRU order, app acknowledgement, failures)")
