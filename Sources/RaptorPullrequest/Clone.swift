import Foundation
import RaptorWorktree

// Ownership is outside the clone: gh requires an empty destination. Never clean
// a failed clone. A valid nonempty clone is discovered and validated by Resolve.
func claimClone(_ path: String) throws {
    let key = "clone:" + prospectivePath(path)
    let owner = try load(key)
    var st = stat()
    if lstat(path, &st) != 0 {
        guard errno == ENOENT else {
            throw MessageError("lstat \(path): \(errnoText(errno))")
        }
        try FileManager.default.createDirectory(atPath: dirOf(path), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let id = try cloneIdentity(path)
        try save(key, SetupState(instance: id, path: path))
        return
    }
    let id = try cloneIdentity(path)
    let isDir = (st.st_mode & S_IFMT) == S_IFDIR
    if !isDir || owner.path != path || owner.instance != id {
        throw MessageError("clone destination is occupied and ownership is not verified: \(path)")
    }
    let entries = try FileManager.default.contentsOfDirectory(atPath: path)
    if !entries.isEmpty {
        throw MessageError("partial clone contains data; inspect before retry: \(path)")
    }
}
