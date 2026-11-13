import Foundation
import XCTest
@testable import RaptorAPI

final class StdinIsolationTests: APITestCase {
    func testPumpDiscoveryAndStreamUseNullStdin() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        env.set("PATH", dir + ":" + (env.get("PATH") ?? ""))
        env.set("RAPTOR_STDIN_PROBE_DIR", dir)
        try put(dir + "/rex", """
        #!/bin/sh
        if [ /dev/fd/0 -ef /dev/null ]; then result=null; else result=inherited; fi
        case "$*" in
          *hosts.list*)
            printf '%s' "$result" > "$RAPTOR_STDIN_PROBE_DIR/discovery"
            printf '%s\\n' '{"hosts":[]}' ;;
          *'do -e'*)
            printf '%s' "$result" > "$RAPTOR_STDIN_PROBE_DIR/stream"
            printf '%s\\n' '{"type":"raptor_ready"}' ;;
          *) exit 1 ;;
        esac
        """)
        let pump = APIEventPump(onChange: {})
        pump.start()
        defer { pump.close() }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let discovery = try? String(contentsOfFile: dir + "/discovery", encoding: .utf8)
            let stream = try? String(contentsOfFile: dir + "/stream", encoding: .utf8)
            if let discovery, !discovery.isEmpty, let stream, !stream.isEmpty {
                XCTAssertEqual(discovery, "null", "host discovery inherited stdin")
                XCTAssertEqual(stream, "null", "event stream inherited stdin")
                return
            }
            usleep(10_000)
        }
        XCTFail("pump did not execute both capture paths")
    }
}
