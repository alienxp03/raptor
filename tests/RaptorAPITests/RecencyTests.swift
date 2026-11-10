import Foundation
import RaptorCatalog
import RaptorRex
import XCTest
@testable import RaptorAPI

final class RecencyTests: APITestCase {
    func testSessionRecencyFrozenOrdering() throws {
        let h = recencyHandler(env)
        var rows: [LauncherItem] = []
        for i in 0..<8 {
            let id = "session:\(i)"
            rows.append(LauncherItem(kind: "session", id: id, sessionID: id, label: "project",
                sessionLabel: "project", host: Rex.localHostLabel, local: true))
        }
        rows.append(contentsOf: [
            LauncherItem(kind: "session", id: "session:7", sessionID: "session:7", label: "project", sessionLabel: "project", host: "remote"),
            LauncherItem(kind: "dir", id: "/one", path: "/one", host: "dir-one"),
            LauncherItem(kind: "dir", id: "/two", path: "/two", host: "dir-two"),
        ])
        h.launcherLoaded = true
        h.launcher.items = rows
        h.ctx.session = "session:3"
        var latest = SessionRecency(["remote\u{0}session:7": 0, "\u{0}session:6": 1, "\u{0}session:7": 2])
        h.loadRecency = { latest }
        h.captureRecency(false)
        let want = [
            "This Mac/session:3", "remote/session:7", "This Mac/session:6", "This Mac/session:7",
            "This Mac/session:0", "This Mac/session:1", "This Mac/session:2", "This Mac/session:4",
            "This Mac/session:5", "dir-one/", "dir-two/",
        ]
        let got = sessionRows(h, "")
        if got != want {
            XCTFail("order = \(got)")
        }
        // Even a caller mutating its map cannot change the published snapshot.
        latest = SessionRecency(["remote\u{0}session:7": 0, "\u{0}session:6": 1, "\u{0}session:7": 2, "\u{0}session:0": -1])
        h.invalidateActivity()
        h.storeLauncher(h.cacheGeneration(), rows, nil)
        if sessionRows(h, "") != want {
            XCTFail("live refresh changed ranks: \(sessionRows(h, ""))")
        }
        do {
            let (_, contextError) = h.call("context", "{\"session\":\"session:3\"}")
            if let contextError {
                XCTFail("\(contextError)")
            }
        }
        if sessionRows(h, "")[1] != "This Mac/session:0" {
            XCTFail("context did not reload ranks: \(sessionRows(h, ""))")
        }
    }

    func testSessionRecencyFuzzyScoreBeforeRanks() {
        let h = recencyHandler(env)
        h.launcherLoaded = true
        h.ranks = SessionRecency(["\u{0}session:new": 0])
        h.launcher.items = [
            LauncherItem(kind: "session", id: "session:new", sessionID: "session:new", label: "a long project",
                sessionLabel: "a long project", host: Rex.localHostLabel, local: true),
            LauncherItem(kind: "session", id: "session:old", sessionID: "session:old", label: "project",
                sessionLabel: "project", host: Rex.localHostLabel, local: true),
        ]
        let got = sessionRows(h, "project")
        if got.count != 2 || got[0] != "This Mac/session:old" {
            XCTFail("fuzzy score lost: \(got)")
        }
    }

