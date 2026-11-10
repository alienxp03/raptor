import Foundation
import RaptorRex
import XCTest
@testable import RaptorAPI

final class StatusFallbackTests: APITestCase {
    func testColdLauncherDoesNotRequireActivityAPI() throws {
        env.set("XDG_CACHE_HOME", makeTempDir())
        let dir = makeTempDir()
        env.set("PATH", dir + ":" + (env.get("PATH") ?? ""))
        let log = dir + "/calls"
        env.set("STATUS_FALLBACK_LOG", log)
        let script = #"""
        #!/bin/sh
        printf '%s\n' "$*" >> "$STATUS_FALLBACK_LOG"
        case "$*" in
         do*) exit 1 ;;
         'ls --json') echo '{"sessions":[{"session_id":"session:one","label":"One"}]}' ;;
         'api call hosts.list') echo '{"hosts":[]}' ;;
         *) echo '{}' ;;
        esac
        """#
        for (name, body) in ["rex": script, "zoxide": "#!/bin/sh\nprintf '/work/project\\n'\n"] {
            try put(dir + "/" + name, body)
        }
        let h = Handler(ctx: Ctx(), cfg: .default())
        let (result, error) = h.call("sessions", "{}")
        if let error {
            XCTFail("optional activity failure hid the cold launcher: \(error)")
            return
        }
        guard case .sessions(_, let rows, _, _, _) = result else {
            XCTFail("unexpected sessions result")
            return
        }
        if rows.count != 2 || rows[0].kind != "session" || rows[1].path != "/work/project" {
            XCTFail("plain discovery rows missing: \(rows.map { $0.kind + "/" + $0.path })")
        }
        for row in rows {
            if row.working || !row.state.isEmpty {
                XCTFail("failed status scan invented activity: \(row.kind)")
            }
        }
        if h.activityLoaded {
            XCTFail("failed activity scan must not become a successful empty snapshot")
        }
        let calls = try readFile(log)
        if calls.components(separatedBy: "local result = { sessions = {} }").count - 1 != 1 {
            XCTFail("cold fallback repeated the failed status scan: \(calls)")
        }
    }
}
