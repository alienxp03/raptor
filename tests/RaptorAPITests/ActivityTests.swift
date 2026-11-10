import Foundation
import RaptorRex
import XCTest
@testable import RaptorAPI

final class ActivityTests: APITestCase {
    func testActivitySnapshotViewsCacheAndFailure() throws {
        env.set("XDG_CACHE_HOME", makeTempDir())
        let dir = makeTempDir()
        let log = dir + "/scans"
        let fail = dir + "/fail"
        env.set("PATH", dir + ":" + (env.get("PATH") ?? ""))
        env.set("ACTIVITY_LOG", log)
        env.set("ACTIVITY_FAIL", fail)
        let script = #"""
        #!/bin/sh
        if [ "$1" = do ]; then
         echo scan >> "$ACTIVITY_LOG"
         [ ! -f "$ACTIVITY_FAIL" ] || exit 1
         echo '{"sessions":[{"session_id":"s","active_window_id":"w","windows":[{"window_id":"w","focused_block_id":"b","blocks":[{"block_id":"b","process":{"foreground":{"cwd":"/repo/sub"}},"records":[{"app":"pi","state":"working"},{"app":"codex","state":"blocked"}]}]}]}]}'
         exit 0
        fi
        case "$*" in
         'ls --json') echo '{"sessions":[{"session_id":"s","label":"Repo"}]}' ;;
         'api call -s s session.view '*) echo '{"windows":[{"window_id":"w","label":"Tab"}]}' ;;
         *) exit 1 ;;
        esac
        """#
        for (name, contents) in ["rex": script, "zoxide": "#!/bin/sh\nprintf '/repo\\n/repo/sub\\n/repo-other\\n'\n"] {
            try put(dir + "/" + name, contents)
        }
        let h = Handler(ctx: Ctx(session: "s"), cfg: .default())
        func call(_ method: String) -> MethodResult? {
            let (result, error) = h.call(method, "{}")
            if let error {
                XCTFail("\(error)")
            }
            return result
        }
        func scans(_ want: Int) throws {
            let data = try readFile(log)
            let got = data.components(separatedBy: "scan").count - 1
            if got != want {
                XCTFail("scans=\(got) want=\(want)")
            }
        }
        // The launcher cache is per test; legs that must hit the live fetch
        // clear it first.
        func clearCache() {
            try? FileManager.default.removeItem(atPath: h.launcherCachePath())
        }
        func checkSessions(_ active: Bool) {
            guard case .sessions(_, let items, _, _, _) = call("sessions") else {
                XCTFail("unexpected sessions result")
                return
            }
            if items.count != 4 {
                XCTFail("sessions count \(items.count)")
                return
            }
            // The session and exact working folder light up. The parent and
            // unrelated directories stay quiet, even while the agent is working.
            for item in items {
                let matches = active && (item.kind == "session" || item.path == "/repo/sub")
                if matches && (item.state != "blocked" || !item.working) {
                    XCTFail("row \(item.kind)/\(item.path) state=\(item.state) working=\(item.working)")
                }
                if !matches && (!item.state.isEmpty || item.working) {
                    XCTFail("failed snapshot row \(item.kind)/\(item.path)")
                }
            }
        }

        clearCache()
        _ = call("sessions") // Cold start: snapshot scan + live fetch + cache write.
        checkSessions(true)
        try scans(1)
        do {
            let (_, contextError) = h.call("context", "{\"session\":\"other\"}")
            if let contextError {
                XCTFail("\(contextError)")
            }
        }
        // A fresh cache answers without touching the snapshot.
        checkSessions(true)
        try scans(1)
        guard case .agents(let agentItems, _) = call("agents") else {
            XCTFail("unexpected agents result")
            return
        }
        if agentItems.count != 2 || agentItems[0].active {
            XCTFail("agents \(agentItems.count)")
        }
        try scans(1)
        // Expiry and disk deletion must not evict the persistent memory snapshot.
        h.activityAt = Date().addingTimeInterval(-Handler.activitySnapshotTTL - 1)
        clearCache()
        checkSessions(true)
        try scans(1)

        FileManager.default.createFile(atPath: fail, contents: nil)
        h.requestRefresh()
        h.cacheMu.lock()
        let done = h.refreshDone
        h.cacheMu.unlock()
        done?.wait(until: Date().addingTimeInterval(10))
        checkSessions(true) // Failed refresh preserves both usable snapshots.
        _ = call("agents")
        try scans(2)
        try FileManager.default.removeItem(atPath: fail)
        clearCache()
        checkSessions(true)
        try scans(2)
        // Cache is per Handler, not process-wide.
        let other = Handler(ctx: Ctx(), cfg: .default())
        _ = try other.activitySnapshot(fresh: false)
        try scans(3)
    }

    func testActivityCachesSuccessfulEmptySnapshot() throws {
        let dir = makeTempDir()
        let log = dir + "/log"
        env.set("PATH", dir + ":" + (env.get("PATH") ?? ""))
        env.set("ACTIVITY_LOG", log)
        try put(dir + "/rex", "#!/bin/sh\necho scan >> \"$ACTIVITY_LOG\"\necho '{}'\n")
        let h = Handler(ctx: Ctx(), cfg: .default())
        for _ in 0..<2 {
            _ = try h.activitySnapshot(fresh: false)
        }
        let data = try readFile(log)
        if data.components(separatedBy: "scan").count - 1 != 1 {
            XCTFail("log=\(data)")
        }
    }
}