    func testFocusImmediateAckHiddenAndShutdown() throws {
        let h = recencyHandler(env)
        h.launcherLoaded = true
        h.launcher.items = []
        final class Gate: @unchecked Sendable {
            private let cond = NSCondition()
            private var fired = false
            func fire() {
                cond.lock()
                fired = true
                cond.broadcast()
                cond.unlock()
            }
            var isFired: Bool {
                cond.lock()
                defer { cond.unlock() }
                return fired
            }
            func wait(_ timeout: TimeInterval) {
                cond.lock()
                let deadline = Date().addingTimeInterval(timeout)
                while !fired {
                    if !cond.wait(until: deadline) {
                        break
                    }
                }
                cond.unlock()
            }
        }
        let entered = Gate()
        let exited = Gate()
        h.validateFocus = { cancel, _ in
            entered.fire()
            cancel.wait()
            exited.fire()
            return true
        }
        h.resolveFocus = { _ in
            XCTFail("resolved after shutdown")
            return ("", false)
        }
        let input = Pipe()
        let responses = Pipe()
        let output = PipeOutput(responses)
        let cancel = CancelToken()
        final class Box: @unchecked Sendable {
            var error: Error?
            var done = false
        }
        let box = Box()
        let serveThread = Thread {
            do {
                try h.serveContext(input: PipeInput(input), output: output, cancel: cancel)
            } catch {
                box.error = error
            }
            box.done = true
        }
        serveThread.start()
        addTeardown {
            try? input.fileHandleForWriting.close()
            try? responses.fileHandleForReading.close()
        }
        let received = LineFeed()
        let reader = Thread {
            let lineReader = LineReader(PipeInput(responses))
            while true {
                do {
                    let (line, _, eof) = try lineReader.next()
                    if !line.isEmpty {
                        received.push(LineFeed.Item(line: line, oversized: false, eof: eof, error: nil))
                    }
                    if eof { break }
                } catch {
                    break
                }
            }
        }
        reader.start()
        func send(_ id: Int, _ method: String, _ params: String) throws {
            let line = "{\"id\":\(id),\"method\":\"\(method)\",\"params\":\(params)}\n"
            try input.fileHandleForWriting.write(contentsOf: Data(line.utf8))
        }
        func nextResponse() -> WireResponse? {
            guard let item = received.pop(timeout: 2)?.line else {
                XCTFail("focus worker stalled")
                return nil
            }
            return decodeWire(String(decoding: item, as: UTF8.self))
        }
        try send(1, "events.subscribe", "{\"enabled\":false}")
        if nextResponse()?.error?.isEmpty == false {
            XCTFail("subscribe failed")
        }
        try send(2, "sessions.visit", observation("session:focus", 123, Date().addingTimeInterval(-1), false))
        if nextResponse()?.error?.isEmpty == false {
            XCTFail("visit failed")
        }
        entered.wait(2)
        // A blocked worker cannot block the next request, even while hidden.
        try send(3, "sessions", "{}")
        if nextResponse()?.error?.isEmpty == false {
            XCTFail("hidden request failed")
        }
        cancel.cancel()
        let deadline = Date().addingTimeInterval(2)
        while !box.done && Date() < deadline {
            usleep(10_000)
        }
        if !box.done {
            XCTFail("shutdown stalled")
        }
        if let error = box.error {
            XCTFail("\(error)")
        }
        exited.wait(2)
    }

    func testFocusValidationPreservesDistinctVisitsAndDeduplicates() throws {
        let h = recencyHandler(env)
        final class Gate: @unchecked Sendable {
            private let cond = NSCondition()
            private var fired = false
            private var released = false
            func fire() {
                cond.lock()
                fired = true
                cond.broadcast()
                cond.unlock()
            }
            var isFired: Bool {
                cond.lock()
                defer { cond.unlock() }
                return fired
            }
            func fireOnce() -> Bool {
                cond.lock()
                defer { cond.unlock() }
                if fired { return false }
                fired = true
                return true
            }
            func waitRelease(_ timeout: TimeInterval) {
                cond.lock()
                let deadline = Date().addingTimeInterval(timeout)
                while !released {
                    if !cond.wait(until: deadline) {
                        break
                    }
                }
                cond.unlock()
            }
            func release() {
                cond.lock()
                released = true
                cond.broadcast()
                cond.unlock()
            }
        }
        let gate = Gate()
        let entered = Gate()
        h.validateFocus = { _, _ in
            if gate.fireOnce() {
                entered.fire()
                gate.waitRelease(5)
            }
            return true
        }
        h.resolveFocus = { _ in ("remote", true) }
        let recorded = ObservationBox()
        h.recordFocus = { host, sid, at, initial in
            if host != "remote" {
                XCTFail("host = \(host)")
            }
            recorded.push((sid, at, initial))
        }
        let stop = h.startFocusWorker(CancelToken())
        let at = Date().addingTimeInterval(-3600)
        func send(_ sid: String, _ n: Int, _ initial: Bool) {
            do {
                _ = try h.observeFocus(Array(observation(sid, 123, at.addingTimeInterval(TimeInterval(n)), initial).utf8))
            } catch {
                XCTFail("\(error)")
            }
        }
        send("session:first", 0, true)
        _ = waitFor(2, { entered.isFired }, "focus worker stalled")
        send("session:second", 1, false)
        send("session:third", 2, false)
        send("session:third", 2, false) // Duplicate.
        send("session:third", 1, false) // Older report for the same session.
        gate.release()
        let expected = [("session:first", 0, true), ("session:second", 1, false), ("session:third", 2, false)]
        for (i, want) in expected.enumerated() {
            guard let got = recorded.pop(timeout: 2) else { break }
            if got.sid != want.0 || !dateClose(got.at, at.addingTimeInterval(TimeInterval(want.1))) || got.initial != want.2 {
                XCTFail("observation \(i) = \(got.sid) initial=\(got.initial)")
            }
        }
        // Stop joins the worker; there must be no duplicate writes left behind.
        stop()
        if recorded.count != 0 {
            XCTFail("duplicate writes = \(recorded.count)")
        }
    }

