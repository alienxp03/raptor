import Foundation
import RaptorExecx
import RaptorPaths

/// Namespace for the ported internal/rex package.
public enum Rex {}

/// Thrown where Go returned a formatted error. The message keeps the Go
/// error text so protocol-adjacent strings stay identical.
public struct RexError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Session/block/client/title flags carried into Rex calls.
public struct Ctx: Equatable {
    public var session: String
    public var block: String
    public var client: String
    public var title: String

    public init(session: String = "", block: String = "", client: String = "", title: String = "") {
        self.session = session
        self.block = block
        self.client = client
        self.title = title
    }
}

public extension Rex {
    /// Go's time.Time zero value, used to keep "missing timestamp" semantics.
    static let zeroTime = Date(timeIntervalSince1970: -62_135_596_800)

    static func newContext(session: String, block: String, client: String, title: String) -> Ctx {
        Ctx(session: session, block: block, client: client, title: title)
    }

    // ---------- rex CLI wrappers ----------

    static func runCmd(dir: String, timeout: TimeInterval, name: String, args: [String]) throws -> ExecResult {
        try Execx.run(dir: dir, timeout: timeout, name: name, args: args)
    }

    /// Runs `rex` with a 15s process budget; nonzero exits throw with the
    /// joined command line and trimmed stderr, like the Go wrapper.
    @discardableResult
    static func run(_ args: [String]) throws -> String {
        let r = try runCmd(dir: "", timeout: 15, name: "rex", args: args)
        if r.code != 0 {
            throw RexError("rex \(args.joined(separator: " ")): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return r.stdout
    }

    @discardableResult
    static func run(_ args: String...) throws -> String {
        try run(args)
    }

    static func runQuiet(_ args: String...) {
        _ = try? run(args)
    }

    /// Do targets a client (e.g. session.select). Remote Control required.
    /// Named doAction: `do` is a Swift keyword.
    static func doAction(client: String, action: String, kv: String...) throws {
        try doAction(client: client, action: action, kv: kv)
    }

    static func doAction(client: String, action: String, kv: [String]) throws {
        var args = ["-C", client, "do", action]
        args.append(contentsOf: kv)
        _ = try run(args)
        recordSelectedSession("", action, kv)
    }

    /// RunOn targets a host's Rex server. The empty host and the local label are
    /// the local server: its sessions need no -S flag.
    @discardableResult
    static func runOn(_ host: String, _ args: String...) throws -> String {
        try runOn(host, args)
    }

    @discardableResult
    static func runOn(_ host: String, _ args: [String]) throws -> String {
        if host.isEmpty || host == localHostLabel {
            return try run(args)
        }
        return try run(["-S", host] + args)
    }

    /// RunOnBounded bounds a host call. Remote calls pass rex's own --timeout so a
    /// down host cannot stall the sessions view: rex otherwise waits its default
    /// 10s per connection. Local calls only get the process kill as a backstop.
    /// The extra second covers process startup and shutdown.
    @discardableResult
    static func runOnBounded(_ host: String, _ seconds: Int, _ args: String...) throws -> String {
        try runOnBounded(host, seconds, args)
    }

    @discardableResult
    static func runOnBounded(_ host: String, _ seconds: Int, _ args: [String]) throws -> String {
        let timeout = TimeInterval(seconds + 1)
        var callArgs = args
        if !(host.isEmpty || host == localHostLabel) {
            callArgs = ["-S", host, "--timeout", "\(seconds)s"] + args
        }
        let r = try runCmd(dir: "", timeout: timeout, name: "rex", args: callArgs)
        if r.code != 0 {
            throw RexError("rex \(callArgs.joined(separator: " ")): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return r.stdout
    }

    /// DoOn targets a client on one host's server.
    static func doOn(_ host: String, _ client: String, _ action: String, kv: String...) throws {
        try doOn(host, client, action, kv: kv)
    }

    static func doOn(_ host: String, _ client: String, _ action: String, kv: [String]) throws {
        var args = ["-C", client, "do", action]
        args.append(contentsOf: kv)
        _ = try runOn(host, args)
        recordSelectedSession(host, action, kv)
    }

    static func sessions() -> [RexSession]? {
        guard let out = try? run("ls", "--json") else { return nil }
        guard let data = decodeJSON(SessionsResponse.self, from: Data(out.utf8)) else { return nil }
        return data.sessions
    }

    /// Returns the session ID when a session with this label exists.
    static func sessionByLabel(_ label: String) -> String? {
        for s in sessions() ?? [] where s.label == label {
            return s.sessionID
        }
        return nil
    }

    /// BlockPwd returns the cwd a block last reported, via rex do.
    static func blockPwd(_ blockID: String) -> String {
        if blockID.isEmpty { return "" }
        let script = "local r = rex.block.call('com.superlogical.terminal', 'pwd', { block_id = '\(blockID)' }) print(r and r.pwd or '')"
        guard let out = try? run("do", "-b", blockID, "-e", script) else { return "" }
        return reportedDirectory(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// BlockCwd returns the cwd of a block's foreground process (works even when
    /// the terminal never reported OSC 7, e.g. while a TUI app owns the pane).
    static func blockCwd(_ blockID: String) -> String {
        blockCwdInSession("", blockID)
    }

    /// BlockCwdInSession avoids inheriting an unrelated caller's REX_SESSION when
    /// a backend was explicitly given context for another session.
    static func blockCwdInSession(_ sessionID: String, _ blockID: String) -> String {
        if blockID.isEmpty { return "" }
        // Resolve reported cwd and foreground fallback in one Rex invocation.
        let script = "local ok, r = pcall(rex.block.call, 'com.superlogical.terminal', 'pwd', { block_id = '\(blockID)' }) "
            + "local pwd = ok and r and r.pwd "
            + "if pwd and pwd ~= '' then print(pwd) else "
            + "local p = rex.block.call('com.superlogical.terminal', 'process', { block_id = '\(blockID)' }) "
            + "print(p and p.foreground and p.foreground.cwd or '') end"
        var args = ["do"]
        if !sessionID.isEmpty {
            args.append(contentsOf: ["-s", sessionID])
        }
        args.append(contentsOf: ["-b", blockID, "-e", script])
        guard let out = try? run(args) else { return "" }
        return reportedDirectory(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// reportedDirectory decodes the file URL returned by Rex's pwd method (OSC 7).
    /// URL authorities are metadata, not a path prefix. Plain paths stay unchanged.
    static func reportedDirectory(_ value: String) -> String {
        guard value.hasPrefix("file:") else { return value }
        guard let c = URLComponents(string: value), c.scheme == "file" else { return "" }
        if c.user != nil || c.query != nil || c.fragment != nil { return "" }
        // Go's url.Parse fails on invalid escapes ("%ZZ"); Foundation re-encodes
        // them, so decode the raw path strictly here.
        var raw = String(value.dropFirst("file:".count))
        if raw.hasPrefix("//") {
            raw = String(raw.dropFirst(2))
            if let slash = raw.firstIndex(of: "/") {
                raw = String(raw[slash...])
            } else {
                raw = ""
            }
        }
        if !raw.hasPrefix("/") { return "" }
        guard let path = percentDecode(raw) else { return "" }
        return path
    }

    static func percentDecode(_ s: String) -> String? {
        let bytes = Array(s.utf8)
        var out = [UInt8]()
        var i = 0
        func hexVal(_ b: UInt8) -> Int? {
            switch b {
            case 48...57: return Int(b - 48)
            case 65...70: return Int(b - 55)
            case 97...102: return Int(b - 87)
            default: return nil
            }
        }
        while i < bytes.count {
            if bytes[i] == 0x25 {
                guard i + 2 < bytes.count, let hi = hexVal(bytes[i + 1]), let lo = hexVal(bytes[i + 2]) else {
                    return nil
                }
                out.append(UInt8(hi * 16 + lo))
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// blockForeground returns the foreground process name of a block.
    static func blockForeground(_ blockID: String) -> String {
        if blockID.isEmpty { return "" }
        let script = "local r = rex.block.call('com.superlogical.terminal', 'process', { block_id = '\(blockID)' }) print(r and r.foreground and r.foreground.name or '')"
        guard let out = try? run("do", "-b", blockID, "-e", script) else { return "" }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // ---------- zoxide ----------

    static func zoxideList() -> [String] {
        parseZoxide(try? zoxideOut(""))
    }

    /// ZoxideListOn lists one host's frecency directories. Remote hosts answer over
    /// SSH; a non-interactive login may not carry zoxide on PATH, so well-known
    /// install locations are tried before giving up.
    static func zoxideListOn(_ host: String) -> [String] {
        if host.isEmpty || host == localHostLabel {
            return zoxideList()
        }
        return parseZoxide(try? remoteZoxideOut(host))
    }

    static func parseZoxide(_ result: String?) -> [String] {
        guard let out = result else { return [] }
        var dirs: [String] = []
        for line in out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { dirs.append(trimmed) }
        }
        return dirs
    }

    static func zoxideOut(_ host: String) throws -> String {
        try runCmd(dir: "", timeout: 5, name: "zoxide", args: ["query", "-l"]).stdout
    }

    /// remoteZoxideCandidates keeps unexpanded tilde paths: the remote shell expands them.
    static let remoteZoxideCandidates = [
        "zoxide",
        "~/.local/share/mise/shims/zoxide",
        "~/.local/bin/zoxide",
        "~/.cargo/bin/zoxide",
        "/usr/local/bin/zoxide",
    ]

    static func remoteZoxideOut(_ host: String) throws -> String {
        for zoxide in remoteZoxideCandidates {
            let r = try? runCmd(dir: "", timeout: 8, name: "ssh",
                args: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=4", host, zoxide + " query -l"])
            if let r, r.code == 0 {
                return r.stdout
            }
        }
        throw RexError("zoxide is unavailable on \(host)")
    }

    // ---------- last-session state ----------

    static func statePath() -> String {
        var cache = RaptorPaths.env("XDG_CACHE_HOME") ?? ""
        if cache.isEmpty {
            cache = RaptorPaths.home() + "/.cache"
        }
        return cache + "/rex/raptor-last"
    }

    // ---------- JSON helpers ----------

    /// Lenient decode: missing keys and JSON nulls become Go zero values.
    static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(T.self, from: data)
    }

    /// Encodes a string map like Go's encoding/json: sorted keys, no spaces.
    static func marshalSorted(_ dict: [String: String]) -> String {
        let sorted = dict.sorted { $0.key < $1.key }
        let pairs = sorted.map { key, value in
            jsonQuote(key) + ":" + jsonQuote(value)
        }
        return "{" + pairs.joined(separator: ",") + "}"
    }

    static func marshalSorted(_ dict: [String: [String]]) -> String {
        let sorted = dict.sorted { $0.key < $1.key }
        let pairs = sorted.map { key, values in
            jsonQuote(key) + ":[" + values.map(jsonQuote).joined(separator: ",") + "]"
        }
        return "{" + pairs.joined(separator: ",") + "}"
    }

    static func jsonQuote(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if c.value < 0x20 {
                    out += String(format: "\\u%04x", c.value)
                } else {
                    out.unicodeScalars.append(c)
                }
            }
        }
        return out + "\""
    }
}

/// One row of `rex ls --json`.
public struct RexSession: Decodable, Equatable {
    public var sessionID: String
    public var label: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case label
    }

    public init(sessionID: String = "", label: String = "") {
        self.sessionID = sessionID
        self.label = label
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = (try? c.decode(String.self, forKey: .sessionID)) ?? ""
        label = (try? c.decode(String.self, forKey: .label)) ?? ""
    }
}

struct SessionsResponse: Decodable {
    var sessions: [RexSession]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try c.decodeIfPresent([RexSession].self, forKey: .sessions)
    }

    enum CodingKeys: String, CodingKey { case sessions }
}
