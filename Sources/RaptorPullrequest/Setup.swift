import Foundation
import RaptorWorktree

// Worktrunk forwards unreferenced --KEY=VALUE options as hook arguments.
// Restrict overrides to template expressions, not literal command text.
func hookVariableArguments(_ values: [String], hooks: [Any]) -> [String] {
    let templates = hooks.compactMap { ($0 as? [String: Any])?["template"] as? String }
    return values.compactMap { value in
        let key = String(value.prefix { $0 != "=" })
        let identifier = NSRegularExpression.escapedPattern(for: key)
        let pattern = #"\{\{[^}]*\b"# + identifier + #"\b[^}]*\}\}|\{%[^%]*\b"# + identifier + #"\b[^%]*%\}"#
        return templates.contains { $0.range(of: pattern, options: .regularExpression) != nil }
            ? "--" + value : nil
    }
}

/// checkPreSwitch fails closed: Prepare has no interactive destination yet. A
/// source pre-switch hook must never be moved after creation or auto-approved.
func checkPreSwitch(_ repo: String) throws {
    let out: String
    do {
        out = try command(repo, "wt", ["hook", "show", "pre-switch", "--format=json"])
    } catch {
        throw MessageError("Worktrunk manual-hook support required: \(error)")
    }
    let hooks = jsonArray(out)
    if hooks == nil {
        throw MessageError("invalid JSON: pre-switch hook inspection must return a valid JSON array")
    }
    if !hooks!.isEmpty {
        throw MessageError("source has pre-switch hooks; run wt switch interactively before Prepare (automatic pre-switch approval is unsafe)")
    }
}

/// Include effective user/system config, not guessed platform config paths.
func configStamp(_ path: String) throws -> String {
    let out = try command(path, "wt", ["config", "show", "--format=json"])
    guard let cfg = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] else {
        throw MessageError("invalid JSON: wt config show")
    }
    // Hash both effective metadata and file bytes. Config JSON alone can omit
    // comments or content not represented by the parsed configuration.
    var contents: [String: String] = [:]
    for kind in ["user", "system", "project"] {
        let data = try configBytes(cfg[kind])
        contents[kind] = sha256Hex(data)
    }
    guard let final = try? JSONSerialization.data(withJSONObject: ["Config": cfg, "Contents": contents],
                                                  options: [.sortedKeys]) else {
        throw MessageError("encode config stamp")
    }
    return sha256Hex(final)
}

func sameProjectConfig(source: String, destination: String) throws {
    func read(_ root: String) throws -> Data? {
        let out = try command(root, "wt", ["config", "show", "--format=json"])
        guard let cfg = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] else {
            throw MessageError("invalid JSON: wt config show")
        }
        return try configBytes(cfg["project"])
    }
    let a = try read(source)
    let b = try read(destination)
    if a != b {
        throw MessageError("source and destination effective project configs differ; deferred hooks cannot preserve source config safely; run setup manually")
    }
}

func configBytes(_ raw: Any?) throws -> Data? {
    guard let obj = raw as? [String: Any] else {
        throw MessageError("effective config path unavailable")
    }
    let entryPath = (obj["path"] as? String) ?? (obj["Path"] as? String) ?? ""
    let entryExists = (obj["exists"] as? Bool) ?? (obj["Exists"] as? Bool) ?? false
    if entryPath.isEmpty {
        throw MessageError("effective config path unavailable")
    }
    do {
        return try Data(contentsOf: URL(fileURLWithPath: entryPath))
    } catch {
        if isNotExist(error) && !entryExists {
            return nil
        }
        throw error
    }
}

func interactive(_ path: String, _ args: [String]) throws {
    // Interactive installs have no arbitrary timeout. The caller can interrupt.
    let (code, exited) = try Procs.runInherit(dir: path, name: "wt", args: args)
    if !exited {
        throw CmdError(name: "wt", kind: .signal(SIGKILL), stderr: "", stdout: "", exitedNormally: false)
    }
    if code != 0 {
        throw ExitStatusError(code: code)
    }
}

func approvals(_ path: String, _ phase: String) throws {
    let out = try command(path, "wt", ["config", "approvals", "list", "--format=json"])
    guard let obj = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any],
          let commands = obj["commands"] as? [[String: Any]] else {
        throw MessageError("invalid JSON: wt config approvals")
    }
    for c in commands {
        if (c["phase"] as? String ?? "") == phase && (c["approved"] as? Bool ?? false) == false {
            throw MessageError("\(phase) approval declined or not saved; setup is incomplete")
        }
    }
}

