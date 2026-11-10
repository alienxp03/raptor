import Foundation
import RaptorCatalog
import RaptorRex
import XCTest
@testable import RaptorAPI

/// Response sink that records NDJSON lines and detects concurrent writes.
final class EventOutput: ResponseOutput {
    let feed = LineFeed()
    private let writeLock = NSLock()
    private var writing = false

    var interleaved = false

    func writeChunk(_ data: Data) throws {
        writeLock.lock()
        if writing {
            interleaved = true
        }
        writing = true
        writeLock.unlock()
        feed.push(LineFeed.Item(line: data, oversized: false, eof: false, error: nil))
        writeLock.lock()
        writing = false
        writeLock.unlock()
    }
}

final class EventsTests: APITestCase {
    func testServeContextCancellationUnblocksIdleRead() {
        let input = Pipe()
        let token = CancelToken()
        final class Box: @unchecked Sendable {
            var error: Error?
            var done = false
        }
        let box = Box()
        let thread = Thread {
            do {
                try Handler(ctx: Ctx(), cfg: .default())
                    .serveContext(input: PipeInput(input), output: DataOutput(), cancel: token)
            } catch {
                box.error = error
            }
            box.done = true
        }
        thread.start()
        token.cancel()
        let deadline = Date().addingTimeInterval(1)
        while !box.done && Date() < deadline {
            usleep(10_000)
        }
        if !box.done {
            XCTFail("shutdown waited for another input line")
        }
        if let error = box.error {
            XCTFail("\(error)")
        }
        try? input.fileHandleForWriting.close()
    }

    func testServeEventsSubscriptionFreshCacheAndEOF() throws {
        env.set("XDG_CACHE_HOME", makeTempDir())
        let dir = makeTempDir()
        env.set("PATH", dir + ":" + (env.get("PATH") ?? ""))
        let script = #"""
        #!/bin/sh
        case "$*" in
         *'do -e'*'--all --fail-fast')
         printf '%s\n' '{"type":"session_created","payload":{"session":{"session_id":"new","label":"New"}}}'
         exec sleep 60 ;;
         'ls --json') echo '{"sessions":[]}' ;;
         *) echo '{}' ;;
        esac
        """#
        for (name, content) in ["rex": script, "zoxide": "#!/bin/sh\nexit 0\n"] {
            try put(dir + "/" + name, content)
        }
        let h = Handler(ctx: Ctx(), cfg: .default())
        try FileManager.default.createDirectory(atPath: dirName(h.launcherCachePath()), withIntermediateDirectories: true)
        h.writeLauncherCache([LauncherItem(kind: "dir", id: "/stale", path: "/stale", label: "Stale")], nil)
        h.activityAgents = [AgentEntry(state: "blocked")]
        h.activityAt = Date()
        let input = Pipe()
        let out = EventOutput()
        final class Box: @unchecked Sendable {
            var error: Error?
            var done = false
        }
        let box = Box()
        let serveThread = Thread {
            do {
                try h.serve(input: PipeInput(input), output: out)
            } catch {
                box.error = error
            }
            box.done = true
        }
        serveThread.start()
        addTeardown {
            try? input.fileHandleForWriting.close()
            for _ in 0..<200 where serveThread.isExecuting {
                usleep(50_000)
            }
            if serveThread.isExecuting {
                XCTFail("serve did not observe EOF")
            }
            if let error = box.error {
                XCTFail("\(error)")
            }
        }
        func request(_ id: Int, _ method: String, _ params: String) throws {
            let line = "{\"id\":\(id),\"method\":\"\(method)\",\"params\":\(params)}\n"
            try input.fileHandleForWriting.write(contentsOf: Data(line.utf8))
        }
        func read() throws -> [String: String] {
            guard let data = out.feed.pop(timeout: 5)?.line else {
                XCTFail("no protocol output")
                return [:]
            }
            let text = String(decoding: data, as: UTF8.self)
            if rawFields(text).isEmpty {
                XCTFail("interleaved JSON: \(text)")
            }
            return rawFields(text)
        }
        try request(1, "theme", "{}")
        let first = try read()
        if first["id"] != "1" || first["event"] != nil {
            XCTFail("unexpected initial output \(first)")
        }
        if out.feed.pop(timeout: 0.05) != nil {
            XCTFail("notification before opt-in")
        }
        try request(2, "events.subscribe", "{\"enabled\":true}")
        var sawResponse = false
        var sawEvent = false
        while !sawResponse || !sawEvent {
            let value = try read()
            if value["id"] == "2" {
                sawResponse = true
                if value["result"] != "{}" {
                    XCTFail("subscribe response: \(value)")
                }
            }
            if value["event"] == "\"rex.changed\"" {
                sawEvent = true
                if value["id"] != nil || value.count != 1 {
                    XCTFail("invalid notification \(value)")
                }
            }
        }
        try request(3, "sessions", "{}")
        while true {
            let value = try read()
            if value["id"] == "3" {
                if (value["result"] ?? "").contains("/stale") {
                    XCTFail("live request returned disk cache")
                }
                break
            }
        }
        for id in 4..<20 {
            try request(id, "theme", "{}")
            while true {
                if try read()["id"] == String(id) {
                    break
                }
            }
        }
        try request(20, "events.subscribe", "{\"enabled\":false}")
        while true {
            if try read()["id"] == "20" {
                break
            }
        }
        if out.feed.pop(timeout: 0.05) != nil {
            XCTFail("notification after unsubscribe")
        }
        // Subscribe again, then close stdin while the child is still streaming.
        try request(21, "events.subscribe", "{\"enabled\":true}")
        while true {
            if try read()["id"] == "21" {
                break
            }
        }
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(1)
        while !box.done && Date() < deadline {
            usleep(10_000)
        }
        if !box.done {
            XCTFail("EOF leaked event watcher")
        }
        if let error = box.error {
            XCTFail("\(error)")
        }
        if out.interleaved {
            XCTFail("concurrent output writes")
        }
    }

    func testEventGenerationRejectsStaleCacheAndActivity() throws {
        env.set("XDG_CACHE_HOME", makeTempDir())
        let h = Handler(ctx: Ctx(), cfg: .default())
        try FileManager.default.createDirectory(atPath: dirName(h.launcherCachePath()), withIntermediateDirectories: true)
        let generation = h.cacheGeneration()
        h.storeLauncher(generation, [LauncherItem(id: "/old", path: "/old")], nil)
        h.invalidateActivity()
        do {
            let (cached, ok) = h.readLauncherCache()
            if !ok || cached.items?[0].path != "/old" {
                XCTFail("invalidation removed usable rows")
            }
        }
        h.storeLauncher(generation, [LauncherItem(id: "/late-worker", path: "/late-worker")], nil)
        do {
            let (cached, ok) = h.readLauncherCache()
            if !ok || cached.items?[0].path != "/old" {
                XCTFail("old worker replaced usable rows")
            }
        }
        h.storeLauncher(h.cacheGeneration(), [LauncherItem(id: "/fresh", path: "/fresh")], nil)
        let (cached, ok) = h.readLauncherCache()
        if !ok || cached.items?[0].path != "/fresh" {
            XCTFail("fresh cache rejected: \(String(describing: cached.items))")
        }
    }
}
