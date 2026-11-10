import Foundation

public extension Rex {
    /// AgentEntriesOn reads native status records on the host that owns the paths.
    /// Remote paths must never be matched against local agents.
    static func agentEntriesOn(_ host: String, _ originSession: String) throws -> [AgentEntry] {
        if host.isEmpty || host == localHostLabel {
            return try agentEntries(originSession)
        }
        let out = try runOnBounded(host, 2, "do", "-e", agentsScript, "--json")
        return try decodeAgentEntriesWithNames(Data(out.utf8), "", Date(), false)
    }
}
