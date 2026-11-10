import Foundation

/// Ported from internal/theme: resolves the active Rex theme from the Rex
/// app bundle and its macOS preferences. Both interfaces (terminal picker
/// and native app) consume the resolved palette; on any failure callers
/// keep their built-in colors.
public enum RaptorTheme {
    /// Rex preference domain for `defaults` lookups.
    static let prefDomain = "com.superlogical.rex"
    /// Theme catalog path inside the Rex app bundle.
    static let tokensRelPath = "Contents/Resources/SuperUI_SuperDesignTokens.bundle/Contents/Resources/themes.json"

    /// Options make resolution testable. Zero fields use the real machine
    /// state.
    public struct Options {
        /// Overrides Rex application discovery (directory containing
        /// Contents/Resources).
        public var rexApp: String
        /// Replaces `defaults export com.superlogical.rex -`.
        public var defaultsOutput: (() throws -> Data)?
        /// Replaces the global appearance probe.
        public var systemIsDark: (() -> Bool)?

        public init(
            rexApp: String = "",
            defaultsOutput: (() throws -> Data)? = nil,
            systemIsDark: (() -> Bool)? = nil
        ) {
            self.rexApp = rexApp
            self.defaultsOutput = defaultsOutput
            self.systemIsDark = systemIsDark
        }
    }

    /// Returns the active Rex theme, or throws ThemeError.unavailable. Each
    /// call reads current preferences, system appearance, and the selected
    /// theme catalog so resident callers see theme changes.
    public static func resolve(_ options: Options = Options()) throws -> Theme {
        do {
            return try resolveUnchecked(options)
        } catch let error as ThemeError {
            throw error
        } catch {
            // Like Go's fmt.Errorf("%w: %v", ErrUnavailable, err) around
            // readPrefs and the file reads.
            throw ThemeError.unavailable(String(describing: error))
        }
    }

    /// api `theme` payload: the resolved palette for the native picker, or
    /// an error message when resolution is disabled or fails.
    public static func themePayload() -> ThemePayload {
        if let raw = getenv("RAPTOR_THEME"), String(cString: raw) == "ansi" {
            return .error("disabled by RAPTOR_THEME=ansi")
        }
        do {
            return .theme(try resolve(Options()))
        } catch let error as ThemeError {
            return .error(error.description)
        } catch {
            return .error(String(describing: error))
        }
    }

    /// api `theme` payload encoded as JSON bytes for the native app.
    public static func themeJSONData() -> Data {
        themePayload().jsonData()
    }

    // MARK: - Resolution

    private static func resolveUnchecked(_ options: Options) throws -> Theme {
        let prefs = try readPrefs(options)
        var appearance = prefs["Workspace.appearance"] as? String ?? ""
        if appearance.isEmpty { appearance = "system" }
        var style = prefs["Workspace.interfaceStyle"] as? String ?? ""
        if style.isEmpty { style = "modern" }
        if appearance != "system" && appearance != "light" && appearance != "dark" {
            throw ThemeError.unavailable("unsupported appearance \"" + appearance + "\"")
        }
        switch style {
        case "modern", "classic", "blendTheme", "useTheme":
            break
        default:
            throw ThemeError.unavailable("interface style \"" + style + "\"")
        }
        let dark = appearance == "dark" || (appearance == "system" && systemIsDark(options))
        let key = dark ? "Workspace.darkThemeID" : "Workspace.lightThemeID"
        let id = prefs[key] as? String ?? ""
        if id.isEmpty {
            throw ThemeError.unavailable("no " + key)
        }

        if var custom = parseCustomThemes(prefs["Workspace.customThemes"], id) {
            custom.interfaceStyle = style
            return custom
        }
        let entries = try builtinThemes(options)
        var theme = try builtinTheme(entries, id, dark)
        theme.interfaceStyle = style
        return theme
    }