    func testFocusQueueBoundAndNewest() {
        let w = FocusWorker()
        let at = Date().addingTimeInterval(-3600)
        for i in 1...300 {
            w.enqueue(FocusObservation(sid: "session:focus", pid: i, at: at.addingTimeInterval(TimeInterval(i)), initial: false, origin: false))
        }
        if w.pendingCount != focusQueueLimit || w.latestCount > 128 {
            XCTFail("unbounded queue: \(w.pendingCount)/\(w.latestCount)")
        }
        if w.lastPendingPID != 300 {
            XCTFail("newest observation lost")
        }
    }

    func testFocusInvalidPayload() throws {
        let h = recencyHandler(env)
        let payloads = [
            "{}",
            "{\"session_id\":\"short\",\"client_pid\":\"1\",\"observed_at\":\"bad\"}",
            observation("session:ok", -1, Date(), false),
            observation("session:ok", 1, Date().addingTimeInterval(3600), false),
            observation("session:bad id", 1, Date(), false),
        ]
        for p in payloads {
            do {
                _ = try h.observeFocus(Array(p.utf8))
                XCTFail("accepted \(p)")
            } catch {
                // expected rejection
            }
        }
    }

    func testFocusRejectPIDAndAmbiguousSession() {
        for validPID in [false, true] {
            subtest(String(validPID), {
                let h = recencyHandler(env)
                h.launcher.items = [
                    LauncherItem(kind: "session", id: "session:duplicate", sessionID: "session:duplicate", host: Rex.localHostLabel, local: true),
                    LauncherItem(kind: "session", id: "session:duplicate", sessionID: "session:duplicate", host: "remote"),
                ]
                final class Flag: @unchecked Sendable {
                    private let cond = NSCondition()
                    private var fired = false
                    func fire() {
                        cond.lock()
                        fired = true
                        cond.broadcast()
                        cond.unlock()
                    }
                    var isFired: Bool {
                        cond.lock()
                        defer { cond.unlock() }
                        return fired
                    }
                }
                let validated = Flag()
                h.validateFocus = { _, _ in
                    validated.fire()
                    return validPID
                }
                if !validPID {
                    h.resolveFocus = { _ in
                        XCTFail("session resolution ran before PID validation")
                        return ("", false)
                    }
                }
                let stop = h.startFocusWorker(CancelToken())
                do {
                    _ = try h.observeFocus(Array(observation("session:duplicate", 123, Date().addingTimeInterval(-1), true).utf8))
                } catch {
                    XCTFail("\(error)")
                }
                _ = waitFor(2, { validated.isFired }, "focus worker stalled")
                stop()
            })
        }
    }

