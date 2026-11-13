import Foundation
import RaptorConfig
import RaptorWorktree
import RaptorRex

extension Handler {
    /// Resolve and validate without calling the app. Lua actions must queue local
    /// selection after returning, rather than wait for their own blocked client.
    public func resolvePinnedSession(slot: Int) throws -> SessionPin {
        guard (1...9).contains(slot) else {
            throw MessageError("pinned session slot must be 1...9")
        }
        guard let pin = RaptorConfig.loadSessionPins().first(where: { $0.slot == slot }) else {
            throw MessageError("no pinned session in slot \(slot)")
        }
        let host = Rex.apiNormalizeHost(pin.host)
        let displayHost = host.isEmpty ? "local host" : host
        let output: String
        do {
            output = try Rex.runOn(host, "ls", "--json")
        } catch {
            throw MessageError("pinned session \(slot): cannot reach \(displayHost): \(error)")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any],
              let sessions = object["sessions"] as? [[String: Any]] else {
            throw MessageError("pinned session \(slot): invalid session listing from \(displayHost)")
        }
        guard !pin.sessionID.isEmpty,
              sessions.contains(where: { $0["session_id"] as? String == pin.sessionID }) else {
            throw MessageError("pinned session \(slot) is closed or missing on \(displayHost) (\(pin.sessionID))")
        }
        return SessionPin(sessionID: pin.sessionID, host: host, slot: slot)
    }

    /// Select only the stored identity. Never recreate a closed session.
    public func selectPinnedSession(slot: Int) throws -> String {
        let pin = try resolvePinnedSession(slot: slot)
        let host = pin.host
        let displayHost = host.isEmpty ? "local host" : host
        do {
            try apiJumpOnHost(host, SessionEntry(kind: "session", id: pin.sessionID,
                path: pin.sessionID, sessionID: pin.sessionID, sessionLabel: pin.sessionID), ctx.client)
        } catch {
            throw MessageError("pinned session \(slot): could not select \(pin.sessionID) on \(displayHost): \(error)")
        }
        return pin.sessionID
    }
}
