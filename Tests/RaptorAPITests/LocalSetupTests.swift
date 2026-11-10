import Foundation
import RaptorPullrequest
import RaptorRex
import RaptorWorktree
import XCTest
@testable import RaptorAPI

final class LocalSetupTests: APITestCase {
    func testCreateRegistersConfiguredLocalSetup() throws {
        let repo = try fixtureRepo(env)
        env.set("XDG_STATE_HOME", makeTempDir())
        let projectConfig = env.get("WORKTRUNK_PROJECT_CONFIG_PATH") ?? ""
        try put(projectConfig, "[pre-start]\ninstall = \"true\"\n", mode: 0o600)
        let call = makeClient(self, Handler(ctx: Ctx(), cfg: .default()))
        var createdPath = ""
        let err = call("worktrees.create", .object(["repo": .string(repo), "branch": .string("local-setup"), "base": .string("main")])) { result in
            createdPath = try jsonDict(result)["path"] as? String ?? ""
        }
        if !err.isEmpty {
            XCTFail(err)
            return
        }
        let pending = try Pullrequest.localPending(createdPath)
        if !pending {
            XCTFail("pending=false")
        }
        if !Pullrequest.ready(path: createdPath) {
            XCTFail("local state lacks worktree identity")
        }
        let dispatchErr = call("dispatch", .object(["target": .string("here"), "path": .string(createdPath)]), nil)
        if !dispatchErr.contains("Session or Tab") || !dispatchErr.contains("preserved") {
            XCTFail(dispatchErr)
        }
    }

    func testCreatePreSwitchRefusesBeforeMutation() throws {
        let repo = try fixtureRepo(env)
        try put(env.get("WORKTRUNK_PROJECT_CONFIG_PATH") ?? "", "[pre-switch]\ncheck = \"true\"\n", mode: 0o600)
        let call = makeClient(self, Handler(ctx: Ctx(), cfg: .default()))
        let err = call("worktrees.create", .object(["repo": .string(repo), "branch": .string("local-setup"), "base": .string("main")]), nil)
        if !err.contains("pre-switch") {
            XCTFail(err)
        }
        if WorktreeKit.list(repo: repo).count != 1 {
            XCTFail("pre-switch refusal mutated repository")
        }
    }
}