extension Pullrequest {
    /// Setup runs in the destination terminal. The parent CLI must return its
    /// error, not exec this runner: Open's shell wrapper then starts a usable
    /// login shell. Retry resumes the failed/interrupted stage, never recreates
    /// resources. Failure diagnostics go to stderr exactly like the Go port.
    public static func setup(path: String, retry: Bool) throws {
        let original = path
        do {
            try setupImpl(path: path, retry: retry)
        } catch {
            let exe = executablePath()
            fputs("Worktree setup failed: \(error)\nRetry: \(quote(exe)) setup --path \(quote(original)) --retry\n", Darwin.stderr)
            fflush(Darwin.stderr)
            throw error
        }
    }

    static func setupImpl(path originalPath: String, retry: Bool) throws {
        let path = try canonical(originalPath)
        // The setup process itself is the terminal-readiness signal. It waits until
        // Open persists release AFTER requesting selection; no visual ack is assumed.
        let deadline = Date().addingTimeInterval(2 * 60)
        while true {
            if let unlock = try? lock(path, false) {
                let s: SetupState
                do {
                    s = try load(path)
                } catch {
                    unlock()
                    throw error
                }
                unlock()
                if !validState(path, s) {
                    throw MessageError("no valid setup state for this worktree instance: \(path); call Prepare")
                }
                if s.released {
                    break
                }
            }
            if Date() > deadline {
                throw MessageError("destination not released; retry Open, then retry setup")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let unlock = try lock(path, false)
        defer { unlock() }
        let s: SetupState
        do {
            s = try load(path)
        } catch {
            throw error
        }
        if !validState(path, s) {
            throw MessageError("worktree instance changed; call Prepare")
        }
        if s.complete {
            return
        }
        if (s.failed ?? "").hasSuffix(" interrupted") && s.stage < 3 && s.new && s.stage > 0 {
            throw MessageError("background launch status is uncertain; inspect wt config state logs before manual recovery (not replayed)")
        }
        if !s.new && s.failed == "post-switch interrupted" {
            throw MessageError("background launch status is uncertain; inspect wt config state logs before manual recovery (not replayed)")
        }
        if let failed = s.failed, !failed.isEmpty, !retry {
            throw MessageError("previous setup failed or was interrupted: \(failed); use --retry")
        }
        let stamp = try configStamp(s.source)
        if stamp != s.config {
            throw MessageError("hook config changed since Prepare; inspect and run setup manually")
        }
        try sameProjectConfig(source: s.source, destination: path)
        var stages = ["post-switch"]
        if s.new {
            stages = ["pre-start", "post-start", "post-switch"]
        }
        var state = s
        while state.stage < stages.count {
            let phase = stages[state.stage]
            let hooks = try command(path, "wt", ["hook", "show", phase, "--format=json"])
            guard let configured = jsonArray(hooks) else {
                throw MessageError("\(phase) hook inspection must return a valid JSON array")
            }
            if configured.isEmpty {
                // Empty phases still advance durably, but require neither execution nor
                // approval. Do not mark an absent background launch as interrupted.
                state.stage += 1
                state.failed = nil
                try save(path, state)
                continue
            }
            var args = ["hook", phase]
            if phase == "pre-start" {
                args.append("--foreground")
            }
            // Manual hooks run in destination cwd with destination config. Identical
            // project config is required above. Preserve source/base and PR variables.
            // Shorthand binds referenced variables, but forwards unused keys into
            // {{ args }}. Send only values referenced by this phase's templates.
            var values = ["branch=\(state.branch)", "worktree_path=\(path)",
                          "target=\(state.branch)", "target_worktree_path=\(path)"]
            if !state.url.isEmpty {
                let parts = state.url.components(separatedBy: "/")
                values.append(contentsOf: ["base_worktree_path=\(state.source)",
                                           "pr_url=\(state.url)", "pr_number=\(parts.last ?? "")"])
            } else if let basePath = state.basePath, !basePath.isEmpty {
                values.append("base_worktree_path=\(basePath)")
            } else {
                // Manual hook context supplies the current worktree as a default.
                // Native creation has no base_worktree_path when the base ref has
                // no checkout. Stop if a hook uses it; never supply a wrong path.
                if hooks.contains("base_worktree_path") {
                    throw MessageError("\(phase) uses base_worktree_path but the base has no worktree; run this setup manually")
                }
            }
            if !state.base.isEmpty { values.append("base=\(state.base)") }
            args.append(contentsOf: hookVariableArguments(values, hooks: configured))
            state.failed = phase + " interrupted"
            try save(path, state)
            var stageErr: (any Error)?
            do {
                try interactive(path, args)
            } catch {
                stageErr = error
            }
            if stageErr == nil {
                do {
                    try approvals(path, phase)
                } catch {
                    stageErr = error
                }
            }
            if let e = stageErr {
                state.failed = phase + ": " + String(describing: e)
                do {
                    try save(path, state)
                } catch {
                    throw MessageError("\(state.failed ?? ""); state: \(error)")
                }
                throw MessageError(state.failed ?? "")
            }
            state.stage += 1
            state.failed = nil
            try save(path, state)
        }
        state.complete = true
        try save(path, state)
    }
}
