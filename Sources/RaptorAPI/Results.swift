import Foundation
import RaptorCatalog
import RaptorPaths
import RaptorPullrequest
import RaptorRex

/// Tells native clients which group headers to render, including unreachable
/// hosts so their absence is explained rather than silent.
struct HostHeader: Equatable {
    var label: String
    var local: Bool
    var reachable: Bool
    var error: String

    init(label: String = "", local: Bool = false, reachable: Bool = false, error: String = "") {
        self.label = label
        self.local = local
        self.reachable = reachable
        self.error = error
    }

    func js() -> JS {
        var fields: [(String, JS)] = [("label", .string(label))]
        if local {
            fields.append(("local", .bool(local)))
        }
        fields.append(("reachable", .bool(reachable)))
        if !error.isEmpty {
            fields.append(("error", .string(error)))
        }
        return .object(fields)
    }
}

/// One worktree row of the tree picker payload.
struct TreeItem {
    var path: String
    var branch: String
    var isMain: Bool

    func js() -> JS {
        .object([("path", .string(path)), ("branch", .string(branch)), ("is_main", .bool(isMain))])
    }
}

/// api method results. Each case mirrors one Go result struct, keeping field
/// order and omitempty behavior byte-compatible.
enum MethodResult {
    /// Go's struct{}{} — encodes as {}.
    case empty
    /// map[string]any{"theme": theme.ThemeJSON()} with the raw embedded payload.
    case theme(raw: Data)
    case pins(pinned: Bool)
    case agents(items: [AgentEntry], target: String)
    case sessions(
        selectedID: String, items: [LauncherItem], hosts: [HostHeader]?, targets: [String], target: String)
    case directories(items: [Directory], targets: [String], target: String)
    case tree(
        destinationRoot: String, repo: String, needsRepo: Bool, items: [TreeItem], branches: [String],
        baseBranch: String, suggestedBranch: String, targets: [String], target: String)
    case branches(items: [String])
    case preview(path: String, validationError: String)
    case path(String)
    /// sessions.create's map: sorted keys, plus optional error/launcher_items.
    case creation(fields: [(String, JS)])
    case open(OpenResult, launcherItems: [LauncherItem]?)
    case info(Info)
    /// Prepare's recoverable partial: Info fields then "error".
    case preparePartial(Info, error: String)

    func encode() -> String {
        switch self {
        case .empty:
            return "{}"
        case .theme(let raw):
            return "{\"theme\":" + String(decoding: raw, as: UTF8.self) + "}"
        case .pins(let pinned):
            return "{\"pinned\":" + (pinned ? "true" : "false") + "}"
        case .agents(let items, let target):
            return JS.object([("items", .array(items.map(agentEntryJS))), ("targets", .array([])), ("target", .string(target))]).encode()
        case .sessions(let selectedID, let items, let hosts, let targets, let target):
            var fields: [(String, JS)] = []
            if !selectedID.isEmpty {
                fields.append(("selected_id", .string(selectedID)))
            }
            fields.append(("items", .array(items.map { .raw(encodedJSONString($0)) })))
            fields.append(("hosts", hosts == nil ? .null : .array(hosts!.map { $0.js() })))
            fields.append(("targets", .array(targets.map { .string($0) })))
            fields.append(("target", .string(target)))
            return JS.object(fields).encode()
        case .directories(let items, let targets, let target):
            return JS.object([
                ("items", .array(items.map { .raw(encodedJSONString($0)) })),
                ("targets", .array(targets.map { .string($0) })),
                ("target", .string(target)),
            ]).encode()
        case .tree(let destinationRoot, let repo, let needsRepo, let items, let branches, let baseBranch,
            let suggestedBranch, let targets, let target):
            var fields: [(String, JS)] = [
                ("destination_root", .string(destinationRoot)),
                ("repo", .string(repo)),
                ("needs_repo", .bool(needsRepo)),
                ("items", .array(items.map { $0.js() })),
                ("branches", .array(branches.map { .string($0) })),
                ("base_branch", .string(baseBranch)),
            ]
            if !suggestedBranch.isEmpty {
                fields.append(("suggested_branch", .string(suggestedBranch)))
            }
            fields.append(("targets", .array(targets.map { .string($0) })))
            fields.append(("target", .string(target)))
            return JS.object(fields).encode()
        case .branches(let items):
            return JS.object([("branches", .array(items.map { .string($0) }))]).encode()
        case .preview(let path, let validationError):
            return JS.object([("path", .string(path)), ("validation_error", .string(validationError))]).encode()
        case .path(let path):
            return JS.object([("path", .string(path))]).encode()
        case .creation(let fields):
            return JS.object(fields).encode()
        case .open(let result, let launcherItems):
            var fields: [(String, JS)] = [
                ("path", .string(result.path)),
            ]
            if let sessionID = result.sessionID, !sessionID.isEmpty {
                fields.append(("session_id", .string(sessionID)))
            }
            if let windowID = result.windowID, !windowID.isEmpty {
                fields.append(("window_id", .string(windowID)))
            }
            if let blockID = result.blockID, !blockID.isEmpty {
                fields.append(("block_id", .string(blockID)))
            }
            if let error = result.error, !error.isEmpty {
                fields.append(("error", .string(error)))
            }
            if let launcherItems, !launcherItems.isEmpty {
                fields.append(("launcher_items", .array(launcherItems.map { .raw(encodedJSONString($0)) })))
            }
            return JS.object(fields).encode()
        case .info(let info):
            return encodedJSONString(info)
        case .preparePartial(let info, let error):
            let fields: [(String, JS)] = [
                ("input", .string(info.input)),
                ("url", .string(info.url)),
                ("number", .int(Int64(info.number))),
                ("title", .string(info.title)),
                ("branch", .string(info.branch)),
                ("repo", .string(info.repo)),
                ("path", .string(info.path)),
                ("clone_required", .bool(info.cloneRequired)),
                ("existing", .bool(info.existing)),
                ("state", .string(info.state)),
                ("head_deleted", .bool(info.headDeleted)),
                ("head_oid", .string(info.headOID)),
                ("error", .string(error)),
            ]
            return JS.object(fields).encode()
        }
    }
}

