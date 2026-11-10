import Foundation
import RaptorLauncherupdate
import RaptorPaths
import RaptorRex
import RaptorWorktree
import RaptorCatalog

extension Handler {
    /// Remote-host jump/select, mirroring Rex.jumpOnHost/selectOnHost. These call
    /// the variadic Rex.doOn form explicitly: the Rex.doOn(kv: [String]) overload
    /// currently forwards to itself and overflows the stack on remote hosts.
    /// The control flow, budgets, and side effects (recordSelectedSession runs
    /// inside doOn) match the Rex port exactly.
    func apiSelectOnHost(_ host: String, _ sessionID: String, _ clientID: String) throws {
        let entry = SessionEntry(kind: "session", id: sessionID, path: sessionID, sessionID: sessionID)
        return try apiJumpOnHost(host, entry, clientID)
    }

    func apiJumpOnHost(_ host: String, _ entry: SessionEntry, _ clientID: String) throws {
        if host.isEmpty || host == Rex.localHostLabel {
            return try Rex.jump(entry, clientID)
        }
        let client = Rex.appClientOn(host, apiClientLabel(clientID))
        if !client.isEmpty {
            do {
                if entry.kind == "window" {
                    try Rex.doOn(host, client, "session.select", kv: "session_id=\(entry.sessionID)", "window_id=\(entry.id)")
                } else {
                    try Rex.doOn(host, client, "session.select", kv: "session_id=\(entry.sessionID)")
                }
                return
            } catch {
                // Fall through to server-side focus, like Go's err == nil check.
            }
        }
        let windows = apiHostWindows(host, entry.sessionID) ?? []
        if windows.isEmpty {
            throw MessageError("session \(entry.sessionLabel) has no windows on \(host)")
        }
        if entry.kind == "window" {
            return try Rex.focusWindow(host, entry.sessionID, entry.id)
        }
        var active = windows[0].windowID
        for window in windows where window.active {
            active = window.windowID
            break
        }
        return try Rex.focusWindow(host, entry.sessionID, active)
    }

    /// Rex.HostWindows port: raw window list of one remote session (labels are
    /// not resolved; active defaults to the first window, like focusRemoteWindow).
    private func apiHostWindows(_ host: String, _ sessionID: String) -> [(windowID: String, label: String, focusedBlockID: String, active: Bool)]? {
        let payload = Rex.marshalSorted(["session_id": sessionID])
        guard let out = try? Rex.runOn(host, ["api", "call", "-s", sessionID, "session.view", payload]),
            let obj = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] else {
            return nil
        }
        let activeWindowID = obj["active_window_id"] as? String ?? ""
        var windows: [(windowID: String, label: String, focusedBlockID: String, active: Bool)] = []
        for window in obj["windows"] as? [[String: Any]] ?? [] {
            let windowID = window["window_id"] as? String ?? ""
            windows.append((
                windowID: windowID,
                label: window["label"] as? String ?? "",
                focusedBlockID: window["focused_block_id"] as? String ?? "",
                active: windowID == activeWindowID))
        }
        return windows
    }

    // MARK: - CreateSessionOn / ClientLabel ports

    /// Rex.ClientLabel port: resolves a unique app label on the local server with
    /// ONE client.list fetch (the Rex port re-fetches, doubling the rex call).
    /// A label is only a cross-host routing hint, not device identity.
    func apiClientLabel(_ clientID: String) -> String {
        var id = clientID
        if !id.hasPrefix("client:") {
            id = Catalog.resolveHostTarget("", "client", id)
        }
        if id.isEmpty {
            return ""
        }
        let clients = apiAppClientsOn("") ?? []
        for client in clients {
            if client.clientID == id && client.state != "lost" {
                let label = client.label.trimmingCharacters(in: .whitespaces)
                if !label.isEmpty && apiUniqueAppClient(clients, label) == id {
                    return label
                }
                return ""
            }
        }
        return ""
    }

    struct APIClient {
        var clientID: String
        var state: String
        var kind: String
        var label: String
    }

    private func apiAppClientsOn(_ host: String) -> [APIClient]? {
        guard let out = try? Rex.runOn(host, ["api", "call", "client.list", "{\"kinds\":[\"app\"]}"]),
            let obj = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] else {
            return nil
        }
        var clients: [APIClient] = []
        for client in obj["clients"] as? [[String: Any]] ?? [] {
            let info = client["info"] as? [String: Any] ?? [:]
            clients.append(APIClient(
                clientID: client["client_id"] as? String ?? "",
                state: client["connection_state"] as? String ?? "",
                kind: info["kind"] as? String ?? "",
                label: info["label"] as? String ?? ""))
        }
        return clients
    }

    /// Rex.uniqueAppClient port: one full ID only for one app with this exact
    /// label; a lost duplicate still makes the label unsafe.
    private func apiUniqueAppClient(_ clients: [APIClient], _ label: String) -> String {
        var id = ""
        for client in clients {
            if client.kind != "app" || client.label.trimmingCharacters(in: .whitespaces) != label {
                continue
            }
            if !id.isEmpty || !client.clientID.hasPrefix("client:") || client.state == "lost" {
                return ""
            }
            id = client.clientID
        }
        return id
    }

    /// Rex.CreateSessionOn port: reuses a host session by label or creates one at
    /// dir, recording the creation through the API-local hostname cache (the Rex
    /// port consults its module-internal cache, which the api tests must not hit).
    func apiCreateSessionOn(_ host: String, _ dir: String) throws -> (id: String, existing: Bool) {
        let name = RaptorPaths.basename(dir)
        if let out = try? Rex.runOn(host, "ls", "--json"),
            let obj = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] {
            for session in obj["sessions"] as? [[String: Any]] ?? []
            where session["label"] as? String == name {
                let sid = session["session_id"] as? String ?? ""
                return (sid, true)
            }
        }
        let out = try Rex.runOn(host, ["new", "--json", "-c", dir, name])
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any],
            let sid = obj["session_id"] as? String, !sid.isEmpty else {
            throw MessageError("could not create session for \(dir) on \(host)")
        }
        apiRecordLauncherCreation(host, sid, name, dir)
        return (sid, false)
    }

    /// Rex.RecordLauncherCreation port: publishes only an actual returned session
    /// identity, normalizing the host through the shared api hostname cache.
    private func apiRecordLauncherCreation(_ host: String, _ id: String, _ label: String, _ path: String) {
        let normalized = Rex.apiNormalizeHost(host)
        let local = normalized.isEmpty || normalized == Rex.localHostLabel
        let display = local ? Rex.apiLocalHostname() : normalized
        Launcherupdate.record(Session(id: id, label: label, host: display, local: local, path: path))
    }
}
