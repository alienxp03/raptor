import Foundation
import RaptorExecx
import RaptorPaths

/// Pi model discovery via a short-lived Node helper against the installed Pi
/// package. The helper reuses Pi's own SDK (ModelRuntime, enabledModels scope
/// resolution, per-model thinking levels); Swift only parses its JSON output.
/// Loading extensions is avoided: plain ModelRuntime.create keeps discovery
/// side-effect free and honors `enabledModels` from global settings.
public enum PiModels {
    /// Injectable for tests; resolves the node executable or nil.
    public static var locateNode: () -> String? = { Execx.lookup(name: "node") }

    /// Walks up from the resolved pi binary's real path to the package root
    /// (the directory whose package.json names the Pi package).
    static func packageRoot(realPath: String) -> String? {
        var dir = (realPath as NSString).deletingLastPathComponent
        for _ in 0...8 {
            let manifest = dir + "/package.json"
            if let data = FileManager.default.contents(atPath: manifest),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = obj["name"] as? String,
               name == "@earendil-works/pi-coding-agent" {
                return dir
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { return nil }
            dir = parent
        }
        return nil
    }

    /// A mise shim resolves to mise itself, not to Pi. Ask that exact manager
    /// for the active installation; never guess an npm directory or version.
    static func packageRoot(piPath: String, cwd: String = "") -> String? {
        let real = URL(fileURLWithPath: piPath).resolvingSymlinksInPath()
        if let root = packageRoot(realPath: real.path) { return root }
        guard real.lastPathComponent == "mise",
              let result = try? Execx.run(dir: cwd.isEmpty ? "/" : cwd, timeout: 5,
                                         name: real.path, args: ["which", "pi"]), result.ok else { return nil }
        let installed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard installed.hasPrefix("/"), !installed.contains("\n"),
              FileManager.default.isExecutableFile(atPath: installed) else { return nil }
        return packageRoot(realPath: URL(fileURLWithPath: installed).resolvingSymlinksInPath().path)
    }

    /// The ESM helper. Resolves entries from the real installation (never a
    /// global module guess) and prints one JSON line to stdout.
    static let script = """
    import { createRequire } from "node:module";
    import { pathToFileURL } from "node:url";
    import { existsSync } from "node:fs";
    const pkgRoot = process.argv[2];
    const req = createRequire(pkgRoot + "/package.json");
    const mainUrl = pathToFileURL(req.resolve(".")).href;
    let compatUrl = null;
    for (const cand of [
      pkgRoot + "/node_modules/@earendil-works/pi-ai/dist/compat.js",
      pkgRoot + "/../../node_modules/@earendil-works/pi-ai/dist/compat.js",
    ]) { if (existsSync(cand)) { compatUrl = pathToFileURL(cand).href; break; } }
    if (!compatUrl) throw new Error("pi-ai compat not found near " + pkgRoot);
    const { getAgentDir, ModelRuntime, SettingsManager, resolveModelScopeWithDiagnostics } = await import(mainUrl);
    const { getSupportedThinkingLevels, clampThinkingLevel } = await import(compatUrl);
    const { DEFAULT_THINKING_LEVEL } = await import(pathToFileURL(pkgRoot + "/dist/core/defaults.js").href);
    const { findInitialModel } = await import(pathToFileURL(pkgRoot + "/dist/core/model-resolver.js").href);
    const agentDir = getAgentDir();
    const cwd = process.cwd();
    const settings = await SettingsManager.create(cwd, agentDir, { projectTrusted: false });
    const runtime = await ModelRuntime.create({ allowModelNetwork: false, signal: AbortSignal.timeout(15000) });
    const available = await runtime.getAvailable(undefined, { signal: AbortSignal.timeout(15000) });
    const patterns = settings.getEnabledModels();
    const result = patterns?.length
      ? await resolveModelScopeWithDiagnostics(patterns, runtime, { signal: AbortSignal.timeout(15000) })
      : { scopedModels: available.map(m => ({ model: m })), diagnostics: [] };
    // Match the CLI's fresh-session selection: a saved model in scope wins;
    // otherwise Pi selects from the scope. Without a scope, use its resolver.
    const scoped = patterns?.length ? result.scopedModels : [];
    const saved = scoped.find(e => e.model.provider === settings.getDefaultProvider()
      && e.model.id === settings.getDefaultModel());
    const initial = await findInitialModel({
      scopedModels: saved ? [saved] : scoped,
      isContinuing: false,
      defaultProvider: settings.getDefaultProvider(),
      defaultModelId: settings.getDefaultModel(),
      defaultThinkingLevel: settings.getDefaultThinkingLevel(),
      modelThinkingLevels: settings.getAllModelThinkingLevels(),
      modelRuntime: runtime,
    });
    const models = result.scopedModels.map((e) => {
      const m = e.model ?? e;
      let id; try { id = m.id ?? m.modelId ?? m.model ?? String(m); } catch { id = String(m); }
      let provider; try { provider = m.provider ?? ""; } catch { provider = ""; }
      let label; try { label = m.displayName ?? m.name ?? id; } catch { label = id; }
      let levels = []; try { levels = getSupportedThinkingLevels(m); } catch {}
      const thinking = e.thinkingLevel
        ?? settings.getModelThinkingLevel(provider, id)
        ?? settings.getDefaultThinkingLevel()
        ?? DEFAULT_THINKING_LEVEL;
      return { id, provider, label, reasoning: Array.isArray(levels) ? levels : [],
        defaultReasoning: clampThinkingLevel(m, thinking),
        isDefault: initial.model?.id === id && initial.model?.provider === provider };
    });
    process.stdout.write(JSON.stringify({ models, warnings: (result.diagnostics ?? []).map(d => String(d?.message ?? d)).slice(0, 5) }));
    """

    static func scriptPath() -> String {
        let dir = RaptorPaths.home() + "/Library/Caches/raptor"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/pi-models.mjs"
    }

    public static func discover(piPath: String, cwd: String = "") -> AgentCatalog {
        guard let node = locateNode() else {
            return AgentCatalog(agent: "pi", models: [], warning: "node not found on PATH; node is required to enumerate Pi models")
        }
        guard let pkgRoot = packageRoot(piPath: piPath, cwd: cwd) else {
            return AgentCatalog(agent: "pi", models: [], warning: "could not locate the installed Pi package from " + piPath)
        }
        let scriptPath = scriptPath()
        do {
            try Data(Self.script.utf8).write(to: URL(fileURLWithPath: scriptPath), options: .atomic)
        } catch {
            return AgentCatalog(agent: "pi", models: [], warning: "could not write Pi discovery helper: \(error)")
        }
        let result: ExecResult
        do {
            result = try Execx.run(dir: cwd.isEmpty ? "/" : cwd, timeout: 30, name: node, args: [scriptPath, pkgRoot])
        } catch let error as ExecxError {
            let stderr = error.result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentCatalog(agent: "pi", models: [], warning: "Pi model discovery failed: " + lastLine(stderr.isEmpty ? error.message : stderr))
        } catch {
            return AgentCatalog(agent: "pi", models: [], warning: "Pi model discovery failed: \(error)")
        }
        guard result.ok, let parsed = parseOutput(result.stdout) else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentCatalog(agent: "pi", models: [], warning: "Pi model discovery failed: " + lastLine(stderr.isEmpty ? result.stdout : stderr))
        }
        var warning = ""
        if let first = parsed.warnings.first { warning = "Pi scope: " + first }
        return AgentCatalog(agent: "pi", models: parsed.models, warning: warning)
    }

    /// Pure for tests: parses the helper's JSON document.
    public static func parseOutput(_ stdout: String) -> (models: [AgentModel], warnings: [String])? {
        guard let data = stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["models"] as? [[String: Any]] else { return nil }
        let models: [AgentModel] = rows.map { row in
            var model = AgentModel(id: row["id"] as? String ?? "")
            if let provider = row["provider"] as? String { model.provider = provider }
            if let label = row["label"] as? String { model.label = label }
            if let reasoning = row["reasoning"] as? [String] { model.reasoning = reasoning }
            if let reasoning = row["defaultReasoning"] as? String { model.defaultReasoning = reasoning }
            if let isDefault = row["isDefault"] as? Bool { model.isDefault = isDefault }
            return model
        }
        let warnings = (obj["warnings"] as? [String] ?? []).filter { !$0.isEmpty }
        return (models, warnings)
    }

    /// Diagnostics keep only the final line; subprocess chatter is noise.
    static func lastLine(_ text: String) -> String {
        let line = text.split(separator: "\n").last.map(String.init) ?? text
        return String(line.prefix(300))
    }
}
