import Foundation
import CryptoKit
import RaptorPaths
import RaptorWorktree

/// Durable setup journal. Ported from state.go. JSON keys stay byte-identical
/// to the Go original; omitempty fields are optional Strings/Bools.
struct SetupState: Codable, Equatable {
    var instance: String?
    var config: String
    var path: String
    var source: String
    var branch: String
    var base: String
    var basePath: String?
    var url: String
    var new: Bool
    var stage: Int
    var complete: Bool
    var failed: String?
    var released: Bool
    var opening: Bool
    var retryCreate: Bool?
    var target: String?
    var result: OpenResult

    init(instance: String? = nil, config: String = "", path: String = "", source: String = "",
         branch: String = "", base: String = "", basePath: String? = nil, url: String = "",
         new: Bool = false, stage: Int = 0, complete: Bool = false, failed: String? = nil,
         released: Bool = false, opening: Bool = false, retryCreate: Bool? = nil,
         target: String? = nil, result: OpenResult = OpenResult()) {
        self.instance = instance
        self.config = config
        self.path = path
        self.source = source
        self.branch = branch
        self.base = base
        self.basePath = basePath
        self.url = url
        self.new = new
        self.stage = stage
        self.complete = complete
        self.failed = failed
        self.released = released
        self.opening = opening
        self.retryCreate = retryCreate
        self.target = target
        self.result = result
    }

    enum CodingKeys: String, CodingKey {
        case instance, config, path, source, branch, base
        case basePath = "base_path"
        case url, new, stage, complete, failed, released, opening
        case retryCreate = "retry_create"
        case target, result
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instance = try c.decodeIfPresent(String.self, forKey: .instance)
        config = try c.decodeIfPresent(String.self, forKey: .config) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        base = try c.decodeIfPresent(String.self, forKey: .base) ?? ""
        basePath = try c.decodeIfPresent(String.self, forKey: .basePath)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        new = try c.decodeIfPresent(Bool.self, forKey: .new) ?? false
        stage = try c.decodeIfPresent(Int.self, forKey: .stage) ?? 0
        complete = try c.decodeIfPresent(Bool.self, forKey: .complete) ?? false
        failed = try c.decodeIfPresent(String.self, forKey: .failed)
        released = try c.decodeIfPresent(Bool.self, forKey: .released) ?? false
        opening = try c.decodeIfPresent(Bool.self, forKey: .opening) ?? false
        retryCreate = try c.decodeIfPresent(Bool.self, forKey: .retryCreate)
        target = try c.decodeIfPresent(String.self, forKey: .target)
        result = try c.decodeIfPresent(OpenResult.self, forKey: .result) ?? OpenResult()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Go's omitempty: empty strings, false bools, and nils are omitted.
        if let instance, !instance.isEmpty { try c.encode(instance, forKey: .instance) }
        try c.encode(config, forKey: .config)
        try c.encode(path, forKey: .path)
        try c.encode(source, forKey: .source)
        try c.encode(branch, forKey: .branch)
        try c.encode(base, forKey: .base)
        if let basePath, !basePath.isEmpty { try c.encode(basePath, forKey: .basePath) }
        try c.encode(url, forKey: .url)
        try c.encode(new, forKey: .new)
        try c.encode(stage, forKey: .stage)
        try c.encode(complete, forKey: .complete)
        if let failed, !failed.isEmpty { try c.encode(failed, forKey: .failed) }
        try c.encode(released, forKey: .released)
        try c.encode(opening, forKey: .opening)
        if let retryCreate, retryCreate { try c.encode(retryCreate, forKey: .retryCreate) }
        if let target, !target.isEmpty { try c.encode(target, forKey: .target) }
        try c.encode(result, forKey: .result)
    }
}

func stateFile(_ key: String, _ suffix: String) throws -> String {
    var root = RaptorPaths.env("XDG_STATE_HOME") ?? ""
    if root.isEmpty {
        root = userHome() + "/.local/state"
    }
    root = root + "/raptor/pullrequest"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    // Normalize existing ancestors too, so a prospective path keeps its identity
    // after creation beneath a symlink (for example /tmp on macOS).
    var k = key
    if let p = absPath(k) {
        k = prospectivePath(p)
    }
    let hex = sha256Hex(Data(k.utf8))
    return pathJoin([root, hex + suffix])
}

func prospectivePath(_ path: String) -> String {
    if let p = try? canonical(path) {
        return p
    }
    let parent = dirOf(path)
    if parent == path {
        return path
    }
    return pathJoin([prospectivePath(parent), baseOf(path)])
}

/// flock-based nonblocking-by-default lock; the returned closure releases it.
func lock(_ key: String, _ wait: Bool) throws -> () -> Void {
    let path = try stateFile(key, ".lock")
    let fd = open(path, O_CREAT | O_RDWR, mode_t(0o600))
    if fd < 0 {
        throw MessageError("open \(path): \(errnoText(errno))")
    }
    var flags: Int32 = LOCK_EX
    if !wait { flags |= LOCK_NB }
    if flock(fd, flags) != 0 {
        let text = errnoText(errno)
        close(fd)
        throw MessageError("operation already running: \(text)")
    }
    return {
        _ = flock(fd, LOCK_UN)
        close(fd)
    }
}

func load(_ path: String) throws -> SetupState {
    let name = try stateFile(path, ".json")
    guard let data = FileManager.default.contents(atPath: name) else {
        if !FileManager.default.fileExists(atPath: name) {
            return SetupState()
        }
        throw MessageError("read state \(name): \(errnoText(errno))")
    }
    do {
        return try JSONDecoder().decode(SetupState.self, from: data)
    } catch {
        throw MessageError("decode state \(name): \(error)")
    }
}

func save(_ path: String, _ state: SetupState) throws {
    let name = try stateFile(path, ".json")
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted]
    let data = try enc.encode(state)
    var tmpl = dirOf(name) + "/.state-XXXXXX"
    var cpath = Array(tmpl.utf8CString)
    let fd = mkstemp(&cpath)
    if fd < 0 {
        throw MessageError("mkstemp \(dirOf(name)): \(errnoText(errno))")
    }
    tmpl = String(cString: cpath)
    defer { try? FileManager.default.removeItem(atPath: tmpl) }
    var writeErr: (any Error)?
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        var written = 0
        while written < data.count {
            let n = write(fd, raw.baseAddress!.advanced(by: written), data.count - written)
            if n <= 0 {
                writeErr = MessageError("write state: \(errnoText(errno))")
                return
            }
            written += n
        }
    }
    if fcntl(fd, F_FULLFSYNC) != 0 { _ = fsync(fd) }
    var closeErr: Int32 = 0
    closeErr = close(fd)
    if let writeErr { throw writeErr }
    if closeErr != 0 {
        throw MessageError("close state: \(errnoText(errno))")
    }
    if rename(tmpl, name) != 0 {
        throw MessageError("rename state: \(errnoText(errno))")
    }
    // Persist the rename as well as the bytes (ownership and pre-mutation
    // journals must survive a crash before a subsequent command starts).
    let dfd = open(dirOf(name), O_RDONLY)
    if dfd >= 0 {
        if fcntl(dfd, F_FULLFSYNC) != 0 { _ = fsync(dfd) }
        close(dfd)
    }
}
