import Darwin
import Foundation
import RaptorExecx
import RaptorPaths

/// Discovers and caches Pi/Codex model catalogs. Discovery runs a short-lived
/// subprocess against the installed CLIs; results cache under
/// ~/Library/Caches/raptor/agent-catalog-v1.json keyed by agent. Cache keys
/// include the tool path so CLI upgrades invalidate; stale entries survive
/// transient discovery failures and are returned with a warning.
public enum AgentCatalogStore {
    /// Seconds a cache entry is served without re-running discovery.
    static let ttl: TimeInterval = 600

    /// Injectable for tests; returns the absolute tool path or nil.
    public static var locateTool: (String) -> String? = { Execx.lookup(name: $0) }

    struct CacheEntry: Codable {
        var agent: String
        var toolPath: String
        var fetchedAt: Double
        var models: [AgentModel]
        var warning: String

        enum CodingKeys: String, CodingKey {
            case agent
            case toolPath = "tool_path"
            case fetchedAt = "fetched_at"
            case models, warning
        }
    }

    // v1 lacks resolved Pi defaults and Codex configured overrides. Reject it
    // even as stale data, including entries decoded with field fallbacks.
    static let cacheVersion = 2

    struct CacheFile: Codable {
        var version: Int = AgentCatalogStore.cacheVersion
        var entries: [String: CacheEntry] = [:]
    }

    public static func cachePath() -> String {
        RaptorPaths.home() + "/Library/Caches/raptor/agent-catalog-v1.json"
    }

    static func loadCache() -> CacheFile {
        guard let data = FileManager.default.contents(atPath: cachePath()),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data),
              file.version == cacheVersion else { return CacheFile() }
        return file
    }

    static func writeCache(_ file: CacheFile) {
        let path = cachePath()
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Cached entry without discovery, whatever its age.
    public static func cachedCatalog(agent: String) -> AgentCatalog? {
        guard let entry = loadCache().entries[agent] else { return nil }
        return AgentCatalog(agent: agent, models: entry.models, warning: entry.warning)
    }

    /// Blocking bridge for synchronous request handlers: the api server runs
    /// call() off the main thread and discovery is bounded subprocess work.
    public static func catalogSync(agent: String, refresh: Bool = false, cwd: String = "") -> AgentCatalog {
        let box = LockedBox<AgentCatalog>(AgentCatalog(agent: agent))
        Task.detached {
            box.set(await catalog(agent: agent, refresh: refresh, cwd: cwd))
        }
        while !box.filled { usleep(10_000) }
        return box.get()
    }

    /// Minimal lock + value cell for the blocking bridge.
    final class LockedBox<Value> {
        private let lock = NSLock()
        private var value: Value
        private(set) var filled = false
        init(_ initial: Value) { value = initial }
        func set(_ newValue: Value) {
            lock.lock(); value = newValue; filled = true; lock.unlock()
        }
        func get() -> Value {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    static func isFresh(_ entry: CacheEntry, toolPath: String, now: TimeInterval) -> Bool {
        entry.toolPath == toolPath && now - entry.fetchedAt < ttl
    }

    /// Cache-aware discovery. Never throws: failures degrade to a warning and,
    /// when available, the last-good catalog.
    public static func catalog(agent: String, refresh: Bool = false, cwd: String = "") async -> AgentCatalog {
        let toolPath = locateTool(agent) ?? ""
        if toolPath.isEmpty {
            let warning = agent + " not found on PATH; install it or check the app's PATH"
            if let stale = loadCache().entries[agent] {
                return AgentCatalog(agent: agent, models: stale.models, warning: warning)
            }
            return AgentCatalog(agent: agent, models: [], warning: warning)
        }
        let now = Date().timeIntervalSince1970
        if !refresh, let entry = loadCache().entries[agent], isFresh(entry, toolPath: toolPath, now: now) {
            return AgentCatalog(agent: agent, models: entry.models, warning: entry.warning)
        }
        let catalog: AgentCatalog
        switch agent {
        case "pi":
            catalog = PiModels.discover(piPath: toolPath, cwd: cwd)
        case "codex":
            catalog = await CodexModels.discover(codexPath: toolPath)
        default:
            return AgentCatalog(agent: agent, models: [], warning: "unknown agent: " + agent)
        }
        if catalog.warning.isEmpty || !catalog.models.isEmpty {
            var file = loadCache()
            file.entries[agent] = CacheEntry(
                agent: agent, toolPath: toolPath, fetchedAt: Date().timeIntervalSince1970,
                models: catalog.models, warning: catalog.warning)
            writeCache(file)
            return catalog
        }
        // Discovery failed with no models: serve last-good data, marked stale.
        if let stale = loadCache().entries[agent], !stale.models.isEmpty {
            let warning = "Cached models; refresh failed: " + catalog.warning
            return AgentCatalog(agent: agent, models: stale.models, warning: warning)
        }
        return catalog
    }
}
