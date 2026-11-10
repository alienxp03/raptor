import Foundation
import RaptorPullrequest
import RaptorRex
import RaptorWorktree
import XCTest
@testable import RaptorAPI

final class PullrequestsTests: APITestCase {
    func testPullRequestURLDoesNotResolveOriginPane() throws {
        let bin = makeTempDir()
        let log = bin + "/rex-called"
        let script = "#!/bin/sh\nprintf called > '" + log + "'\nexit 1\n"
        try put(bin + "/rex", script)
        env.set("PATH", bin + ":" + (env.get("PATH") ?? ""))
        let h = Handler(ctx: Ctx(session: "origin", block: "block"), cfg: .default())
        let (_, error) = h.call("pullrequests.resolve", "{\"input\":\"https://github.com/demo/example/pull/0\"}")
        if error == nil {
            XCTFail("invalid PR URL accepted")
        }
        if fileExists(log) {
            XCTFail("URL resolution inspected an unrelated origin pane")
        }
    }

    func testPrepareRefusalDoesNotEnterOpenRecovery() throws {
        let repo = try fixtureRepo(env)
        env.set("XDG_STATE_HOME", makeTempDir())
        _ = try WorktreeKit.gitOut(dir: repo, args: ["remote", "add", "origin", "https://github.com/demo/example.git"])
        let project = env.get("WORKTRUNK_PROJECT_CONFIG_PATH") ?? ""
        try put(project, "pre-switch = 'echo guard'\n", mode: 0o600)
        let bin = makeTempDir()
        let script = #"""
        #!/bin/sh
        case "$1" in
        api) printf '%s\n' '{"base":{"repo":{"full_name":"demo/example"}}}' ;;
        pr) printf '%s\n' '{"number":23,"title":"Example PR","headRefName":"main","url":"https://github.com/demo/example/pull/23"}' ;;
        *) exit 1 ;;
        esac
        """#
        try put(bin + "/gh", script)
        env.set("PATH", bin + ":" + (env.get("PATH") ?? ""))
        let params = JS.object(["repo": .string(repo), "input": .string("23")])
        let (result, error) = Handler(ctx: Ctx(), cfg: .default()).callJSON("pullrequests.prepare", params)
        if error == nil || !String(describing: error!).contains("pre-switch") || result != nil {
            XCTFail("must retry Prepare, not Open: result=\(String(describing: result)) error=\(String(describing: error))")
        }
    }

    func testPullRequestCommitOptionRouting() throws {
        let repo = try fixtureRepo(env)
        _ = try WorktreeKit.gitOut(dir: repo, args: ["remote", "add", "origin", "https://github.com/demo/example.git"])
        let bin = makeTempDir()
        let script = #"""
        #!/bin/sh
        case "$1" in
        api) echo '{"base":{"repo":{"full_name":"demo/example"}}}' ;;
        pr) echo '{"number":23,"title":"Example","headRefName":"feature"}' ;;
        *) exit 1 ;;
        esac
        """#
        try put(bin + "/gh", script)
        env.set("PATH", bin + ":" + (env.get("PATH") ?? ""))
        let h = Handler(ctx: Ctx(), cfg: .default())
        for explicit in [false, true] {
            let params = JS.object(["repo": .string(repo), "input": .string("23"), "checkout_commit": .bool(explicit)])
            let (result, error) = h.callJSON("pullrequests.resolve", params)
            if let error {
                XCTFail("\(error)")
                continue
            }
            guard case .info(let info) = result else {
                XCTFail("unexpected resolve result")
                continue
            }
            let want = explicit ? "pr/23" : "feature"
            if info.branch != want || info.path.isEmpty {
                XCTFail("explicit=\(explicit): branch=\(info.branch)")
            }
            if explicit {
                let (_, prepareError) = h.callJSON("pullrequests.prepare", params)
                if prepareError == nil || !String(describing: prepareError!).contains("head OID") {
                    XCTFail("explicit option not routed: \(String(describing: prepareError))")
                }
            }
        }
    }

    func testPullRequestRequestValidation() {
        let h = Handler(ctx: Ctx(), cfg: .default())
        let table: [(method: String, params: String, want: String)] = [
            ("pullrequests.resolve", "{\"input\":23}", "cannot unmarshal"),
            ("pullrequests.prepare", "{\"input\":\"23\",\"checkout_commit\":\"true\"}", "cannot unmarshal"),
            ("pullrequests.resolve", "{}", "enter a GitHub"),
            ("pullrequests.prepare", "{\"input\":\" \"}", "enter a GitHub"),
            ("pullrequests.open", "{}", "worktree path is required"),
            ("pullrequests.open", "{\"path\":\"/no-worktree\",\"target\":\"here\"}", "session or tab"),
            ("pullrequests.open", "{\"path\":\"/no-worktree\",\"target\":12}", "cannot unmarshal"),
        ]
        for tc in table {
            subtest(tc.method + tc.params, {
                let (_, error) = h.call(tc.method, tc.params)
                if error == nil || !String(describing: error!).contains(tc.want) {
                    XCTFail("error = \(String(describing: error)), want \(tc.want)")
                }
            })
        }
    }
}
