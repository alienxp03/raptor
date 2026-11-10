import Foundation
import RaptorRex
import RaptorWorktree

/// Namespace for the ported internal/pullrequest package: GitHub PR resolution,
/// durable clone/worktree preparation, and visible setup terminals.
public enum Pullrequest {}

/// Resolve/Prepare return partial metadata even on failure, like Go's
/// (Info, error) pair; the failed call's Info rides on these errors.
public struct ResolveError: Error, CustomStringConvertible {
    public let info: Info
    public let cause: any Error
    public var description: String { String(describing: cause) }
}

public struct PrepareError: Error, CustomStringConvertible {
    public let info: Info
    public let cause: any Error
    public var description: String { String(describing: cause) }
}

/// PR metadata and destination preview. `source` is internal bookkeeping, not
/// part of the JSON surface (matching Go's unexported field).
public struct Info: Codable, Equatable {
    var source: String
    public var input: String
    public var url: String
    public var number: Int
    public var title: String
    public var branch: String
    public var repo: String
    public var path: String
    public var cloneRequired: Bool
    public var existing: Bool
    public var state: String
    public var headDeleted: Bool
    public var headOID: String

    public init(source: String = "", input: String = "", url: String = "", number: Int = 0,
                title: String = "", branch: String = "", repo: String = "", path: String = "",
                cloneRequired: Bool = false, existing: Bool = false, state: String = "",
                headDeleted: Bool = false, headOID: String = "") {
        self.source = source
        self.input = input
        self.url = url
        self.number = number
        self.title = title
        self.branch = branch
        self.repo = repo
        self.path = path
        self.cloneRequired = cloneRequired
        self.existing = existing
        self.state = state
        self.headDeleted = headDeleted
        self.headOID = headOID
    }

    enum CodingKeys: String, CodingKey {
        case input, url, number, title, branch, repo, path
        case cloneRequired = "clone_required"
        case existing, state
        case headDeleted = "head_deleted"
        case headOID = "head_oid"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = ""
        input = try c.decodeIfPresent(String.self, forKey: .input) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        number = try c.decodeIfPresent(Int.self, forKey: .number) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        cloneRequired = try c.decodeIfPresent(Bool.self, forKey: .cloneRequired) ?? false
        existing = try c.decodeIfPresent(Bool.self, forKey: .existing) ?? false
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        headDeleted = try c.decodeIfPresent(Bool.self, forKey: .headDeleted) ?? false
        headOID = try c.decodeIfPresent(String.self, forKey: .headOID) ?? ""
    }
}

/// Rex destination IDs for an opened setup terminal. `path` is always encoded;
/// the other fields are omitempty, matching the Go JSON tags.
public struct OpenResult: Codable, Equatable {
    public var path: String
    public var sessionID: String?
    public var windowID: String?
    public var blockID: String?
    public var error: String?

    public init(path: String = "", sessionID: String? = nil, windowID: String? = nil,
                blockID: String? = nil, error: String? = nil) {
        self.path = path
        self.sessionID = sessionID
        self.windowID = windowID
        self.blockID = blockID
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case path
        case sessionID = "session_id"
        case windowID = "window_id"
        case blockID = "block_id"
        case error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        windowID = try c.decodeIfPresent(String.self, forKey: .windowID)
        blockID = try c.decodeIfPresent(String.self, forKey: .blockID)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        if let sessionID, !sessionID.isEmpty { try c.encode(sessionID, forKey: .sessionID) }
        if let windowID, !windowID.isEmpty { try c.encode(windowID, forKey: .windowID) }
        if let blockID, !blockID.isEmpty { try c.encode(blockID, forKey: .blockID) }
        if let error, !error.isEmpty { try c.encode(error, forKey: .error) }
    }
}

extension Pullrequest {
    /// Ready reports whether Open can use the registered worktree and its
    /// journal. A registration alone is not proof that Prepare reached a
    /// recoverable state.
    public static func ready(path: String) -> Bool {
        guard let p = try? canonical(path) else { return false }
        guard let unlock = try? lock(p, false) else { return false }
        defer { unlock() }
        guard let s = try? load(p) else { return false }
        return validState(p, s)
    }
}