/// rex.AgentEntry wire shape: Go struct field order with omitempty tags.
func agentEntryJS(_ entry: AgentEntry) -> JS {
    var fields: [(String, JS)] = [
        ("path", .string(entry.path)),
        ("kind", .string(entry.kind)),
        ("label", .string(entry.label)),
        ("app", .string(entry.app)),
        ("state", .string(entry.state)),
    ]
    if entry.unreadDone { fields.append(("unread_done", .bool(true))) }
    if !entry.agentID.isEmpty {
        fields.append(("agent_id", .string(entry.agentID)))
    }
    fields.append(("session_id", .string(entry.sessionID)))
    fields.append(("session_label", .string(entry.sessionLabel)))
    fields.append(("window_id", .string(entry.windowID)))
    fields.append(("window_label", .string(entry.windowLabel)))
    fields.append(("block_id", .string(entry.blockID)))
    if entry.active {
        fields.append(("active", .bool(true)))
    }
    if let updatedAt = entry.updatedAt {
        fields.append(("updated_at", .string(formatRFC3339Nano(updatedAt))))
    }
    if !entry.cwd.isEmpty {
        fields.append(("cwd", .string(entry.cwd)))
    }
    return .object(fields)
}

/// The on-disk stale-while-revalidate payload: the full unfiltered composition
/// plus its host headers, stamped when fetched.
struct LauncherCacheEntry {
    var timestamp: Date
    // Go zero time when absent (scan_started omitted on disk).
    var scanStarted: Date
    var items: [LauncherItem]?
    var hosts: [HostHeader]?

    init(
        timestamp: Date = Rex.zeroTime, scanStarted: Date = Rex.zeroTime,
        items: [LauncherItem]? = nil, hosts: [HostHeader]? = nil
    ) {
        self.timestamp = timestamp
        self.scanStarted = scanStarted
        self.items = items
        self.hosts = hosts
    }
}

func encodeLauncherCache(_ entry: LauncherCacheEntry) -> Data {
    var out = "{\"timestamp\":\"" + formatRFC3339Nano(entry.timestamp) + "\""
    if entry.scanStarted != Rex.zeroTime {
        out += ",\"scan_started\":\"" + formatRFC3339Nano(entry.scanStarted) + "\""
    }
    out += ",\"items\":" + (entry.items.map { "[" + $0.map { encodedJSONString($0) }.joined(separator: ",") + "]" } ?? "null")
    out += ",\"hosts\":" + (entry.hosts.map { "[" + $0.map { $0.js().encode() }.joined(separator: ",") + "]" } ?? "null")
    out += "}"
    return Data(out.utf8)
}

