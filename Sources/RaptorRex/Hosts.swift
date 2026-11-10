import Foundation
import Darwin

public extension Rex {
    /// LocalHostLabel is the display name of the server this picker runs against.
    static let localHostLabel = "This Mac"

    static let hostWorkers = 4
}

/// Host is one selectable group header in the Sessions view. The local server
/// is always first and unnamed in rex terms: its sessions need no -S flag.
public struct Host: Equatable {
    public var id: String
    public var label: String
    public var local: Bool

    public init(id: String = "", label: String = "", local: Bool = false) {
        self.id = id
        self.label = label
        self.local = local
    }
}

struct HostsResult: Decodable {
    struct Entry: Decodable {
        var id: String
        var label: String

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decode(String.self, forKey: .id)) ?? ""
            label = (try? c.decode(String.self, forKey: .label)) ?? ""
        }

        enum CodingKeys: String, CodingKey {
            case id, label
        }
    }

    var hosts: [Entry]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hosts = try c.decodeIfPresent([Entry].self, forKey: .hosts)
    }

    enum CodingKeys: String, CodingKey { case hosts }
}

struct HostAppClient: Decodable {
    var clientID: String
    var connectionState: String
    var infoKind: String
    var infoLabel: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientID = (try? c.decode(String.self, forKey: .clientID)) ?? ""
        connectionState = (try? c.decode(String.self, forKey: .connectionState)) ?? ""
        let info = try? c.nestedContainer(keyedBy: InfoKeys.self, forKey: .info)
        infoKind = (try? info?.decode(String.self, forKey: .kind)) ?? ""
        infoLabel = (try? info?.decode(String.self, forKey: .label)) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case connectionState = "connection_state"
        case info
    }

    enum InfoKeys: String, CodingKey {
        case kind, label
    }
}

struct ClientsResponse: Decodable {
    var clients: [HostAppClient]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clients = try c.decodeIfPresent([HostAppClient].self, forKey: .clients)
    }

    enum CodingKeys: String, CodingKey { case clients }
}

public extension Rex {
    /// Hosts lists the local server plus every remote Rex server it knows. Failures
    /// keep the local entry: a sessions view without hosts still lists local work.
    static func hosts() -> [Host] {
        var hosts = [Host(label: localHostLabel, local: true)]
        guard let out = try? run("api", "call", "hosts.list"),
              let data = decodeJSON(HostsResult.self, from: Data(out.utf8)) else {
            return hosts
        }
        var seen = Set<String>([localHostLabel])
        for h in data.hosts ?? [] {
            let label = h.label.trimmingCharacters(in: .whitespaces)
            if label.isEmpty || seen.contains(label) {
                continue
            }
            seen.insert(label)
            hosts.append(Host(id: h.id, label: label))
        }
        return hosts
    }

    /// LocalHostLabelOr normalizes the empty host to the local display label.
    static func localHostLabelOr(_ host: String) -> String {
        if host.isEmpty || host == localHostLabel {
            return localHostLabel
        }
        return host
    }

    /// ClientLabel returns a unique app label on the local server. A label is only
    /// a cross-host routing hint, not device identity. Refuse ambiguous origins.
    static func clientLabel(_ clientID: String) -> String {
        var clientID = clientID
        if !clientID.hasPrefix("client:") {
            clientID = resolveHostTarget("", "client", clientID)
        }
        if clientID.isEmpty {
            return ""
        }
        for client in appClientsOn("") ?? [] {
            if client.clientID == clientID && client.connectionState != "lost" {
                let label = client.infoLabel.trimmingCharacters(in: .whitespaces)
                if !label.isEmpty && uniqueAppClient(appClientsOn("") ?? [], label) == clientID {
                    return label
                }
                return ""
            }
        }
        return ""
    }

    /// appClientOn returns a full ID only for one app with this exact label on the
    /// target host. Never reuse a local client ID or choose the first duplicate.
    static func appClientOn(_ host: String, _ label: String) -> String {
        let label = label.trimmingCharacters(in: .whitespaces)
        if label.isEmpty {
            return ""
        }
        return uniqueAppClient(appClientsOn(host) ?? [], label)
    }
}

extension Rex {
    static func appClientsOn(_ host: String) -> [HostAppClient]? {
        guard let out = try? runOn(host, "api", "call", "client.list", "{\"kinds\":[\"app\"]}"),
              let data = decodeJSON(ClientsResponse.self, from: Data(out.utf8)) else {
            return nil
        }
        return data.clients
    }

