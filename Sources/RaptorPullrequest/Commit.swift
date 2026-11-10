import Foundation
import RaptorRex
import RaptorWorktree

/// ^[0-9a-f]{40}$
func matchesCommitOID(_ s: String) -> Bool {
    let chars = Array(s.unicodeScalars)
    if chars.count != 40 { return false }
    for c in chars {
        let v = c.value
        if !(v >= 48 && v <= 57) && !(v >= 97 && v <= 102) { return false } // 0-9 a-f
    }
    return true
}

// MARK: - head metadata

/// headRef is nullable only when the PR's actual source ref no longer exists.
/// Do not treat HTTP failures (including 404s) as evidence of deletion.
func resolveHead(_ info: inout Info, _ id: String) throws {
    let parts = id.components(separatedBy: "/")
    let raw: String
    do {
        raw = try command("", "gh", ["api", "--hostname", "github.com", "graphql",
            "-f", "query=query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){state headRefOid headRef{name}}}}",
            "-f", "owner=" + parts[0], "-f", "repo=" + parts[1], "-F", "number=\(info.number)"])
    } catch {
        throw MessageError("verify PR head branch: \(error)")
    }
    guard let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
        throw MessageError("parse PR head metadata: invalid JSON")
    }
    let repository = (obj["data"] as? [String: Any])?["repository"] as? [String: Any]
    let pr = repository?["pullRequest"] as? [String: Any] ?? [:]
    let prState = pr["state"] as? String ?? ""
    let prOID = pr["headRefOid"] as? String ?? ""
    let hasErrors: Bool
    if let errs = obj["errors"], !(errs is NSNull) {
        if let arr = errs as? [Any] {
            hasErrors = !arr.isEmpty
        } else {
            hasErrors = true
        }
    } else {
        hasErrors = false
    }
    let headRefPresent = pr["headRef"] != nil
    let headRef: Any? = pr["headRef"]
    if hasErrors
        || (prState != "OPEN" && prState != "CLOSED" && prState != "MERGED")
        || prState != info.state
        || !matchesCommitOID(prOID)
        || prOID != info.headOID
        || !headRefPresent {
        throw MessageError("PR head metadata is incomplete or changed; resolve again")
    }
    info.headDeleted = headRef is NSNull
    if !info.headDeleted {
        let name = (headRef as? [String: Any])?["name"] as? String ?? ""
        if name != info.branch {
            throw MessageError("PR head branch metadata is invalid or changed; resolve again")
        }
    }
}

// MARK: - retained commit checkout

/// Called only after the preparation journal is durable. Never update the PR's
/// original branch or FETCH_HEAD. Private fetch refs are unique and short-lived.
func prepareCommit(_ info: Info) throws {
    var nonce = [UInt8](repeating: 0, count: 16)
    var rng = SystemRandomNumberGenerator()
    for i in 0..<16 {
        nonce[i] = UInt8.random(in: 0...255, using: &rng)
    }
    let ref = "refs/raptor/pr-checkout/" + nonce.map { String(format: "%02x", $0) }.joined()
    var resultErr: (any Error)?
    do {
        resultErr = try prepareCommitBody(info, ref: ref)
    } catch {
        resultErr = error
    }
    // Deferred cleanup, joined into the result like Go's errors.Join.
    do {
        _ = try command(info.repo, "git", ["update-ref", "-d", ref])
    } catch {
        resultErr = joinErrors(resultErr, error)
    }
    if let resultErr {
        throw resultErr
    }
}

private func prepareCommitBody(_ info: Info, ref: String) throws -> (any Error)? {
    do {
        let (id, _) = (try? parse(info.url, "")) ?? ("", "")
        // Use the same GitHub account as metadata resolution. SSH-only clones may
        // have no HTTPS Git credentials; do not prompt or change global Git config.
        _ = try command(info.repo, "env", [
            "GIT_TERMINAL_PROMPT=0", "git", "-c", "credential.helper=",
            "-c", "credential.helper=!gh auth git-credential", "fetch", "--no-tags", "--no-write-fetch-head",
            "https://github.com/" + id + ".git", "refs/pull/\(info.number)/head:" + ref,
        ])
        var oid = ""
        var oidErr: (any Error)?
        var kind = ""
        var typeErr: (any Error)?
        do { oid = try command(info.repo, "git", ["rev-parse", "--verify", ref]) } catch { oidErr = error }
        do { kind = try command(info.repo, "git", ["cat-file", "-t", ref]) } catch { typeErr = error }
        if oidErr != nil || typeErr != nil || kind != "commit" || oid != info.headOID {
            throw MessageError("retained PR head does not match source head OID \(info.headOID); no checkout performed")
        }
        let branchRef = "refs/heads/" + info.branch
        // Compare-and-create: a concurrent or pre-existing branch must never be overwritten.
        do {
            _ = try command(info.repo, "git", ["update-ref", "--no-deref", branchRef, oid, String(repeating: "0", count: 40)])
        } catch {
            var existing = ""
            var readErr: (any Error)?
            do {
                existing = try command(info.repo, "git", ["rev-parse", "--verify", branchRef])
            } catch {
                readErr = error
            }
            var symbolicErr: (any Error)?
            do {
                _ = try command(info.repo, "git", ["symbolic-ref", "-q", branchRef])
            } catch {
                symbolicErr = error
            }
            if readErr != nil || symbolicErr == nil || existing != oid {
                throw MessageError("branch \(info.branch) already exists at a different commit or cannot be created; preserved: \(error)")
            }
        }
        return nil
    } catch {
        return error
    }
}
