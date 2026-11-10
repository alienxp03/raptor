import XCTest
@testable import RaptorRex

final class EventsTests: XCTestCase {
    func testRelevantEvents() throws {
        for name in ["program_status_changed", "program_status_removed", "pwd_changed", "process_changed", "child_exited", "title_changed"] {
            let line = "{\"type\":\"session_event\",\"payload\":{\"session_id\":\"s\",\"event\":{\"type\":\"block_event\",\"payload\":{\"name\":\"\(name)\"}}}}"
            XCTAssertTrue(Rex.relevantEvent(Data(line.utf8)), "ignored \(name)")
        }
        for line in ["garbage", "{\"type\":\"client_joined\"}", "{\"type\":\"client_left\"}", "{\"type\":\"client_changed\"}", "{\"type\":\"session_event\",\"payload\":{\"event\":{\"type\":\"client_connected\"}}}", "{\"type\":\"block_event\",\"payload\":{\"name\":\"bell\"}}", "{\"type\":\"future_event\"}"] {
            XCTAssertFalse(Rex.relevantEvent(Data(line.utf8)), "accepted \(line)")
        }
        for name in ["session_created", "session_destroyed", "session_label_changed", "session_view_changed", "window_closed", "hosts_changed"] {
            XCTAssertTrue(Rex.relevantEvent(Data("{\"type\":\"\(name)\"}".utf8)), "ignored \(name)")
        }
    }

    func testWatcherDeliveryReconnectCancel() throws {
        let dir = fakeEventCLI("""
        echo "$*" >> "$EVENT_LOG"
        if [ -f "$EVENT_FIRST" ]; then
         printf '%s\\n' '{"type":"session_event","payload":{"event":{"type":"block_event","payload":{"name":"program_status_changed"}}}}'
         exec sleep 60
        fi
        touch "$EVENT_FIRST"
        exit 0
        """)
        let log = dir + "/log"
        setenvTemp("EVENT_LOG", log)
        setenvTemp("EVENT_FIRST", dir + "/first")
        let watcher = Rex.watchEvents()
        addTeardownBlock { watcher.close() }
        watcher.addHost("devbox")
        watcher.addHost("devbox") // Idempotent, no second stream for the same host.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if watcher.changes.wait(timeout: min(0.2, deadline.timeIntervalSinceNow)) != nil {
                let data = readTextFile(log)
                if countOccurrences(data, "--all --fail-fast") >= 3 {
                    XCTAssertTrue(data.contains("-S devbox do -e"), "wrong host arguments: \(data)")
                    let closeStart = Date()
                    watcher.close()
                    XCTAssertLessThan(Date().timeIntervalSince(closeStart), 1, "cancel did not reap streams")
                    return
                }
            }
        }
        XCTFail("no reconnect/delivery")
    }

    func testWatcherReadyRefreshesWithoutStartupTimer() throws {
        fakeEventCLI("""
        printf '%s\\n' '{"type":"raptor_ready"}'
        exec sleep 60
        """)
        let watcher = Rex.watchEvents()
        addTeardownBlock { watcher.close() }
        XCTAssertNotNil(watcher.changes.wait(timeout: 1), "native subscription acknowledgement did not invalidate snapshot")
        XCTAssertNil(watcher.changes.wait(timeout: 0.05), "quiet subscription caused another state refresh")
        XCTAssertTrue(Rex.eventsScript.contains("rex.call(\"session.attach_all\", {event_scope=\"all\"})"))
        XCTAssertFalse(Rex.eventsScript.contains("rex.every"), "subscription must use native attach acknowledgement, not a timer")
    }

    func testWatcherBoundedInvalidations() {
        let watcher = EventWatcher(changes: ChangeChannel())
        for _ in 0..<10000 {
            watcher.changed("")
        }
        XCTAssertEqual(watcher.pendingChangeCount, 1, "queue length")
        watcher.close()
    }
}
