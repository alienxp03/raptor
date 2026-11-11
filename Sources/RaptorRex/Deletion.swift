import Foundation
import RaptorExecx

/// Live host/session state. This never reads launcher cwd hints or disk caches.
public struct DeletionSessionState: Equatable {
    public let hostID: String
    public let sessionID: String
    public let directories: [String]
    public let blocks: [String]

    public init(hostID: String, sessionID: String, directories: [String], blocks: [String]) {
        self.hostID = hostID
        self.sessionID = sessionID
        self.directories = directories
        self.blocks = blocks
    }
}

public extension Rex {
    static func deletionHost(_ supplied: String) throws -> String {
        if supplied.isEmpty || supplied == localHostLabel { return "" }
        let normalized = normalizeHost(supplied)
        if normalized.isEmpty {
            let registry = try deletionAPI("", "hosts.list")
            let aliases = registry["hosts"] as? [[String: Any]] ?? []
            guard !aliases.contains(where: {
                ($0["label"] as? String ?? "").caseInsensitiveCompare(supplied) == .orderedSame
            }) else { throw RexError("host label is ambiguous with this machine") }
        }
        return normalized
    }

    static func validateDeletionOrigin(_ sessionID: String, origins: [String]) throws {
        for origin in origins where !origin.isEmpty {
            let resolved = origin.hasPrefix("session:") ? origin : resolveHostTarget("", "session", origin)
            guard !resolved.isEmpty else { throw RexError("cannot resolve protected picker origin") }
            guard resolved != sessionID else { throw RexError("refusing to delete the session this picker opened from") }
        }
    }

