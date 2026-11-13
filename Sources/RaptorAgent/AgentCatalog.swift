import Foundation

/// One launchable model of an agent CLI (Pi or Codex). Reasoning levels are
/// reported by the tool itself; never inferred from the model name.
public struct AgentModel: Codable, Equatable, Sendable {
    /// Launch identifier (Pi: model id without provider; Codex: `model` field).
    public var id: String
    /// Pi provider qualifier ("zai", "openai-codex"); empty when not needed.
    public var provider: String
    /// Human-readable display name from the tool.
    public var label: String
    /// Supported reasoning levels in tool order.
    public var reasoning: [String]
    /// Effective default reasoning from tool settings/capabilities; empty means unknown.
    public var defaultReasoning: String
    /// Effective fresh-session default model, resolved by the tool's settings/rules.
    public var isDefault: Bool

    public init(
        id: String, provider: String = "", label: String = "", reasoning: [String] = [],
        defaultReasoning: String = "", isDefault: Bool = false
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.reasoning = reasoning
        self.defaultReasoning = defaultReasoning
        self.isDefault = isDefault
    }

    enum CodingKeys: String, CodingKey {
        case id, provider, label, reasoning
        case defaultReasoning = "default_reasoning"
        case isDefault = "is_default"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        reasoning = try c.decodeIfPresent([String].self, forKey: .reasoning) ?? []
        defaultReasoning = try c.decodeIfPresent(String.self, forKey: .defaultReasoning) ?? ""
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }
}

/// Discovery result for one agent CLI, cache-shaped and directly cacheable.
public struct AgentCatalog: Codable, Equatable, Sendable {
    public var agent: String
    public var models: [AgentModel]
    /// Empty when discovery is clean; else explains missing/stale/fallback data.
    public var warning: String

    public init(agent: String, models: [AgentModel] = [], warning: String = "") {
        self.agent = agent
        self.models = models
        self.warning = warning
    }

    public func model(id: String, provider: String) -> AgentModel? {
        models.first { $0.id == id && $0.provider == provider } ?? models.first { $0.id == id }
    }
}

/// Launch arguments for the selected agent. `nil` means "do not launch"; empty
/// reasoning keeps the tool's own default (no flag).
public enum AgentLaunch {
    /// Reasoning value that leaves the tool's default in place.
    public static let defaultReasoning = "default"

    public static func arguments(
        agent: String, provider: String, model: String, reasoning: String
    ) -> [String]? {
        let model = model.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { return nil }
        switch agent {
        case "pi":
            var args: [String] = []
            let provider = provider.trimmingCharacters(in: .whitespaces)
            if !provider.isEmpty {
                args += ["--provider", provider]
            }
            args += ["--model", model]
            if let thinking = reasoningArgument(reasoning) {
                args += ["--thinking", thinking]
            }
            return args
        case "codex":
            var args = ["--model", model]
            if let effort = reasoningArgument(reasoning) {
                // Codex config values are TOML strings; quote the level.
                args += ["-c", "model_reasoning_effort=\"\(effort)\""]
            }
            return args
        default:
            return nil
        }
    }

    /// Maps the UI reasoning choice; "default" and unknown values mean no flag.
    static func reasoningArgument(_ reasoning: String) -> String? {
        let value = reasoning.trimmingCharacters(in: .whitespaces)
        if value.isEmpty || value == AgentLaunch.defaultReasoning { return nil }
        return value
    }

    /// Single-quote shell quoting for data arguments ("here" target sends text).
    public static func shellLine(_ args: [String]) -> String {
        args.map { arg in
            if arg.isEmpty { return "''" }
            return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
