import Foundation
import RaptorAPI
import RaptorConfig
import RaptorDispatch
import RaptorPanel
import RaptorPaths
import RaptorPullrequest
import RaptorRex
import RaptorRexconfig
import RaptorTask

// Go's flag package, subset: -flag value / -flag=value / bool -flag.
struct Flags {
    private(set) var args: [String]
    private var index = 0

    init(_ args: [String]) { self.args = args }

    private func value(after key: String) -> String? {
        let pair = key.split(separator: "=", maxSplits: 1).map(String.init)
        if pair.count == 2 { return pair[1] }
        guard index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    /// Returns (string values by flag, bool flags, positionals).
    /// Go's flag.Parse stops collecting flags at the first positional; pass
    /// `continuePastPositional: true` only for service-style mixed parsing.
    static func parse(_ argv: [String], valueFlags: Set<String>, boolFlags: Set<String> = [], continuePastPositional: Bool = false) -> (values: [String: String], bools: Set<String>, positional: [String]) {
        var values: [String: String] = [:]
        var bools = Set<String>()
        var positional: [String] = []
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            guard arg.hasPrefix("-"), arg != "-" else {
                positional.append(arg)
                i += 1
                if !continuePastPositional {
                    while i < argv.count {
                        positional.append(argv[i])
                        i += 1
                    }
                }
                continue
            }
            let key = String(arg.drop(while: { $0 == "-" }))
            if boolFlags.contains(key) || (!valueFlags.contains(key) && arg.contains("=") == false && (i + 1 >= argv.count || argv[i + 1].hasPrefix("-"))) {
                if arg.contains("=") {
                    values[key] = String(arg.split(separator: "=", maxSplits: 1).last ?? "")
                } else {
                    bools.insert(key)
                }
                i += 1
                continue
            }
            let pair = key.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 {
                values[pair[0]] = pair[1]
                i += 1
                continue
            }
            if i + 1 < argv.count {
                values[key] = argv[i + 1]
                i += 2
                continue
            }
            values[key] = ""
            i += 1
        }
        return (values, bools, positional)
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func out(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

/// fixPath makes rex, gh, git findable when launched from the Rex server,
/// whose PATH is minimal.
func fixPath() {
    let extra = [
        RaptorPaths.home() + "/.local/share/mise/shims",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        RaptorPaths.home() + "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS",
    ]
    var cur = RaptorPaths.env("PATH") ?? ""
    for p in extra where !cur.contains(p) {
        cur = p + ":" + cur
    }
    setenv("PATH", cur, 1)
}

let argv = Array(CommandLine.arguments.dropFirst())

// Rex passes context as flags on every subcommand.
let (globals, _, rest) = Flags.parse(argv, valueFlags: ["session", "block", "client", "title"])
let env = ProcessInfo.processInfo.environment
let ctx = Ctx(
    session: globals["session"] ?? env["REX_SESSION"] ?? "",
    block: globals["block"] ?? env["REX_BLOCK"] ?? "",
    client: globals["client"] ?? "",
    title: globals["title"] ?? ""
)

guard let command = rest.first else {
    FileHandle.standardError.write(Data(("usage: raptor [context flags] <init|task|setup|api|direct|last-session|panel|service> [command flags]\n").utf8))
    exit(2)
}
fixPath()
let cfg = RaptorConfig.load()
let sub = Array(rest.dropFirst())

switch command {
case "api":
    let token = CancelToken()
    // Unblock an idle request reader as well as canceling Rex children.
    func installSignal(_ sig: Int32) {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler {
            FileHandle.standardInput.closeFile()
            token.cancel()
        }
        source.resume()
        // Keep the source alive for the process lifetime.
        objc_setAssociatedObject(token, "sig\(sig)", source, .OBJC_ASSOCIATION_RETAIN)
    }
    installSignal(SIGINT)
    installSignal(SIGTERM)
    do {
        let handler = Handler(ctx: ctx, cfg: cfg)
        try handler.serveContext(
            input: PipeInput(FileHandle.standardInput),
            output: PipeOutput(FileHandle.standardOutput),
            cancel: token
        )
    } catch {
        // Go: errors after normal cancellation are not fatal reports.
        if !token.isCancelled {
            fail(String(describing: error))
        }
    }
case "task":
    let (values, _, _) = Flags.parse(sub, valueFlags: ["repo", "resume"])
    do {
        let result = try RaptorTask.start(ctx: ctx, cfg: cfg, explicitRepo: values["repo"] ?? "", resumePath: values["resume"] ?? "")
        let data = try JSONEncoder().encode(result)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch let e as StartError {
        fail(String(describing: e.cause))
    } catch {
        fail(String(describing: error))
    }
case "setup":
    let (values, bools, _) = Flags.parse(sub, valueFlags: ["path"], boolFlags: ["retry"])
    var path = values["path"] ?? ""
    if path.isEmpty {
        path = FileManager.default.currentDirectoryPath
    }
    do {
        try Pullrequest.setup(path: path, retry: bools.contains("retry"))
    } catch {
        fail(String(describing: error))
    }
case "direct":
    guard sub.count >= 2 else {
        FileHandle.standardError.write(Data(("usage: raptor direct <target> <dir>\n").utf8))
        exit(2)
    }
    do {
        try RaptorDispatch.dispatch(target: sub[0], dir: sub[1], ctx: ctx, cfg: cfg)
    } catch {
        fail(String(describing: error))
    }
case "init":
    let (values, bools, _) = Flags.parse(sub, valueFlags: ["config"], boolFlags: ["force"])
    let target = values["config"].flatMap { $0.isEmpty ? nil : $0 } ?? Rexconfig.configPath()
    let plugin = Rexconfig.locatePlugin()
    guard !plugin.isEmpty else { fail("Rex plugin not found; reinstall Raptor before running raptor init") }
    do {
        let created = try Rexconfig.apply(configPath: target, plugin: plugin, options: Rexconfig.defaultOptions(), force: bools.contains("force"))
        out("Wired plugin: \(plugin)")
        out("Rex config: \(target)\(created ? " (created)" : " (managed block updated)")")
        out("Bindings: shift+cmd+o opens Raptor; shift+cmd+c opens Checkout pull request;")
        out("shift+cmd+n opens the worktree form;")
        out("ctrl+shift+n starts an instant agent worktree (pi).")
        out("Finish with: rex config reload")
    } catch {
        fail(String(describing: error))
    }
case "serve":
    // Resident panel host: owns the NSPanel and the backend child. Spawned
    // detached by the panel client when the socket is missing; under Rex's
    // process chain so file-access grants are inherited.
    MainActor.assumeIsolated { HostMain.run() }
case "panel":
    let (values, _, _) = Flags.parse(sub, valueFlags: ["mode", "repo"])
    let req = RaptorPanel.Request(
        action: "open",
        mode: values["mode"] ?? "dirs",
        session: ctx.session,
        block: ctx.block,
        client: ctx.client,
        title: ctx.title,
        repo: values["repo"] ?? ""
    )
    do {
        try Panel.open(req)
    } catch let e as UnavailableError {
        FileHandle.standardError.write(Data((String(describing: e) + "\n").utf8))
        exit(3) // Callers surface the error; there is no app fallback.
    } catch {
        fail(String(describing: error))
    }
case "last", "last-session":
    do {
        out(try Rex.selectLast(ctx))
    } catch {
        fail(String(describing: error))
    }
case "version":
    out(raptorVersion)
default:
    FileHandle.standardError.write(Data(("usage: raptor [context flags] <init|task|setup|api|direct|last-session|panel|serve> [command flags]\n").utf8))
    exit(2)
}
