import Foundation
import RaptorPaths
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Shared, atomic persistence for Raptor's session pins and recency history.
public enum RaptorStateStore {
    public static let sessionPinsKey = "session_pins"
    public static let sessionRecencyKey = "session_recency"
    public static let lockTimeout: TimeInterval = 0.25
    public static let lockRetry: TimeInterval = 0.001
    private static let processLock = NSLock()

    private enum StoreError: Error {
        case invalidDocument
        case unsupportedVersion(Int)
    }

    private struct Migration {
        var document: [String: Any]
        var legacyPaths: [String]
    }

    public static func statePath() -> String {
        #if os(macOS)
        return RaptorPaths.home() + "/Library/Application Support/raptor/state.json"
        #else
        let root = RaptorPaths.env("XDG_STATE_HOME") ?? (RaptorPaths.home() + "/.local/state")
        return root + "/raptor/state.json"
        #endif
    }

    /// Read without creating a file unless legacy files need migration.
    public static func read() throws -> [String: Any] {
        let path = statePath()
        if FileManager.default.fileExists(atPath: path) {
            return try decodeState(Data(contentsOf: URL(fileURLWithPath: path)))
        }
        guard legacyFilePaths().contains(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return emptyDocument()
        }
        return try withLock(at: path) {
            if FileManager.default.fileExists(atPath: path) {
                return try decodeState(Data(contentsOf: URL(fileURLWithPath: path)))
            }
            let migration = try importLegacyFiles()
            guard !migration.legacyPaths.isEmpty else { return migration.document }
            try save(migration.document, to: path)
            removeLegacyFiles(migration.legacyPaths)
            return migration.document
        }
    }

    /// Mutate the full document under one process-shared lock so independent pin
    /// and recency writers cannot overwrite each other's fields.
    @discardableResult
    public static func update<T>(_ body: (inout [String: Any], Data, String) throws -> T) throws -> T {
        let path = statePath()
        return try withLock(at: path) {
            var legacyPaths: [String] = []
            var document: [String: Any]
            var original: Data
            if FileManager.default.fileExists(atPath: path) {
                original = try Data(contentsOf: URL(fileURLWithPath: path))
                do {
                    document = try decodeState(original)
                } catch StoreError.invalidDocument {
                    try backup(original, beside: path, suffix: "corrupt")
                    let migration = try importLegacyFiles()
                    document = migration.document
                    legacyPaths = migration.legacyPaths
                    original = try encode(document)
                }
            } else {
                let migration = try importLegacyFiles()
                document = migration.document
                legacyPaths = migration.legacyPaths
                original = try encode(document)
            }
            let result = try body(&document, original, path)
            try save(document, to: path)
            removeLegacyFiles(legacyPaths)
            return result
        }
    }

    /// Preserve a damaged source before a caller repairs one section of the state.
    @discardableResult
    public static func backup(_ data: Data, beside path: String? = nil, suffix: String = "backup") throws -> String {
        let source = path ?? statePath()
        let backupPath = source + ".\(suffix)-\(UUID().uuidString)"
        try writeNewFile(data, at: backupPath)
        return backupPath
    }

    private static func emptyDocument() -> [String: Any] {
        [
            "version": 1,
            sessionPinsKey: [Any](),
            sessionRecencyKey: ["version": 1, "visits": [Any]()],
        ]
    }

    private static func decodeState(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              var document = object as? [String: Any] else {
            throw StoreError.invalidDocument
        }
        guard let version = document["version"] as? Int else { throw StoreError.invalidDocument }
        guard version == 1 else { throw StoreError.unsupportedVersion(version) }
        if document[sessionPinsKey] == nil { document[sessionPinsKey] = [Any]() }
        if document[sessionRecencyKey] == nil {
            document[sessionRecencyKey] = ["version": 1, "visits": [Any]()]
        }
        return document
    }

    private static func legacyFilePaths() -> [String] {
        let home = RaptorPaths.home()
        let cacheRoot = RaptorPaths.env("XDG_CACHE_HOME") ?? (home + "/Library/Caches")
        return [home + "/.config/raptor/session-pins.json", cacheRoot + "/raptor/session-recency.json"]
    }

    private static func importLegacyFiles() throws -> Migration {
        var document = emptyDocument()
        var paths: [String] = []
        let legacy = legacyFilePaths()
        for (path, key, wantsArray) in [(legacy[0], sessionPinsKey, true), (legacy[1], sessionRecencyKey, false)] {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let value = try? JSONSerialization.jsonObject(with: data),
                  (wantsArray ? value is [Any] : value is [String: Any]) else {
                try backup(data, beside: path, suffix: "corrupt")
                paths.append(path)
                continue
            }
            document[key] = value
            paths.append(path)
        }
        return Migration(document: document, legacyPaths: paths)
    }

    private static func withLock<T>(at path: String, _ body: () throws -> T) throws -> T {
        // flock semantics differ across Unix variants for threads in one process;
        // serialize locally as well as using the lock file for cross-process writers.
        try lockProcess()
        defer { processLock.unlock() }
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        let fd = open(path + ".lock", O_CREAT | O_RDWR, mode_t(0o600))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM) }
        defer { close(fd) }
        _ = fchmod(fd, mode_t(0o600))
        try lock(fd)
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    private static func lockProcess() throws {
        let deadline = Date().addingTimeInterval(lockTimeout)
        while !processLock.try() {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw POSIXError(.EWOULDBLOCK) }
            usleep(useconds_t(min(lockRetry, remaining) * 1_000_000))
        }
    }

    private static func lock(_ fd: Int32) throws {
        let deadline = Date().addingTimeInterval(lockTimeout)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return }
            let code = errno
            if code != EWOULDBLOCK && code != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EPERM)
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw POSIXError(.EWOULDBLOCK) }
            usleep(useconds_t(min(lockRetry, remaining) * 1_000_000))
        }
    }

    private static func encode(_ document: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }

    private static func save(_ document: [String: Any], to path: String) throws {
        try atomicWrite(encode(document), to: path)
    }

    private static func writeNewFile(_ data: Data, at path: String) throws {
        try atomicWrite(data, to: path)
    }

    private static func atomicWrite(_ data: Data, to path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = path + ".tmp-\(UUID().uuidString)"
        let fd = open(temporary, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM) }
        defer {
            _ = close(fd)
            _ = unlink(temporary)
        }
        let bytes = [UInt8](data)
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBufferPointer { buffer in
                DarwinOrGlibcWrite(fd, buffer.baseAddress! + written, bytes.count - written)
            }
            if count <= 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            written += count
        }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard rename(temporary, path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func removeLegacyFiles(_ paths: [String]) {
        for path in paths { try? FileManager.default.removeItem(atPath: path) }
    }
}

#if canImport(Darwin)
private func DarwinOrGlibcWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int { Darwin.write(fd, buffer, count) }
#else
private func DarwinOrGlibcWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int { Glibc.write(fd, buffer, count) }
#endif
