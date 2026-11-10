public extension Rex {
    /// The public Lua API supplies the subscription acknowledgement that the plain
    /// `rex events` CLI does not expose. Register handlers before attach_all, then
    /// signal readiness only after Rex confirms the all-session subscription.
    static let eventsScript = #"""

local function publish(kind)
 local written = io.stdout:write(assert(rex.json.encode({type=kind})), "\n")
 if not written then rex.stop(0); return end
 if not io.stdout:flush() then rex.stop(0) end
end
for _, name in ipairs({
 "program_status_changed", "program_status_removed", "pwd_changed",
 "process_changed", "child_exited", "title_changed"
}) do
 rex.on("terminal." .. name, function()
  publish("activity_changed")
 end)
end
for _, name in ipairs({
 "session_created", "session_destroyed", "session_moved",
 "session_label_changed", "session_view_changed", "active_window_changed",
 "window_created", "window_closed", "window_label_changed", "block_closed",
 "hosts_changed", "tailscale_status_changed"
}) do
 rex.on(name, function() publish(name) end)
end
local attached, err = rex.call("session.attach_all", {event_scope="all"})
if not attached then error(tostring(err), 0) end
publish("raptor_ready")

"""#
}
