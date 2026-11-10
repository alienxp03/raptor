import Foundation
import RaptorPaths

/// AgentEntry is one live program_status record, not one tab or metadata file.
public struct AgentEntry: Equatable {
    public var path: String
    public var kind: String
    public var label: String
    public var app: String
    public var state: String
    public var agentID: String
    public var sessionID: String
    public var sessionLabel: String
    public var windowID: String
    public var windowLabel: String
    public var blockID: String
    public var active: Bool
    public var updatedAt: Date?
    public var cwd: String

    public init(
        path: String = "", kind: String = "", label: String = "", app: String = "", state: String = "",
        agentID: String = "", sessionID: String = "", sessionLabel: String = "", windowID: String = "",
        windowLabel: String = "", blockID: String = "", active: Bool = false, updatedAt: Date? = nil,
        cwd: String = ""
    ) {
        self.path = path
        self.kind = kind
        self.label = label
        self.app = app
        self.state = state
        self.agentID = agentID
        self.sessionID = sessionID
        self.sessionLabel = sessionLabel
        self.windowID = windowID
        self.windowLabel = windowLabel
        self.blockID = blockID
        self.active = active
        self.updatedAt = updatedAt
        self.cwd = cwd
    }
}

struct AgentProcess: Decodable {
    var pid: Int
    var name: String
    var cwd: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = (try? c.decode(Int.self, forKey: .pid)) ?? 0
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        cwd = (try? c.decode(String.self, forKey: .cwd)) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case pid, name, cwd
    }
}

/// Decodes any JSON value, keeping only strings (the sole shape updated_at uses).
struct FlexString: Decodable {
    var value: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        value = try? c.decode(String.self)
    }
}

struct AgentRecord: Decodable {
    var id: String
    var app: String
    var effectiveApp: String
    var state: String
    var title: String
    var msg: String
    var owner: AgentProcess?
    var updatedAt: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        app = (try? c.decode(String.self, forKey: .app)) ?? ""
        effectiveApp = (try? c.decode(String.self, forKey: .effectiveApp)) ?? ""
        state = (try? c.decode(String.self, forKey: .state)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        msg = (try? c.decode(String.self, forKey: .msg)) ?? ""
        owner = try? c.decodeIfPresent(AgentProcess.self, forKey: .owner)
        updatedAt = try? c.decodeIfPresent(FlexString.self, forKey: .updatedAt)?.value
    }

    enum CodingKeys: String, CodingKey {
        case id, app
        case effectiveApp = "effective_app"
        case state, title, msg, owner
        case updatedAt = "updated_at"
    }
}

struct AgentBlock: Decodable {
    var blockID: String
    var title: String
    var records: [AgentRecord]?
    var process: AgentBlockProcess?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blockID = (try? c.decode(String.self, forKey: .blockID)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        records = try c.decodeIfPresent([AgentRecord].self, forKey: .records)
        process = try? c.decodeIfPresent(AgentBlockProcess.self, forKey: .process)
    }

    enum CodingKeys: String, CodingKey {
        case blockID = "block_id"
        case title, records, process
    }
}

struct AgentBlockProcess: Decodable {
    var foreground: AgentProcess?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        foreground = try? c.decodeIfPresent(AgentProcess.self, forKey: .foreground)
    }

    enum CodingKeys: String, CodingKey {
        case foreground
    }
}

struct AgentsSnapshot: Decodable {
    struct SnapshotSession: Decodable {
        var sessionID: String
        var label: String
        var activeWindowID: String
        var windows: [SnapshotWindow]?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessionID = (try? c.decode(String.self, forKey: .sessionID)) ?? ""
            label = (try? c.decode(String.self, forKey: .label)) ?? ""
            activeWindowID = (try? c.decode(String.self, forKey: .activeWindowID)) ?? ""
            windows = try c.decodeIfPresent([SnapshotWindow].self, forKey: .windows)
        }

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case label
            case activeWindowID = "active_window_id"
            case windows
        }
    }

    struct SnapshotWindow: Decodable {
        var windowID: String
        var label: String
        var focusedBlockID: String
        var blocks: [AgentBlock]?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            windowID = (try? c.decode(String.self, forKey: .windowID)) ?? ""
            label = (try? c.decode(String.self, forKey: .label)) ?? ""
            focusedBlockID = (try? c.decode(String.self, forKey: .focusedBlockID)) ?? ""
            blocks = try c.decodeIfPresent([AgentBlock].self, forKey: .blocks)
        }

        enum CodingKeys: String, CodingKey {
            case windowID = "window_id"
            case label
            case focusedBlockID = "focused_block_id"
            case blocks
        }
    }

    var sessions: [SnapshotSession]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try c.decodeIfPresent([SnapshotSession].self, forKey: .sessions)
    }

    enum CodingKeys: String, CodingKey { case sessions }
}

