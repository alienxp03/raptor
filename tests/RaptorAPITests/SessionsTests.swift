import Foundation
import RaptorCatalog
import RaptorRex
import XCTest
@testable import RaptorAPI

final class SessionsTests: APITestCase {
    func testSessionsGroupedListingAndSearch() throws {
        env.set("XDG_CACHE_HOME", makeTempDir())
        let dir = makeTempDir()
        env.set("PATH", dir + ":" + (env.get("PATH") ?? ""))
        let ssh = "#!/bin/sh\ncase \"$*\" in\n  *'zoxide query -l'*) printf '%s\\n' /home/azuan/workspace/hnhiring ;;\nesac\n"
        try put(dir + "/ssh", ssh)
        let script = #"""
        #!/bin/sh
        case "$*" in
          'api call hosts.list') echo '{"hosts":[{"id":"host:1","label":"hades"}]}' ;;
          '-S hades --timeout 3s ls --json') echo '{"sessions":[{"session_id":"r1","label":"wispy-brook"}]}' ;;
          'ls --json') echo '{"sessions":[{"session_id":"a","label":"Project"},{"session_id":"b","label":"Tools"}]}' ;;
          'do'*) echo '{"sessions":[]}' ;;
          '-S hades --timeout 4s do'*) echo '{"sessions":[]}' ;;
        esac
        """#
        try put(dir + "/rex", script)
        let zoxide = "#!/bin/sh\nprintf '%s\\n' /Users/azuan/Workspace/Projects\nprintf '%s\\n' /Users/azuan/.dotfiles\n"
        try put(dir + "/zoxide", zoxide)
        let h = Handler(ctx: Ctx(session: "a"), cfg: .default())
        let table: [(query: String, kinds: [String], ids: [String])] = [
            ("", ["session", "session", "session", "dir", "dir", "dir"],
                ["a", "b", "r1", "/Users/azuan/Workspace/Projects", "/Users/azuan/.dotfiles", "/home/azuan/workspace/hnhiring"]),
            ("project", ["session", "dir"], ["a", "/Users/azuan/Workspace/Projects"]),
            ("wispy", ["session"], ["r1"]),
            ("zzzz", [], []),
        ]
        for tt in table {
            subtest("query=\(tt.query)", {
                let params = JS.object(["query": .string(tt.query)])
                let output = DataOutput()
                let input = "{\"id\":1,\"method\":\"sessions\",\"params\":" + params.encode() + "}"
                try h.serve(input: DataInput(input), output: output)
                let res = decodeWire(output.text.trimmingCharacters(in: .whitespacesAndNewlines))
                if !(res.error ?? "").isEmpty {
                    XCTFail("response = \(output.text), error = \(res.error ?? "")")
                    return
                }
                let items = try decodeLauncherRows(res.result ?? "")
                var ids: [String] = []
                var kinds: [String] = []
                for item in items {
                    ids.append(item.id)
                    kinds.append(item.kind)
                    if item.kind == "session" {
                        if item.path != item.id || item.sessionID.isEmpty || item.sessionLabel.isEmpty || item.host.isEmpty {
                            XCTFail("incomplete session row shape: \(item)")
                        }
                    } else {
                        if item.kind != "dir" || item.path.isEmpty || item.label.isEmpty || item.host.isEmpty {
                            XCTFail("incomplete directory row shape: \(item)")
                        }
                    }
                }
                var wantSelected = ""
                if !tt.ids.isEmpty {
                    wantSelected = tt.ids[0]
                    if tt.query.isEmpty {
                        wantSelected = "b"
                    }
                }
                let resultDict = try jsonDict(res.result ?? "{}")
                let selectedID = resultDict["selected_id"] as? String ?? ""
                let hosts = try decodeHostHeaders(res.result ?? "")
                if ids != tt.ids || kinds != tt.kinds || hosts.count != 2 || resultDict["items"] == nil
                    || resultDict["targets"] == nil || resultDict["target"] as? String != "session" {
                    XCTFail("result ids = \(ids) kinds = \(kinds) hosts = \(hosts), want ids \(tt.ids)")
                }
                if selectedID != wantSelected {
                    XCTFail("selected_id=\(selectedID), want \(wantSelected)")
                }
            })
        }
    }

    func testSessionsKeepUnreachableHostHeaderWithoutRows() throws {
        env.set("XDG_CACHE_HOME", makeTempDir())
        let dir = makeTempDir()
        env.set("PATH", dir + ":" + (env.get("PATH") ?? ""))
        let script = #"""
        #!/bin/sh
        case "$*" in
          'api call hosts.list') echo '{"hosts":[{"id":"host:1","label":"gone"}]}' ;;
          '-S gone --timeout 3s ls --json') echo 'ssh: connect failed' >&2; exit 255 ;;
          'ls --json') echo '{"sessions":[{"session_id":"a","label":"Project"}]}' ;;
          'do'*) echo '{}' ;;
          *) exit 1 ;;
        esac
        """#
        let zoxide = "#!/bin/sh\nexit 0\n"
        try put(dir + "/zoxide", zoxide)
        try put(dir + "/rex", script)
        let h = Handler(ctx: Ctx(session: "a"), cfg: .default())
        let output = DataOutput()
        let input = "{\"id\":1,\"method\":\"sessions\",\"params\":{\"query\":\"\"}}"
        try h.serve(input: DataInput(input), output: output)
        let res = decodeWire(output.text.trimmingCharacters(in: .whitespacesAndNewlines))
        if !(res.error ?? "").isEmpty {
            XCTFail("response = \(output.text), error = \(res.error ?? "")")
            return
        }
        let items = try decodeLauncherRows(res.result ?? "")
        if items.count != 1 || items[0].id != "a" {
            XCTFail("items = \(items), want only the local session")
        }
        let hosts = try decodeHostHeaders(res.result ?? "")
        if hosts.count != 2 {
            XCTFail("hosts = \(hosts), want local and unreachable headers")
        }
        let unreachable = hosts[1]
        if unreachable.label != "gone" || unreachable.reachable || unreachable.error.isEmpty {
            XCTFail("unreachable header = \(unreachable)")
        }
    }

    func testSessionsJumpRoutesRowKinds() throws {
        env.set("XDG_CACHE_HOME", makeTempDir())
        let dir = makeTempDir()
        let log = dir + "/calls"
        env.set("PATH", dir + ":" + (env.get("PATH") ?? ""))
        env.set("REX_TEST_LOG", log)
        try put(dir + "/rex", "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$REX_TEST_LOG\"\n")
        let h = Handler(ctx: Ctx(client: "client"), cfg: .default())
        for params in [
            "{\"kind\":\"session\",\"session_id\":\"a\"}",
            "{\"kind\":\"window\",\"session_id\":\"a\",\"window_id\":\"a2\"}",
        ] {
            let (_, error) = h.call("sessions.jump", params)
            if let error {
                XCTFail("\(error)")
            }
        }
        let got = try readFile(log)
        let want = "-C client do session.select session_id=a\n-C client do session.select session_id=a window_id=a2\n"
        if got != want {
            XCTFail("calls = \(got), want \(want)")
        }
    }

    func testSessionsJumpOnHostSelectsThroughRemoteAppClient() throws {
        env.set("XDG_CACHE_HOME", makeTempDir())
        let dir = makeTempDir()
        let log = dir + "/calls"
        env.set("PATH", dir + ":" + (env.get("PATH") ?? ""))
        env.set("REX_TEST_LOG", log)
        let script = #"""
        #!/bin/sh
        printf '%s\n' "$*" >> "$REX_TEST_LOG"
        case "$*" in
          'api call client.list {"kinds":["app"]}')
            echo '{"clients":[{"client_id":"client:local","info":{"kind":"app","label":"azuanz"}}]}' ;;
          '-S hades api call client.list {"kinds":["app"]}')
            echo '{"clients":[{"client_id":"client:remote-cli","info":{"kind":"cli","label":"other"}},{"client_id":"client:remote-app","info":{"kind":"app","label":"azuanz"}}]}' ;;
        esac
        """#
        try put(dir + "/rex", script)
        let h = Handler(ctx: Ctx(client: "client:local"), cfg: .default())
        let params = "{\"kind\":\"session\",\"session_id\":\"r1\",\"host\":\"hades\"}"
        let (_, error) = h.call("sessions.jump", params)
        if let error {
            XCTFail("\(error)")
        }
        let got = try readFile(log)
        let want = "api call client.list {\"kinds\":[\"app\"]}\n"
            + "-S hades api call client.list {\"kinds\":[\"app\"]}\n"
            + "-S hades -C client:remote-app do session.select session_id=r1\n"
        if got != want {
            XCTFail("calls = \(got), want \(want)")
        }
    }

    func testSessionsCreateReusesLabelAndSelects() throws {
        env.set("XDG_CACHE_HOME", makeTempDir())
        let dir = makeTempDir()
        let log = dir + "/calls"
        env.set("PATH", dir + ":" + (env.get("PATH") ?? ""))
        env.set("REX_TEST_LOG", log)
        let script = #"""
        #!/bin/sh
        printf '%s\n' "$*" >> "$REX_TEST_LOG"
        case "$*" in
          'ls --json') echo '{"sessions":[{"session_id":"existing","label":"raptor"}]}' ;;
        esac
        """#
        try put(dir + "/rex", script)
        let h = Handler(ctx: Ctx(client: "client"), cfg: .default())
        let params = "{\"host\":\"\",\"dir\":\"/Users/x/Workspace/raptor\"}"
        let (result, error) = h.call("sessions.create", params)
        if let error {
            XCTFail("\(error)")
            return
        }
        let payload = result?.encode() ?? ""
        let dict = (try? jsonDict(payload)) ?? [:]
        if dict["session_id"] as? String != "existing" || dict["existing"] as? Bool != true {
            XCTFail("result = \(payload)")
        }
        let got = try readFile(log)
        let want = "ls --json\n-C client do session.select session_id=existing\n"
        if got != want {
            XCTFail("calls = \(got), want \(want)")
        }
    }

    func testSessionsCreateOnRemoteHost() throws {
        env.set("XDG_CACHE_HOME", makeTempDir())
        let dir = makeTempDir()
        let log = dir + "/calls"
        env.set("PATH", dir + ":" + (env.get("PATH") ?? ""))
        env.set("REX_TEST_LOG", log)
        let script = #"""
        #!/bin/sh
        printf '%s\n' "$*" >> "$REX_TEST_LOG"
        case "$*" in
          '-S hades --timeout 3s ls --json') echo '{"sessions":[]}' ;;
          '-S hades new --json -c /home/azuan/workspace/hnhiring hnhiring')
            echo '{"session_id":"remote-1"}' ;;
          '-S hades api call client.list {"kinds":["app"]}')
            echo '{"clients":[{"client_id":"client:remote-app","info":{"kind":"app","label":"azuanz"}}]}' ;;
          'api call client.list {"kinds":["app"]}')
            echo '{"clients":[{"client_id":"client:local","info":{"kind":"app","label":"azuanz"}}]}' ;;
        esac
        """#
        try put(dir + "/rex", script)
        let h = Handler(ctx: Ctx(client: "client:local"), cfg: .default())
        let params = "{\"host\":\"hades\",\"dir\":\"/home/azuan/workspace/hnhiring\"}"
        let (_, error) = h.call("sessions.create", params)
        if let error {
            XCTFail("\(error)")
        }
        let got = try readFile(log)
        let want = "-S hades ls --json\n"
            + "-S hades new --json -c /home/azuan/workspace/hnhiring hnhiring\n"
            + "api call client.list {\"kinds\":[\"app\"]}\n"
            + "-S hades api call client.list {\"kinds\":[\"app\"]}\n"
            + "-S hades -C client:remote-app do session.select session_id=remote-1\n"
        if got != want {
            XCTFail("calls = \(got), want \(want)")
        }
    }

    func testSessionsCreateRefusesToCloseOriginUnchanged() throws {
        let dir = makeTempDir()
        env.set("PATH", dir + ":" + (env.get("PATH") ?? ""))
        try put(dir + "/rex", "#!/bin/sh\nexit 0\n")
        let h = Handler(ctx: Ctx(session: "origin"), cfg: .default())
        let (_, error) = h.call("sessions.create", "{\"host\":\"\",\"dir\":\"\"}")
        if error == nil {
            XCTFail("create without a directory must fail")
        }
    }
}