    static func uniqueAppClient(_ clients: [HostAppClient], _ label: String) -> String {
        var id = ""
        for client in clients {
            if client.infoKind != "app" || client.infoLabel.trimmingCharacters(in: .whitespaces) != label {
                continue
            }
            // A lost duplicate may reconnect. It still makes this label unsafe.
            if !id.isEmpty || !client.clientID.hasPrefix("client:") || client.connectionState == "lost" {
                return ""
            }
            id = client.clientID
        }
        return id
    }

    /// resolveHostTarget uses the named server's ambiguity rules, without inherited
    /// local session/client context. Unknown statuses and malformed replies fail shut.
    static func resolveHostTarget(_ host: String, _ kind: String, _ query: String) -> String {
        let payload = marshalSorted(["kinds": [kind], "queries": [query]])
        guard let out = try? runOn(host, "api", "call", "target.resolve", payload),
              let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let results = obj["results"] as? [[String: Any]], results.count == 1 else {
            return ""
        }
        let result = results[0]
        let target = result["target"] as? [String: Any] ?? [:]
        if result["query"] as? String != query || result["status"] as? String != "resolved" || target["kind"] as? String != kind {
            return ""
        }
        if kind == "client", let id = target["client_id"] as? String, id.hasPrefix("client:") {
            return id
        }
        if kind == "session", let id = target["session_id"] as? String, id.hasPrefix("session:") {
            return id
        }
        return ""
    }

    private static let hostnameLock = NSLock()
    private static var hostnameCache: String?

    /// LocalHostname resolves a display name, not server identity: Rex's Tailscale
    /// DNS label when available, else the OS hostname, else the generic
    /// label. Cached for the process lifetime — badges render it on every row.
    static func localHostname() -> String {
        hostnameLock.lock()
        if let cached = hostnameCache {
            hostnameLock.unlock()
            return cached
        }
        hostnameLock.unlock()

        var name = ""
        if let out = try? runOnBounded("", 2, "api", "call", "server.status"),
           let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
           let tailscale = obj["tailscale"] as? [String: Any] {
            let dnsName = (tailscale["dns_name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let label = dnsName.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if !label.isEmpty {
                name = label
            }
        }
        if name.isEmpty, let hostname = osHostname() {
            name = hostname
        }
        if name.isEmpty {
            name = localHostLabel
        }
        hostnameLock.lock()
        hostnameCache = name
        hostnameLock.unlock()
        return name
    }

    /// Test hook mirroring Go's `localHostnameOnce = sync.Once{}` reset.
    static func resetLocalHostnameForTesting() {
        hostnameLock.lock()
        hostnameCache = nil
        hostnameLock.unlock()
    }

    static func osHostname() -> String? {
        var name = [CChar](repeating: 0, count: 1024)
        guard gethostname(&name, name.count) == 0 else { return nil }
        let trimmed = String(cString: name).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// IsLocalHost reports whether a host label refers to the local server.
    /// Rows carry the display hostname; actions must treat it as local.
    static func isLocalHost(_ host: String) -> Bool {
        if host.isEmpty || host == localHostLabel {
            return true
        }
        return host.caseInsensitiveCompare(localHostname()) == .orderedSame
    }

    /// SameSession compares a local session ID with an origin reference. Non-exact
    /// references must resolve uniquely on the local server, never by suffix alone.
    static func sameSession(_ full: String, _ origin: String) -> Bool {
        sameSessionOn("", full, origin)
    }

    /// SameSessionOn resolves references only on host. Callers must supply IDs from
    /// that host; inherited local origin IDs must not be used for remote sessions.
    static func sameSessionOn(_ host: String, _ full: String, _ origin: String) -> Bool {
        if origin.trimmingCharacters(in: .whitespaces).isEmpty || full.isEmpty {
            return false
        }
        if full == origin {
            return true
        }
        if origin.hasPrefix("session:") {
            return false
        }
        return full == resolveHostTarget(host, "session", origin)
    }

    /// NormalizeHost collapses a local display name to the empty host so actions
    /// take the local code path.
    static func normalizeHost(_ host: String) -> String {
        if isLocalHost(host) {
            return ""
        }
        return host
    }

    /// mapHosts runs one job per host in parallel (bounded by hostWorkers) and
    /// keeps Hosts() order.
    static func mapHosts(_ hosts: [Host], job: @escaping (Host) -> Void) {
        let workers = min(hostWorkers, hosts.count)
        guard workers > 0 else { return }
        let semaphore = DispatchSemaphore(value: workers)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "rex.mapHosts", attributes: .concurrent)
        for host in hosts {
            semaphore.wait()
            group.enter()
            queue.async {
                defer {
                    semaphore.signal()
                    group.leave()
                }
                job(host)
            }
        }
        group.wait()
    }
}