func decodeLauncherCache(_ data: Data) -> LauncherCacheEntry? {
    var parser = JSONParser([UInt8](data))
    guard let node = try? parser.parseTop(), case .object(let fields) = node.value else { return nil }
    var entry = LauncherCacheEntry()
    for (key, fieldNode) in fields {
        let value = fieldNode.value
        switch key {
        case "timestamp":
            if case .string(let s) = value { entry.timestamp = parseRFC3339(s) ?? Rex.zeroTime }
        case "scan_started":
            if case .string(let s) = value { entry.scanStarted = parseRFC3339(s) ?? Rex.zeroTime }
        case "items":
            guard case .array(let items) = value else {
                if case .null = value { continue }
                return nil
            }
            var rows: [LauncherItem] = []
            for itemNode in items {
                guard let row = decodeLauncherItem(itemNode.value) else { return nil }
                rows.append(row)
            }
            entry.items = rows
        case "hosts":
            guard case .array(let hosts) = value else {
                if case .null = value { continue }
                return nil
            }
            var headers: [HostHeader] = []
            for hostNode in hosts {
                guard case .object(let hf) = hostNode.value else { return nil }
                func str(_ key: String) -> String {
                    if let node = hf.first(where: { $0.0 == key })?.1, case .string(let s) = node.value { return s }
                    return ""
                }
                func bool(_ key: String) -> Bool {
                    if let node = hf.first(where: { $0.0 == key })?.1, case .bool(let b) = node.value { return b }
                    return false
                }
                headers.append(HostHeader(label: str("label"), local: bool("local"), reachable: bool("reachable"), error: str("error")))
            }
            entry.hosts = headers
        default:
            continue
        }
    }
    return entry
}

func decodeLauncherItem(_ value: JSONValue) -> LauncherItem? {
    guard case .object(let fields) = value else { return nil }
    func str(_ key: String) -> String {
        if let node = fields.first(where: { $0.0 == key })?.1, case .string(let s) = node.value { return s }
        return ""
    }
    func bool(_ key: String) -> Bool {
        if let node = fields.first(where: { $0.0 == key })?.1, case .bool(let b) = node.value { return b }
        return false
    }
    var sources: [CompletionSource] = []
    if let node = fields.first(where: { $0.0 == "_completion_sources" })?.1,
       case .array(let rows) = node.value {
        for row in rows {
            guard case .object(let metadata) = row.value else { continue }
            func field(_ key: String) -> String? {
                guard let node = metadata.first(where: { $0.0 == key })?.1,
                      case .string(let value) = node.value else { return nil }
                return value
            }
            if let block = field("block"), let record = field("record"),
               let state = field("state"), let updatedAt = field("updatedAt") {
                sources.append(CompletionSource(block: block, record: record, state: state, updatedAt: updatedAt))
            }
        }
    }
    return LauncherItem(
        kind: str("kind"), id: str("id"), path: str("path"), sessionID: str("session_id"),
        label: str("label"), sessionLabel: str("session_label"), host: str("host"), active: bool("active"),
        local: bool("is_local"), pinned: bool("is_pinned"), state: str("state"), working: bool("working"),
        completionSources: sources)
}

/// Go's filepath.EvalSymlinks + filepath.Abs with a Clean fallback.
func apiCanonicalPath(_ path: String) -> String {
    if path.isEmpty {
        return ""
    }
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    if FileManager.default.fileExists(atPath: resolved) || resolved.hasPrefix("/") {
        let absolute = RaptorPaths.absolute(resolved)
        if !absolute.isEmpty {
            return absolute
        }
    }
    return pathSplitClean(resolved.isEmpty ? path : resolved)
}

/// Go's filepath.Clean port (lexical only).
func pathSplitClean(_ path: String) -> String {
    if path.isEmpty {
        return "."
    }
    let rooted = path.hasPrefix("/")
    var parts: [String] = []
    for comp in path.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
        if comp == "." { continue }
        if comp == ".." {
            if let last = parts.last, last != ".." {
                parts.removeLast()
            } else if !rooted {
                parts.append("..")
            }
            continue
        }
        parts.append(comp)
    }
    var result = parts.joined(separator: "/")
    if rooted { result = "/" + result }
    if result.isEmpty { return "." }
    return result
}
