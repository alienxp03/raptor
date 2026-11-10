import Foundation
import RaptorWorktree

/// Fallback for filesystems without creation time is unnecessary on macOS:
/// the darwin identity uses birthtime directly (clone_identity_darwin.go).
func cloneIdentity(_ path: String) throws -> String {
    var st = stat()
    guard lstat(path, &st) == 0 else {
        throw MessageError("lstat \(path): \(errnoText(errno))")
    }
    return "\(st.st_dev):\(st.st_ino):\(st.st_birthtimespec.tv_sec):\(st.st_birthtimespec.tv_nsec)"
}

func instance(_ path: String) throws -> String {
    let root = try WorktreeKit.gitOut(dir: path, args: ["rev-parse", "--show-toplevel"])
    guard let resolved = try? canonical(root), resolved == path else {
        throw MessageError("not a worktree root: \(path)")
    }
    var registered = false
    for tree in WorktreeKit.list(repo: path) {
        if let p = try? canonical(tree.path), p == path {
            registered = true
            break
        }
    }
    if !registered {
        throw MessageError("worktree is not registered: \(path)")
    }
    var gitfile = pathJoin([path, ".git"])
    var st = stat()
    guard lstat(gitfile, &st) == 0 else {
        throw MessageError("lstat \(gitfile): \(errnoText(errno))")
    }
    if (st.st_mode & S_IFMT) == S_IFDIR {
        gitfile = pathJoin([gitfile, "HEAD"])
    }
    return try cloneIdentity(gitfile)
}

func validState(_ path: String, _ s: SetupState) -> Bool {
    if s.path != path || (s.instance ?? "").isEmpty {
        return false
    }
    guard let id = try? instance(path), id == s.instance else {
        return false
    }
    guard let branch = try? command(path, "git", ["symbolic-ref", "--short", "HEAD"]) else {
        return false
    }
    return branch == s.branch
}