/// One CLI process, serial API requests, no process spawning per pane. pcall
/// tolerates sessions/panes disappearing while the snapshot is being read.
let agentsScript = #"""

local result = { sessions = {} }
local listing = rex.call("session.list", {})
for _, s in ipairs(listing.sessions or {}) do
 local ok, attached = pcall(rex.call, "session.attach", {session_id=s.session_id})
 if ok and attached and attached.view then
  local view = attached.view
  local session = {session_id=s.session_id, label=s.label, active_window_id=view.active_window_id, windows={}}
  for _, w in ipairs(view.windows or {}) do
   local window = {window_id=w.window_id, label=w.label, focused_block_id=w.focused_block_id, blocks={}}
   for _, layer in ipairs(w.layers or {}) do
    for _, b in ipairs(layer.blocks or {}) do
     if b.creator_name == "com.superlogical.terminal" then
      local args = {session_id=s.session_id, block_id=b.block_id, args={}}
      local good, status = pcall(rex.call, "com.superlogical.terminal.program_status", args)
      if good and status and status.records and #status.records > 0 then
       local block = {block_id=b.block_id, records=status.records}
       local titled, title = pcall(rex.call, "com.superlogical.terminal.title", args)
       if titled and title then block.title = title.title end
       local inspected, process = pcall(rex.call, "com.superlogical.terminal.process", args)
       if inspected and process then block.process = process end
       table.insert(window.blocks, block)
      end
     end
    end
   end
   if #window.blocks == 0 then window.blocks = nil end
   table.insert(session.windows, window)
  end
  if #session.windows == 0 then session.windows = nil end
  table.insert(result.sessions, session)
 end
end
if #result.sessions == 0 then result.sessions = nil end
return result

