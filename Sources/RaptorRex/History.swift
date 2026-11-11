import Foundation

public extension Rex {
    /// SelectSession records both ends only after the client accepts the switch.
    static func selectSession(_ ctx: Ctx, _ sid: String) throws {
        if ctx.client.isEmpty {
            throw RexError("no client context")
        }
        try selectHistorySession(ctx, "", ctx.client, sid)
    }

    static func selectHistorySession(_ ctx: Ctx, _ host: String, _ client: String, _ sid: String) throws {
        _ = try runOn(host, "-C", client, "do", "session.select", "session_id=" + sid)
        if ctx.session != sid {
            _ = try? recordSessionUse("", ctx.session)
        }
        _ = try? recordSessionUse(host, sid)
    }

    /// SelectLast uses the same history as both pickers. Failed host queries and
    /// selections stop navigation; they must not turn an unavailable session into
    /// a deleted session or report a server-only focus as a successful app switch.
    static func selectLast(_ ctx: Ctx) throws -> String {
        if ctx.client.isEmpty || ctx.session.isEmpty {
            throw RexError("no client or session context")
        }
        let (doc, _, error) = readRecency(recencyPath(), Date())
        if let error {
            throw RexError("could not read session history: \(error)")
        }
        var visits = doc.visits
        // Old installations have a single local ID. Check it only after the shared
        // history, and never let a stale legacy ID block newer valid visits.
        if let data = FileManager.default.contents(atPath: statePath()),
           let id = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            visits.append(RecencyVisit(host: "", sessionID: id, at: zeroTime))
        }
        // The common local toggle needs one Rex process/connection, not a
        // separate listing followed by a second process for client selection.
        // Mixed-host history keeps the existing ordered, bounded host checks.
        if ctx.client.hasPrefix("client:"), visits.allSatisfy({ $0.host.isEmpty }) {
            let candidates = visits.map(\.sessionID).filter { $0 != ctx.session }
            guard !candidates.isEmpty else {
                throw RexError("no previous live session recorded; switch sessions first")
            }
            let payload = try JSONSerialization.data(withJSONObject: ["client": ctx.client, "sessions": candidates], options: .sortedKeys)
            let args = String(decoding: payload, as: UTF8.self)
            let selected = try run("do", "-e", localHistoryScript, "--args", args)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidates.contains(selected) else {
                throw RexError("no previous live session recorded; switch sessions first")
            }
            if ctx.session != selected { _ = try? recordSessionUse("", ctx.session) }
            _ = try? recordSessionUse("", selected)
            return selected
        }
        var listings: [String: Set<String>] = [:]
        for visit in visits {
            if visit.sessionID == ctx.session {
                continue
            }
            var sessions = listings[visit.host]
            if sessions == nil {
                sessions = try historySessions(visit.host)
                listings[visit.host] = sessions
            }
            guard let sessions, sessions.contains(visit.sessionID) else {
                continue
            }
            var client = ctx.client
            if !visit.host.isEmpty {
                client = appClientOn(visit.host, clientLabel(ctx.client))
                if client.isEmpty {
                    throw RexError("cannot identify the requesting app on \(visit.host)")
                }
            }
            try selectHistorySession(ctx, visit.host, client, visit.sessionID)
            return visit.sessionID
        }
        throw RexError("no previous live session recorded; switch sessions first")
    }

    static let localHistoryScript = #"""
    local response, listError = rex.call("session.list")
    if not response then error("could not check previous sessions: " .. tostring(listError)) end
    if type(response.sessions) ~= "table" then error("could not parse previous sessions") end
    local live = {}
    for _, session in ipairs(response.sessions) do live[session.session_id] = true end
    for _, id in ipairs(rex.args.sessions) do
        if live[id] then
            local selected, selectError = rex.call("client.perform", {
                client_id = rex.args.client,
                action = "session.select",
                args = { session_id = id },
            })
            if not selected then error(tostring(selectError)) end
            print(id)
            return
        end
    end
    """#

    static func historySessions(_ host: String) throws -> Set<String> {
        let out: String
        do {
            out = try runOnBounded(host, remoteListTimeout, "ls", "--json")
        } catch {
            throw RexError("could not check previous sessions on \(localHostLabelOr(host)): \(error)")
        }
        guard let data = decodeJSON(SessionsResponse.self, from: Data(out.utf8)), let sessions = data.sessions else {
            throw RexError("could not parse previous sessions on \(localHostLabelOr(host))")
        }
        var set = Set<String>(minimumCapacity: sessions.count)
        for session in sessions {
            set.insert(session.sessionID)
        }
        return set
    }
}