    private static func systemIsDark(_ options: Options) -> Bool {
        if let probe = options.systemIsDark { return probe() }
        guard let out = try? runCommand("defaults", ["read", "-g", "AppleInterfaceStyle"]),
              let text = String(data: out, encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == "Dark"
    }

    private static func readPrefs(_ options: Options) throws -> [String: Any] {
        let data: Data
        if let defaultsOutput = options.defaultsOutput {
            data = try defaultsOutput()
        } else {
            data = try runCommand("defaults", ["export", prefDomain, "-"])
        }
        // `defaults export` writes an XML plist; PropertyListSerialization
        // handles the date and data values JSON conversion rejects.
        guard let prefs = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw CommandError(message: "preferences are not a property list dictionary")
        }
        return prefs
    }

    private static func builtinThemes(_ options: Options) throws -> [[String: Any]] {
        let path = tokensPath(options)
        guard let data = FileManager.default.contents(atPath: path) else {
            let reason = FileManager.default.fileExists(atPath: path) ? "permission denied" : "no such file or directory"
            throw ThemeError.unavailable("open " + path + ": " + reason)
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ThemeError.unavailable("theme catalog: " + (error as NSError).localizedDescription)
        }
        guard let entries = object as? [[String: Any]] else {
            throw ThemeError.unavailable("theme catalog: not a list of themes")
        }
        return entries
    }

