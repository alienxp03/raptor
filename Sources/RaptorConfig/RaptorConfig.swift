import Foundation
import RaptorPaths

/// Read from ~/.config/raptor/config.toml (all optional). Ported from
/// internal/config; the TOML subset stays flat: key = "value" / key = 12.
public struct RaptorConfig {
    /// Where new worktrees are created (legacy; Worktrunk owns real paths).
    public var worktreeRoot: String
    /// Max slug characters in branch/dir names.
    public var slugLen: Int
    /// Default target for Enter in the dir picker.
    public var enter: String
    public var targets: [String]
    /// Canonical paths pinned to the top of the dir picker.
    public var pins: [String]
    /// Default agent launched into new worktrees: "pi", "codex", or "none".
    public var agent: String
    /// Default agent model (Pi: model id; Codex: model id). Empty = tool default.
    public var agentModel: String
    /// Default reasoning level. Empty = tool default.
    public var agentReasoning: String
    /// Agent choices offered in the worktree form.
    public var agents: [String]

    public init(
        worktreeRoot: String? = nil,
        slugLen: Int = 24,
        enter: String = "session",
        targets: [String] = ["session", "tab", "here", "pane_right", "pane_below"],
        pins: [String] = [],
        agent: String = "pi",
        agentModel: String = "",
        agentReasoning: String = "",
        agents: [String] = ["pi", "codex"]
    ) {
        self.worktreeRoot = worktreeRoot ?? (RaptorPaths.home() + "/Workspace/worktrees")
        self.slugLen = slugLen
        self.enter = enter
        self.targets = targets
        self.pins = pins
        self.agent = agent
        self.agentModel = agentModel
        self.agentReasoning = agentReasoning
        self.agents = agents
    }

    /// Default settings.
    public static func `default`() -> RaptorConfig {
        RaptorConfig()
    }

    /// Agent entries excluding "none"; the UI always prepends a none option.
    public func agentChoices() -> [String] {
        let list = agents.isEmpty ? RaptorConfig.default().agents : agents
        var seen = Set<String>()
        return list.filter { $0 != "none" && !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Shared target order and context requirements. Targets needing an origin
    /// pane drop out when `hasBlock` is false; duplicates keep first position.
    public func availableTargets(hasBlock: Bool) -> [String] {
        let list = targets.isEmpty ? RaptorConfig.default().targets : targets
        var seen = Set<String>()
        var result: [String] = []
        for target in list {
            if seen.contains(target) { continue }
            if !hasBlock, target == "here" || target.hasPrefix("pane") { continue }
            seen.insert(target)
            result.append(target)
        }
        return result
    }

    static func configPath() -> String {
        RaptorPaths.home() + "/.config/raptor/config.toml"
    }

    /// Parses the flat TOML subset.
    public static func load() -> RaptorConfig {
        var cfg = RaptorConfig.default()
        cfg.pins = loadPins()
        guard let data = FileManager.default.contents(atPath: configPath()),
              let source = String(data: data, encoding: .utf8) else { return cfg }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        func get(_ key: String) -> String? {
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.count >= key.count + 1, trimmed.hasPrefix(key) else { continue }
                let rest = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
                guard rest.hasPrefix("=") else { continue }
                let value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
                return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            return nil
        }

        if let v = get("worktree_root"), !v.isEmpty { cfg.worktreeRoot = RaptorPaths.expandHome(v) }
        if let v = get("slug_len"), !v.isEmpty, v.allSatisfy({ $0.isNumber }), let n = Int(v), n > 0 { cfg.slugLen = n }
        if let v = get("enter"), !v.isEmpty { cfg.enter = v }
        if let v = get("targets"), !v.isEmpty {
            let inner = v.trimmingCharacters(in: CharacterSet(charactersIn: "[]\"'"))
            let parsed = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }.filter { !$0.isEmpty }
            if !parsed.isEmpty { cfg.targets = parsed }
        }
        if let v = get("agent"), !v.isEmpty { cfg.agent = v }
        if let v = get("agent_model"), !v.isEmpty { cfg.agentModel = v }
        if let v = get("agent_reasoning"), !v.isEmpty { cfg.agentReasoning = v }
        if let v = get("agents"), !v.isEmpty {
            let inner = v.trimmingCharacters(in: CharacterSet(charactersIn: "[]\"'"))
            let parsed = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }.filter { !$0.isEmpty }
            if !parsed.isEmpty { cfg.agents = parsed }
        }
        return cfg
    }

    /// Reads just the pins list. Missing file means no pins.
    public static func loadPins() -> [String] {
        guard let data = FileManager.default.contents(atPath: configPath()),
              let source = String(data: data, encoding: .utf8) else { return [] }
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("pins"), !line.hasPrefix("pins_x") else { continue }
            let rest = line.dropFirst("pins".count).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("=") else { continue }
            let inner = rest.dropFirst().trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }.filter { !$0.isEmpty }
        }
        return []
    }

    /// Rewrites only the pins line, leaving every other byte untouched.
    public static func savePins(_ pins: [String]) throws -> Void {
        let path = configPath()
        let quoted = pins.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let line = "pins = [" + quoted.joined(separator: ", ") + "]"
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var out: [String] = []
        var replaced = false
        for raw in existing.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(raw).trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("pins"), !trimmed.hasPrefix("pins_x") {
                if !replaced {
                    out.append(line)
                    replaced = true
                }
                continue
            }
            out.append(String(raw))
        }
        if !replaced {
            if let last = out.last, last != "" {
                out.append("")
            }
            out.append(line)
        }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Rewrites only the agent default lines, leaving every other byte intact.
    /// A nil/empty value means "tool default": the line is removed so the file
    /// keeps documenting only explicit choices.
    public static func saveAgent(agent: String, model: String, reasoning: String) throws -> Void {
        let lines = [
            agentLine("agent", agent),
            agentLine("agent_model", model),
            agentLine("agent_reasoning", reasoning),
        ].filter { !$0.isEmpty }
        try saveAgentLines(lines, keys: ["agent", "agent_model", "agent_reasoning"])
    }

    static func agentLine(_ key: String, _ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        return key + " = \"" + trimmed.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func saveAgentLines(_ lines: [String], keys: [String]) throws -> Void {
        let path = configPath()
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var out: [String] = []
        var replaced = Set<String>()
        for raw in existing.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(raw).trimmingCharacters(in: .whitespaces)
            if let key = keys.first(where: { trimmed.hasPrefix($0) && trimmed.dropFirst($0.count).trimmingCharacters(in: .whitespaces).hasPrefix("=") }) {
                if let line = lines.first(where: { $0.hasPrefix(key + " ") }), !replaced.contains(key) {
                    out.append(line)
                    replaced.insert(key)
                }
                continue
            }
            out.append(String(raw))
        }
        for line in lines where !replaced.contains(String(line.prefix(while: { $0 != " " }))) {
            if let last = out.last, last != "" {
                out.append("")
            }
            out.append(line)
        }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Adds or removes a canonical path. Returns the new pinned state.
    @discardableResult
    public static func togglePin(_ path: String) throws -> Bool {
        let canonical = RaptorPaths.canonical(path)
        var next: [String] = []
        var found = false
        for pin in loadPins() {
            if pin == canonical {
                found = true
                continue
            }
            next.append(pin)
        }
        if !found {
            next.append(canonical)
        }
        try savePins(next)
        return !found
    }
}