    func testFocusCachedCrossHostIdentity() throws {
        let h = recencyHandler(env)
        h.launcher.items = [LauncherItem(kind: "session", id: "session:remote", sessionID: "session:remote", host: "remote")]
        let (host, ok) = h.resolveFocusHost("session:remote")
        if host != "remote" || !ok {
            XCTFail("host = \(host)/\(ok)")
        }
    }

    func testFocusNativeMembershipNotAttachments() throws {
        let h = recencyHandler(env)
        let dir = makeTempDir()
        env.set("PATH", dir + ":" + (env.get("PATH") ?? ""))
        let script = #"""
        #!/bin/sh
        case "$*" in
         'ls --json') echo '{"sessions":[{"session_id":"session:local"},{"session_id":"session:duplicate"}]}' ;;
         'api call hosts.list') echo '{"hosts":[{"label":"remote"}]}' ;;
         '-S remote --timeout 2s ls --json') echo '{"sessions":[{"session_id":"session:remote"},{"session_id":"session:duplicate"}]}' ;;
         *) exit 1 ;;
        esac
        """#
        try put(dir + "/rex", script)
        let table: [(sid: String, host: String, ok: Bool)] = [
            ("session:local", "", true),
            ("session:remote", "remote", true),
            ("session:duplicate", "", false),
            ("session:attached-only", "", false),
        ]
        for tt in table {
            let (host, ok) = h.resolveFocusHost(tt.sid)
            if host != tt.host || ok != tt.ok {
                XCTFail("\(tt.sid) = \(host)/\(ok)")
            }
        }
    }

    func testFocusVisitDoesNotReloadRanks() throws {
        let h = recencyHandler(env)
        h.ranks = SessionRecency(["\u{0}session:old": 0])
        h.loadRecency = {
            XCTFail("visit reloaded ranks")
            return SessionRecency()
        }
        h.validateFocus = { _, _ in true }
        h.resolveFocus = { _ in ("", true) }
        let written = ObservationBox()
        h.recordFocus = { _, _, _, initial in
            written.push(("", Date(), initial))
        }
        let stop = h.startFocusWorker(CancelToken())
        let at = Date().addingTimeInterval(-3600)
        do {
            _ = try h.observeFocus(Array(observation("session:observed", 123, at, true).utf8))
        } catch {
            XCTFail("\(error)")
        }
        let recorded = written.pop(timeout: 2)
        if recorded?.initial != true {
            XCTFail("initial flag lost")
        }
        if h.ranks.rank("", "session:old") != 0 {
            XCTFail("ranks changed")
        }
        stop()
    }

    func testFocusNativeCancellation() throws {
        let dir = makeTempDir()
        env.set("PATH", dir + ":" + (env.get("PATH") ?? ""))
        try put(dir + "/rex", "#!/bin/sh\nexec sleep 30\n")
        let deadline = Date()
        // 50ms budget mirrors Go's context.WithTimeout.
        let result = focusRead(deadline: deadline.addingTimeInterval(0.05), args: ["ls", "--json"])
        if result != nil {
            XCTFail("cancelled listing succeeded")
        }
        if Date().timeIntervalSince(deadline) > 1 {
            XCTFail("native child did not stop on cancellation")
        }
    }

    func testFocusSubscribeReloadsRanks() throws {
        let h = recencyHandler(env)
        let dir = makeTempDir()
        env.set("PATH", dir + ":" + (env.get("PATH") ?? ""))
        try put(dir + "/rex", "#!/bin/sh\nexit 1\n")
        let loads = Counter()
        h.loadRecency = {
            let n = loads.add()
            return SessionRecency(["\u{0}session:shared": n])
        }
        for i in 1...2 {
            let output = DataOutput()
            try h.serve(input: DataInput("{\"id\":1,\"method\":\"events.subscribe\",\"params\":{\"enabled\":true}}"), output: output)
            if h.ranks.rank("", "session:shared") != i {
                XCTFail("warm reopen did not reload: \(h.ranks.rank("", "session:shared")) want \(i)")
            }
        }
    }
}