    static func deletionAPI(_ host: String, _ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys]), as: UTF8.self)
        let out = try runOn(host, ["api", "call", method, payload])
        guard let object = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else {
            throw RexError("invalid Rex reply for \(method)")
        }
        return object
    }

    /// Remote labels must be registered and unambiguous. Honor a stored identity
    /// when present; otherwise the live identity is pinned by the preview token.
    /// -S is Rex's established host route, never an SSH guess.
    static func deletionHostID(_ host: String) throws -> String {
        let status = try deletionAPI(host, "server.status")
        guard let id = status["host_id"] as? String, !id.isEmpty else { throw RexError("unknown Rex host identity") }
        if !host.isEmpty {
            let registry = try deletionAPI("", "hosts.list")
            let matches = (registry["hosts"] as? [[String: Any]] ?? []).filter { $0["label"] as? String == host }
            guard matches.count == 1,
                  let endpoints = matches[0]["endpoints"] as? [String], !endpoints.isEmpty else {
                throw RexError("remote host is not uniquely registered with a Rex execution route")
            }
            let storedID = matches[0]["host_id"] as? String ?? ""
            guard storedID.isEmpty || storedID == id else { throw RexError("registered Rex host identity does not match") }
        }
        return id
    }

    static func deletionSessionState(_ host: String, _ sessionID: String) throws -> DeletionSessionState {
        guard sessionID.hasPrefix("session:") else { throw RexError("Delete requires a full session ID") }
        let hostID = try deletionHostID(host)
        let sessions = try deletionAPI(host, "session.list")["sessions"] as? [[String: Any]] ?? []
        guard sessions.filter({ $0["session_id"] as? String == sessionID }).count == 1 else {
            throw RexError("unknown or ambiguous session")
        }
        let reply = try deletionAPI(host, "session.list_blocks", ["session_id": sessionID])
        guard let blocks = reply["blocks"] as? [[String: Any]], !blocks.isEmpty else { throw RexError("session has no known directory") }
        var directories: [String] = [], ids: [String] = []
        for block in blocks {
            guard let id = block["block_id"] as? String, id.hasPrefix("block:"),
                  block["host_id"] as? String == hostID,
                  block["creator_name"] as? String == "com.superlogical.terminal" else {
                throw RexError("session contains an unknown or different-host block")
            }
            let process = try deletionAPI(host, "com.superlogical.terminal.process", [
                "session_id": sessionID, "block_id": id, "args": [:] as [String: Any],
            ])
            guard let foreground = process["foreground"] as? [String: Any],
                  let cwd = foreground["cwd"] as? String, cwd.hasPrefix("/"), !cwd.contains("\0") else {
                throw RexError("session block has an unknown process directory")
            }
            directories.append(cwd)
            ids.append(id)
        }
        return DeletionSessionState(hostID: hostID, sessionID: sessionID,
                                    directories: directories.sorted(), blocks: ids.sorted())
    }

    /// Execute through a detached Rex terminal on the selected server. A direct
    /// argv starts sh; each command argument is strictly single-quoted. Output is
    /// base64-framed, not parsed from human diagnostics or terminal escape codes.
    /// The helper is closed on every path; the user's panes remain untouched.
    static func deletionCommand(_ host: String, _ sessionID: String, _ hostID: String,
                                directory: String, name: String, arguments: [String]) throws -> ExecResult {
        guard try deletionHostID(host) == hostID else { throw RexError("Rex host identity changed") }
        let creators = try deletionAPI(host, "block_creator.list")["creators"] as? [[String: Any]] ?? []
        let terminals = creators.filter { $0["name"] as? String == "com.superlogical.terminal" }
        guard terminals.count == 1, terminals[0]["host_id"] as? String == hostID else {
            throw RexError("execution creator has an unknown or different host identity")
        }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let marker = "RAPTOR-" + UUID().uuidString + ":"
        let errorMarker = "RAPTOR-STDERR-" + UUID().uuidString + ":"
        let command = ([name] + arguments).map(quote).joined(separator: " ")
        let child = "(cd " + quote(directory) + " && " + command + "); r=$?; printf '\\n" + marker + "%s' \"$r\""
        // FD 3 carries base64 stdout past the stderr command substitution.
        // Git's NUL-delimited output never enters a shell variable.
        let script = "{ errors=$( { ( " + child + " ) | base64 >&3; } 2>&1 ); printf '\\n"
            + errorMarker + "\\n'; printf '%s' \"$errors\" | base64; } 3>&1"
        let created = try deletionAPI(host, "session.new_block", [
            "session_id": sessionID, "flavor": "com.superlogical.terminal.shell", "label": "Raptor Delete check",
            "options": ["shell": "none", "command": ["/bin/sh", "-c", script],
                        "exit": ["on_completion": false], "size": ["columns": 120, "rows": 24]],
        ])
        guard let block = created["block_id"] as? String, block.hasPrefix("block:") else { throw RexError("missing remote helper ID") }
        var helperClosed = false
        defer {
            if !helperClosed { _ = try? deletionAPI(host, "block.close", ["session_id": sessionID, "block_id": block]) }
        }
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            let process = try deletionAPI(host, "com.superlogical.terminal.process", [
                "session_id": sessionID, "block_id": block, "args": [:] as [String: Any],
            ])
            if process["last_exit"] is [String: Any] {
                let result = try deletionAPI(host, "com.superlogical.terminal.format", [
                    "session_id": sessionID, "block_id": block,
                    "args": ["format": "text", "unwrap": true, "trim": true, "max_bytes": 983040],
                ])
                guard result["id"] == nil, result["eof"] as? Bool != false,
                      let text = result["content"] as? String,
                      let split = text.range(of: errorMarker),
                      let errorData = Data(base64Encoded: text[split.upperBound...].filter { !$0.isWhitespace }),
                      let data = Data(base64Encoded: text[..<split.lowerBound].filter { !$0.isWhitespace }),
                      let output = String(data: data, encoding: .utf8),
                      let range = output.range(of: "\n" + marker, options: .backwards),
                      let code = Int(output[range.upperBound...]) else { throw RexError("invalid or oversized remote command output") }
                let stdout = String(output[..<range.lowerBound])
                _ = try deletionAPI(host, "block.close", ["session_id": sessionID, "block_id": block])
                helperClosed = true
                return ExecResult(stdout: stdout, stderr: String(decoding: errorData, as: UTF8.self), code: code)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw RexError("remote command timed out; inspect resources before retry")
    }
}