"""#

public extension Rex {
    /// AgentEntries returns blocked, working, then idle agents, newest native status
    /// update first within each group. Equal or missing times retain decode order.
    static func agentEntries(_ originSession: String) throws -> [AgentEntry] {
        let out = try run("do", "-e", agentsScript, "--json")
        return try decodeAgentEntriesWithNames(Data(out.utf8), originSession, Date(), true)
    }

    static func decodeAgentEntries(_ data: Data, _ origin: String, _ now: Date) throws -> [AgentEntry] {
        try decodeAgentEntriesWithNames(data, origin, now, true)
    }

    static func decodeAgentEntriesWithNames(_ data: Data, _ origin: String, _ now: Date, _ localNames: Bool) throws -> [AgentEntry] {
        guard let snapshot = try? JSONDecoder().decode(AgentsSnapshot.self, from: data) else {
            throw RexError("could not parse agents: invalid JSON")
        }
        var entries: [AgentEntry] = []
        for s in snapshot.sessions ?? [] {
            for w in s.windows ?? [] {
                var windowLabel = w.label
                let generated = w.windowID.count >= 8 && w.label == "Window " + String(w.windowID.suffix(8))
                if windowLabel.trimmingCharacters(in: .whitespaces).isEmpty || generated {
                    for block in w.blocks ?? [] {
                        if block.blockID == w.focusedBlockID && !block.title.trimmingCharacters(in: .whitespaces).isEmpty {
                            windowLabel = block.title.trimmingCharacters(in: .whitespaces)
                            break
                        }
                    }
                }
                if windowLabel.trimmingCharacters(in: .whitespaces).isEmpty {
                    windowLabel = w.windowID
                }
                for b in w.blocks ?? [] {
                    for r in b.records ?? [] {
                        var app = normalizeAgentApp(r.effectiveApp)
                        if app.isEmpty {
                            app = normalizeAgentApp(r.app)
                        }
                        // Rex owns record lifetime and emits program_status_removed.
                        // A process snapshot must not override its native status records.
                        if app.isEmpty { continue }
                        var state = r.state
                        // done/error describe a task, not process exit. Keep the live
                        // agent visible as idle until ownership proves it has stopped.
                        switch state {
                        case "working", "blocked":
                            break
                        default:
                            state = "idle"
                        }
                        var label = r.title.trimmingCharacters(in: .whitespaces)
                        // Rex's native record title is authoritative. The optional Pi
                        // name bridge only fills names that the program did not report.
                        if label.isEmpty && localNames && app == "pi", let owner = r.owner {
                            let name = piAgentName(owner.pid, b.blockID, s.sessionID, now)
                            if !name.isEmpty { label = name }
                        }
                        // Status messages (for example "Needs input") are not agent names.
                        if label.isEmpty {
                            label = b.title.trimmingCharacters(in: .whitespaces)
                        }
                        if label.isEmpty {
                            label = app
                        }
                        var cwd = ""
                        if let foreground = b.process?.foreground {
                            cwd = foreground.cwd
                        }
                        entries.append(AgentEntry(
                            path: b.blockID + "#" + r.id, kind: "agent", label: label, app: app, state: state,
                            agentID: r.id, sessionID: s.sessionID, sessionLabel: s.label, windowID: w.windowID,
                            windowLabel: windowLabel, blockID: b.blockID,
                            active: s.sessionID == origin && w.windowID == s.activeWindowID && b.blockID == w.focusedBlockID,
                            updatedAt: agentUpdatedAt(r.updatedAt), cwd: cwd))
                    }
                }
            }
        }
        sortGroups(&entries)
        return entries
    }

    static func normalizeAgentApp(_ app: String) -> String {
        switch app.trimmingCharacters(in: .whitespaces).lowercased() {
        case "pi", "pi-coding-agent", "@earendil-works/pi-coding-agent", "@mariozechner/pi-coding-agent":
            return "pi"
        case "codex", "codex-cli", "openai-codex", "@openai/codex":
            return "codex"
        case "claude", "claude-code", "claude_code", "@anthropic-ai/claude-code":
            return "claude"
        default:
            return ""
        }
    }

    static func piAgentName(_ pid: Int, _ block: String, _ session: String, _ now: Date) -> String {
        if pid <= 0 { return "" }
        let file = RaptorPaths.cacheDir() + "/agents/pi-\(pid).json"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file),
              attrs[.type] as? FileAttributeType == FileAttributeType.typeRegular,
              let size = attrs[.size] as? NSNumber, size.intValue <= 64 * 1024 else {
            return ""
        }
        guard let data = FileManager.default.contents(atPath: file),
              let raw = try? JSONDecoder().decode(PiAgentMetadata.self, from: data) else {
            return ""
        }
        let at = raw.updatedAt.flatMap { parseRFC3339($0) }
        if raw.pid != pid || raw.app != "pi" || raw.blockID != block || raw.sessionID != session {
            return ""
        }
        guard let at, at != zeroTime else { return "" }
        if now.timeIntervalSince(at) > 15 || at > now.addingTimeInterval(5) {
            return ""
        }
        return raw.name.trimmingCharacters(in: .whitespaces)
    }

    /// JumpAgent verifies membership before changing focus, then selects the exact
    /// session/window on the requesting client. Never resolve ambiguous short IDs.
    static func jumpAgent(_ entry: AgentEntry, _ client: String) throws {
        if entry.sessionID.trimmingCharacters(in: .whitespaces).isEmpty
            || entry.windowID.trimmingCharacters(in: .whitespaces).isEmpty
            || entry.blockID.trimmingCharacters(in: .whitespaces).isEmpty {
            throw RexError("session_id, window_id and block_id are required")
        }
        let out = try apiCall(entry.sessionID, "session.list_blocks", ["session_id": entry.sessionID])
        struct Listing: Decodable {
            var blocks: [Block]?
            struct Block: Decodable {
                var blockID: String
                var windowID: String
                var creator: String
                init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    blockID = (try? c.decode(String.self, forKey: .blockID)) ?? ""
                    windowID = (try? c.decode(String.self, forKey: .windowID)) ?? ""
                    creator = (try? c.decode(String.self, forKey: .creator)) ?? ""
                }
                enum CodingKeys: String, CodingKey {
                    case blockID = "block_id"
                    case windowID = "window_id"
                    case creator = "creator_name"
                }
            }
        }
        guard let listing = decodeJSON(Listing.self, from: Data(out.utf8)) else {
            throw RexError("could not validate agent pane: invalid JSON")
        }
        let found = (listing.blocks ?? []).contains {
            $0.blockID == entry.blockID && $0.windowID == entry.windowID && $0.creator == "com.superlogical.terminal"
        }
        if !found {
            throw RexError("agent pane is gone or does not belong to this session/window")
        }
        _ = try apiCall(entry.sessionID, "session.focus_block", ["block_id": entry.blockID, "session_id": entry.sessionID])
        if !client.isEmpty {
            return try doAction(client: client, action: "session.select", kv: "session_id=\(entry.sessionID)", "window_id=\(entry.windowID)")
        }
    }
}

struct PiAgentMetadata: Decodable {
    var pid: Int
    var app: String
    var name: String
    var blockID: String
    var sessionID: String
    var updatedAt: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = (try? c.decode(Int.self, forKey: .pid)) ?? 0
        app = (try? c.decode(String.self, forKey: .app)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        blockID = (try? c.decode(String.self, forKey: .blockID)) ?? ""
        sessionID = (try? c.decode(String.self, forKey: .sessionID)) ?? ""
        updatedAt = try? c.decodeIfPresent(FlexString.self, forKey: .updatedAt)?.value
    }

    enum CodingKeys: String, CodingKey {
        case pid, app, name
        case blockID = "block_id"
        case sessionID = "session_id"
        case updatedAt = "updated_at"
    }
}
