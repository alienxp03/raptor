import Foundation
import RaptorPaths
import RaptorRex

public extension Catalog {
    /// ApplyDirectoryActivity replaces activity in place. Only an exact canonical
    /// working-directory match contributes activity; parent directories stay quiet.
    static func applyDirectoryActivity(_ items: inout [Directory], _ agents: [AgentEntry]) {
        applyDirectoryActivityOn(host: "", items: &items, agents: agents)
    }

    /// Remote paths belong to another filesystem. Never resolve their symlinks or
    /// relative paths against this machine when projecting a host-native snapshot.
    static func applyDirectoryActivityOn(host: String, items: inout [Directory], agents: [AgentEntry]) {
        func canonical(_ value: String) -> String {
            canonicalPath(value)
        }
        func clean(_ value: String) -> String {
            if value.isEmpty {
                return ""
            }
            return pathClean(value)
        }
        let normalize = (host.isEmpty || host == Rex.localHostLabel) ? canonical : clean
        let cwds = agents.map { normalize($0.cwd) }
        for i in items.indices {
            items[i].unreadDone = false
            items[i].completionSources = []
            items[i].state = ""
            items[i].working = false
            let dir = normalize(items[i].path)
            if dir.isEmpty {
                continue
            }
            for (j, agent) in agents.enumerated() {
                if cwds[j] != dir {
                    continue
                }
                items[i].unreadDone = items[i].unreadDone || agent.unreadDone
                if let source = agent.completionSource { items[i].completionSources.append(source) }
                var state = agent.state
                if state != "blocked" && state != "working" {
                    state = "idle"
                }
                if items[i].state.isEmpty || Rex.agentStateRank(state) < Rex.agentStateRank(items[i].state) {
                    items[i].state = state
                }
                items[i].working = items[i].working || state == "working"
            }
        }
    }

    /// FilterAgents searches names, applications, state, sessions and tabs. Empty
    /// and non-empty queries both preserve incoming group/time order.
    static func filterAgents(_ entries: [AgentEntry], _ query: String) -> [Int] {
        let texts = entries.map { $0.label + " " + $0.app + " " + $0.state + " " + $0.sessionLabel + " " + $0.windowLabel }
        let indices = match(texts, query)
        // Fuzzy scores select matches, but must not reorder the agent groups.
        return indices.sorted()
    }
}
