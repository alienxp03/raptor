import Foundation
import RaptorCatalog
import RaptorConfig
import RaptorRex
import RaptorWorktree

public extension RaptorTask {
    /// Select a visible progress terminal before running Worktrunk or inspecting
    /// hooks. The bootstrap opens Pi in this same session, then its progress tab
    /// exits. Failures keep a login shell and the diagnostic output available.
    static func launch(ctx: Ctx, cfg: RaptorConfig, explicitRepo: String, resumePath: String,
                       executable: String) throws -> TaskResult {
        guard !ctx.session.isEmpty else { throw MessageError("no session context") }
        guard !ctx.client.isEmpty else { throw MessageError("no app client context; target the Rex app with -C") }
        guard lookPath("pi") != nil else {
            throw MessageError("pi executable not found; install Pi on this host before creating a task")
        }
        let repo = try Catalog.resolveRepo(ctx, explicitRepo)
        guard !repo.isEmpty else { throw MessageError("current pane is not in a Git repository") }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var bootstrap = [executable, "-client", ctx.client, "task", "--finish-in-session", "--repo", repo]
        if !resumePath.isEmpty { bootstrap += ["--resume", resumePath] }
        let wrapper = "printf 'Creating worktree and starting Pi…\\n'; "
            + bootstrap.map(quote).joined(separator: " ")
            + "; status=$?; if [ \"$status\" -ne 0 ]; then "
            + "printf '\\nAgent setup failed. Worktree resources, if created, were preserved.\\n'; "
            + "rex session rename \"$REX_SESSION\" 'Agent setup failed'; exec \"${SHELL:-/bin/sh}\" -l; fi"
        let output = try taskRexRun(["new", "Starting agent…", "-c", repo, "--json", "--", "/bin/sh", "-c", wrapper])
        guard let opened = Rex.decodeJSON(OpenedSessionResponse.self, from: Data(output.utf8)),
              let session = opened.sessionID, !session.isEmpty else {
            throw MessageError("agent session creation response was invalid; inspect Rex before retrying")
        }
        let result = TaskResult(sessionID: session, windowID: opened.initialWindows?.first?.windowID,
                                blockID: opened.initialWindows?.first?.blockIDs?.first)
        Rex.recordLauncherCreation("", session, "Starting agent…", repo)
        do {
            try Rex.doAction(client: ctx.client, action: "session.select", kv: ["session_id=" + session])
        } catch {
            throw StartError(result: result, cause: MessageError("Agent session \(session) was created, but switching failed: \(error); select that session instead of creating another task"))
        }
        return result
    }
}
