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