    private static func tokensPath(_ options: Options) -> String {
        if !options.rexApp.isEmpty {
            return (options.rexApp as NSString).appendingPathComponent(tokensRelPath)
        }
        for app in rexAppCandidates() {
            let path = (app as NSString).appendingPathComponent(tokensRelPath)
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return ("/Applications/Rex.app" as NSString).appendingPathComponent(tokensRelPath)
    }

    private static func rexAppCandidates() -> [String] {
        var dirs: [String] = []
        if let raw = getenv("RAPTOR_REX_APP") {
            let env = String(cString: raw)
            if !env.isEmpty { dirs.append(env) }
        }
        var home = ""
        if let raw = getenv("HOME"), !String(cString: raw).isEmpty {
            home = String(cString: raw)
        }
        for base in ["/Applications", home + "/Applications"] {
            if base == "/" { continue }
            dirs.append(base + "/Rex.app")
            dirs.append(base + "/Rex Beta.app")
        }
        return dirs
    }

    /// Decodes Workspace.customThemes (a plist data blob holding a JSON
    /// document) and returns the theme with the given id, if any. Custom
    /// themes ship a terminal palette rather than UI tokens.
    private static func parseCustomThemes(_ value: Any?, _ id: String) -> Theme? {
        let blob: Data?
        if let data = value as? Data {
            blob = data
        } else if let string = value as? String {
            blob = string.data(using: .utf8)
        } else {
            blob = nil
        }
        guard let blob, let entries = (try? JSONSerialization.jsonObject(with: blob)) as? [[String: Any]] else {
            return nil
        }
        for entry in entries {
            guard (entry["id"] as? String) == id else { continue }
            guard let palette = entry["palette"] as? [String: Any] else { return nil }
            guard let ansi = hexList(palette["ansi"], 16), ansi.count >= 16 else { return nil }
            let background = hexString(palette["background"])
            let foreground = hexString(palette["foreground"])
            let selection = hexString(palette["selectionBackground"])
            if background.isEmpty || foreground.isEmpty || selection.isEmpty { return nil }
            let accent = hexString(palette["cursor"])
            var selectionForeground = hexString(palette["selectionForeground"])
            if selectionForeground.isEmpty { selectionForeground = background }
            let dark = isDarkHex(background)
            let surface = mixHex(background, foreground, 0.12)
            var name = entry["name"] as? String ?? ""
            if name.isEmpty { name = id }
            return Theme(
                name: name, isDark: dark, background: background,
                foreground: foreground, cursor: accent, selection: selection,
                selectionForeground: selectionForeground, surface: surface,
                accent: accent, ansi: ansi
            )
        }
        return nil
    }

    private static func builtinTheme(_ entries: [[String: Any]], _ id: String, _ dark: Bool) throws -> Theme {
        for entry in entries {
            guard (entry["id"] as? String) == id else { continue }
            let semantic = entry["semantic"] as? [String: Any]
            guard let source = entry["source"] as? [String: Any] else {
                throw ThemeError.unavailable("theme \"" + id + "\" has no palette")
            }
            var ansi: [String] = []
            ansiLoop: for i in 0..<16 {
                if let c = p3Color(semantic?["terminalAnsi" + String(i)]) {
                    ansi.append(c.hex())
                    continue
                }
                guard let fallback = hexList(source["ansi"], 16), fallback.count >= 16 else {
                    throw ThemeError.unavailable("theme \"" + id + "\" has no ANSI palette")
                }
                ansi = fallback
                break ansiLoop
            }

            func pick(_ semanticKey: String, _ sourceKey: String) throws -> String {
                if let c = p3Color(semantic?[semanticKey]) { return c.hex() }
                let hex = hexString(source[sourceKey])
                if !hex.isEmpty { return hex }
                throw ThemeError.unavailable("theme \"" + id + "\" has no " + semanticKey)
            }

            let background = try pick("terminalBackground", "background")
            let foreground = try pick("terminalForeground", "foreground")
            let cursor = try pick("terminalCursor", "cursor")
            let selection = try pick("terminalSelection", "selectionBackground")
            let selectionForeground = try pick("terminalSelectionForeground", "selectionForeground")

            var surface = ""
            if let c = p3Color(semantic?["surfaceRaised"]) {
                surface = c.hex()
            } else {
                surface = mixHex(background, foreground, 0.12)
            }
            var accent = cursor
            if let c = p3Color(semantic?["accentSolid"]) {
                accent = c.hex()
            }
            var name = entry["name"] as? String ?? ""
            if name.isEmpty { name = id }
            var theme = Theme(
                name: name, isDark: dark, background: background,
                foreground: foreground, cursor: cursor, selection: selection,
                selectionForeground: selectionForeground, surface: surface,
                accent: accent, ansi: ansi
            )
            // Older catalogs have terminal roles only. Do not invent UI selection.
            if let uiSelection = p3Color(semantic?["selection"]) {
                func uiColor(_ key: String, _ fallback: String) -> String {
                    if let color = p3Color(semantic?[key]) { return color.hex() }
                    return fallback
                }
                theme.ui = UIPalette(
                    background: uiColor("surfaceRaised", theme.surface),
                    foreground: uiColor("content", theme.foreground),
                    selection: uiSelection.hex(),
                    selectionForeground: uiColor("selectionForeground", theme.background),
                    surface: uiColor("controlOnOverlay", theme.surface)
                )
            }
            return theme
        }
        throw ThemeError.unavailable("theme \"" + id + "\" not found")
    }
}

/// Thrown for `defaults` launch failures and non-zero exits, with Go-style
/// exec error text.
struct CommandError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Resolves a bare command name against PATH like Go's exec.LookPath.
private func lookup(_ name: String) -> String? {
    if name.contains("/") {
        return FileManager.default.fileExists(atPath: name) ? name : nil
    }
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    for dir in path.split(separator: ":") {
        let candidate = dir + "/" + name
        if FileManager.default.isExecutableFile(atPath: String(candidate)) {
            return String(candidate)
        }
    }
    return nil
}

/// Runs `name` with `args` and returns stdout; launch failures and non-zero
/// exits throw, like Go's exec.Command(...).Output().
private func runCommand(_ name: String, _ args: [String]) throws -> Data {
    guard let executable = lookup(name) else {
        throw CommandError(message: name + ": no such file or directory")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        throw CommandError(message: name + ": " + (error as NSError).localizedDescription)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CommandError(message: "exit status \(process.terminationStatus)")
    }
    return data
}
