import Foundation

extension LaunchOptions {
    /// Parse picker context only. A URL cannot select or execute an action.
    init(pickerURL: URL) throws {
        let maximumBytes = 16 * 1024
        guard pickerURL.absoluteString.utf8.count <= maximumBytes,
              let components = URLComponents(url: pickerURL, resolvingAgainstBaseURL: false),
              components.scheme == "raptor", components.host == "picker",
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/" else {
            throw APIError.message("Invalid picker URL.")
        }

        let keys = ["mode", "session", "block", "client", "repo"]
        var values: [String: String] = [:]
        var contextBytes = 0
        for item in components.queryItems ?? [] {
            guard keys.contains(item.name), values[item.name] == nil,
                  let value = item.value, !value.isEmpty else {
                throw APIError.message("Invalid, duplicate or empty picker query item.")
            }
            contextBytes += item.name.utf8.count + value.utf8.count
            guard contextBytes <= maximumBytes else {
                throw APIError.message("Picker context exceeds 16 KiB.")
            }
            // queryItems already decoded this value. Keep literal percent strings intact.
            values[item.name] = value
        }
        guard values["mode"] != nil, values["session"] != nil, values["client"] != nil else {
            throw APIError.message("Picker URL requires mode, session and client.")
        }
        var arguments: [String] = []
        for key in keys {
            if let value = values[key] { arguments += ["--" + key, value] }
        }
        try self.init(arguments: arguments)
    }
}
