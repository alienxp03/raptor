import Foundation
import RaptorConfig
import RaptorRex
import XCTest
@testable import RaptorAPI

final class AgentsTests: APITestCase {
    func testAgentsListSearchAndJump() throws {
        let dir = makeTempDir()
        let log = dir + "/calls"
        env.set("PATH", dir + ":" + (env.get("PATH") ?? ""))
        env.set("REX_TEST_LOG", log)
        let script = #"""
        #!/bin/sh
        if [ "$1" = do ]; then
         printf '%s' '{"sessions":[{"session_id":"s","label":"Project","windows":[{"window_id":"w","label":"Build","blocks":[{"block_id":"b","records":[{"app":"pi","state":"idle","title":"Fix login"},{"id":"review","app":"codex","state":"blocked","title":"Review"}]}]}]}]}'
         exit 0
        fi
        printf '%s\n' "$*" >> "$REX_TEST_LOG"
        case "$*" in
         'api call -s s session.list_blocks '*) echo '{"blocks":[{"block_id":"b","window_id":"w","creator_name":"com.superlogical.terminal"}]}' ;;
        esac
        """#
        try put(dir + "/rex", script)
        let h = Handler(ctx: Ctx(session: "s", client: "origin-client"), cfg: .default())
        let table: [(query: String, count: Int)] = [
            ("", 2), ("login", 1), ("codex", 1), ("zzzzzz", 0),
        ]
        for tt in table {
            let params = JS.object(["query": .string(tt.query)])
            let (result, error) = h.callJSON("agents", params)
            if let error {
                XCTFail("\(error)")
                continue
            }
            guard case .agents(let items, let target) = result else {
                XCTFail("unexpected agents result")
                continue
            }
            if items.count != tt.count || target != RaptorConfig.default().enter {
                XCTFail("query \(tt.query): items=\(items.count) target=\(target)")
            }
        }
        let (_, jumpError) = h.call("agents.jump", "{\"session_id\":\"s\",\"window_id\":\"w\",\"block_id\":\"b\"}")
        if let jumpError {
            XCTFail("\(jumpError)")
        }
        let calls = try readFile(log)
        let want = "api call -s s session.list_blocks {\"session_id\":\"s\"}\n"
            + "api call -s s session.focus_block {\"block_id\":\"b\",\"session_id\":\"s\"}\n"
            + "-C origin-client do session.select session_id=s window_id=w\n"
        if calls != want {
            XCTFail("calls=\(calls) want=\(want)")
        }
    }

    func testAgentsInvalidParams() {
        let h = Handler(ctx: Ctx(), cfg: .default())
        let table: [(method: String, params: String)] = [
            ("agents", "{\"query\":5}"),
            ("agents.jump", "{}"),
            ("agents.jump", "{\"session_id\":\"s\"}"),
            ("agents.jump", "{\"session_id\":\"s\",\"window_id\":\"w\"}"),
            ("agents.jump", "{\"session_id\":\"s\",\"window_id\":\"w\",\"block_id\":5}"),
            ("agents.jump", "{\"session_id\":\" \",\"window_id\":\"w\",\"block_id\":\"b\"}"),
        ]
        for tt in table {
            let (_, error) = h.call(tt.method, tt.params)
            if error == nil {
                XCTFail("accepted \(tt.method) \(tt.params)")
            }
        }
    }

    func testAgentsEmptyWireShape() throws {
        let dir = makeTempDir()
        env.set("PATH", dir + ":" + (env.get("PATH") ?? ""))
        try put(dir + "/rex", "#!/bin/sh\nprintf '%s' '{}'\n")
        let h = Handler(ctx: Ctx(), cfg: .default())
        let (result, error) = h.call("agents", "{}")
        if let error {
            XCTFail("\(error)")
            return
        }
        guard let result else {
            XCTFail("no result")
            return
        }
        let wire = result.encode()
        if !wire.contains("\"items\":[]") || !wire.contains("\"targets\":[]") {
            XCTFail("result=\(wire)")
        }
    }
}
