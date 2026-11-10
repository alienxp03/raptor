import Foundation
import RaptorCatalog
import RaptorPullrequest
import RaptorRex
import RaptorWorktree

struct PRParams {
    var repo: String
    var input: String
    var path: String
    var target: String
    var checkoutCommit: Bool
}

extension Handler {
    /// PR requests remain separate from New worktree: PR refs already name a branch.
    /// Partial mutation failures are result data so native clients retain recovery.
    func pullRequest(_ method: String, _ params: [UInt8]) -> (MethodResult?, Error?) {
        let obj: JSONValue
        do {
            var parser = JSONParser(params)
            obj = try parser.parseTop().value
        } catch {
            return (nil, error)
        }
        var p = PRParams(repo: "", input: "", path: "", target: "", checkoutCommit: false)
        do {
            p.repo = try Params.string(obj, "repo")
            p.input = try Params.string(obj, "input")
            p.path = try Params.string(obj, "path")
            p.target = try Params.string(obj, "target")
            p.checkoutCommit = try Params.bool(obj, "checkout_commit")
        } catch {
            return (nil, error)
        }
        let ctx = ctxSnapshot()
        if method == "pullrequests.open" {
            if p.path.isEmpty {
                return (nil, MessageError("worktree path is required"))
            }
            if p.target != "session" && p.target != "tab" {
                return (nil, MessageError("pull requests open in a session or tab"))
            }
            do {
                let result = try Pullrequest.open(path: p.path, target: p.target, ctx: Ctx(
                    session: ctx.session, block: ctx.block, client: ctx.client, title: ctx.title))
                return (openLauncherResult(result, nil), nil)
            } catch let error as OpenError {
                return (openLauncherResult(error.result, error), nil)
            } catch {
                return (openLauncherResult(OpenResult(path: p.path), error), nil)
            }
        }
        if p.input.trimmingCharacters(in: .whitespaces).isEmpty {
            return (nil, MessageError("enter a GitHub pull request URL or number"))
        }
        var repo = ""
        // A URL supplies its own repository. Do not turn the origin pane's cwd
        // into a conflicting mandatory context for a cross-repository URL.
        if !p.repo.isEmpty || !p.input.trimmingCharacters(in: .whitespaces).hasPrefix("https://github.com/") {
            do {
                repo = try Catalog.resolveRepo(Ctx(
                    session: ctx.session, block: ctx.block, client: ctx.client, title: ctx.title), p.repo)
            } catch {
                return (nil, error)
            }
        }
        if method == "pullrequests.resolve" {
            do {
                let info = try Pullrequest.resolveWithOptions(repo: repo, input: p.input, checkoutCommit: p.checkoutCommit)
                return (.info(info), nil)
            } catch let error as ResolveError {
                return (nil, error)
            } catch {
                return (nil, error)
            }
        }
        do {
            let result = try Pullrequest.prepareWithOptions(repo: repo, input: p.input, checkoutCommit: p.checkoutCommit)
            return (.info(result), nil)
        } catch let error as PrepareError {
            // A prospective path or an existing registration is not enough: Open
            // also needs Prepare's valid setup journal. Otherwise retry Prepare.
            if !Pullrequest.ready(path: error.info.path) {
                return (nil, error)
            }
            return (.preparePartial(error.info, error: error.causeDescription), nil)
        } catch {
            return (nil, error)
        }
    }
}

extension PrepareError {
    /// Go's err.Error() for the partial prepare payload.
    var causeDescription: String {
        String(describing: cause)
    }
}
