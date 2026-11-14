import XCTest
@testable import RaptorRex

final class RecencyTests: XCTestCase {
    func readRecencyTest() throws -> RecencyDocument {
        let (doc, _, error) = Rex.readRecency(Rex.recencyPath(), Date())
        if let error {
            throw error
        }
        return doc
    }

    func testRecencyOrderingAndRestore() throws {
        isolateRecency()
        let now = Date()
        let start = now.addingTimeInterval(-60)
        func record(_ host: String, _ id: String, _ at: Date, _ initial: Bool) throws {
            try Rex.recordSessionVisit(host, id, at, initial, now, start)
        }
        try record("", "session:a", now.addingTimeInterval(-10), false)
        let snapshot = Rex.loadSessionRecency()
        try record("remote", "session:a", now.addingTimeInterval(-8), false)
        try record("This Mac", "session:b", now.addingTimeInterval(-5), false)
        // Delayed reads do not undo the confirmed local choice, even with later
        // timestamps for an initial read delivered after a confirmed command.
        try record("", "session:a", now.addingTimeInterval(-9), false)
        try record("", "session:a", now.addingTimeInterval(-1), true)
        try record("", "session:b", now.addingTimeInterval(-20), false)
        let ranks = Rex.loadSessionRecency()
        XCTAssertEqual(ranks.rank("", "session:b"), 0)
        XCTAssertEqual(ranks.rank("remote", "session:a"), 1)
        XCTAssertEqual(ranks.rank(Rex.localHostLabel, "session:a"), 2)
        XCTAssertEqual(snapshot.rank("", "session:a"), 0)
        XCTAssertEqual(snapshot.rank("", "session:b"), Int.max, "snapshot changed")
        XCTAssertEqual(ranks.rank("other", "session:a"), Int.max, "host keys collided")
        let doc = try readRecencyTest()
        XCTAssertEqual(doc.visits.count, 3)
        // Go compares exact times; the Swift round-trip stores sub-nanosecond
        // precision through RFC3339, so compare with a microsecond tolerance.
        XCTAssertLessThan(abs(doc.visits[0].at.timeIntervalSince(now.addingTimeInterval(-5))), 1e-6, "restored: \(doc)")
        let attrs = try FileManager.default.attributesOfItem(atPath: Rex.recencyPath())
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        XCTAssertEqual(perms, 0o600, "history permissions: \(perms)")
    }

    func testRecencyInitialRestoredAndCrossProcessBarrier() throws {
        isolateRecency()
        let now = Date()
        let start = now.addingTimeInterval(-60)
        try Rex.recordSessionVisit("", "session:restored", start.addingTimeInterval(-60), false, now, start)
        try Rex.recordSessionVisit("", "session:initial", start.addingTimeInterval(1), true, now, start)
        XCTAssertEqual(Rex.loadSessionRecency().rank("", "session:initial"), 0, "initial did not reconcile restored history")
        // This also works after another process writes the confirmation: the
        // barrier is the persisted timestamp, not just a process-local boolean.
        try Rex.recordSessionVisit("", "session:confirmed", start.addingTimeInterval(2), false, now, start)
        try Rex.recordSessionVisit("", "session:queued", start.addingTimeInterval(3), true, now, start)
        XCTAssertEqual(Rex.loadSessionRecency().count, 3)
        XCTAssertEqual(Rex.loadSessionRecency().rank("", "session:confirmed"), 0, "initial replaced confirmed selection")
        // Another host's focus has a separate initial-read barrier.
        try Rex.recordSessionVisit("remote", "session:remote", start.addingTimeInterval(4), true, now, start)
        XCTAssertEqual(Rex.loadSessionRecency().rank("remote", "session:remote"), 0, "hosts not scoped")
    }

    func testRecencyValidationAndTrimming() throws {
        isolateRecency()
        let now = Date()
        let cases: [(String, String, Date)] = [
            ("", "short-fixture", now), ("", "session:", now), ("", "session:a\u{00}b", now),
            ("bad\u{00}host", "session:a", now), ("", "session:a", Rex.zeroTime),
            ("", "session:a", now.addingTimeInterval(3600)), ("", "session:a", Date(timeIntervalSince1970: -1)),
        ]
        for (host, id, at) in cases {
            try Rex.recordSessionVisit(host, id, at, false, now, now)
        }
        XCTAssertEqual(Rex.loadSessionRecency().count, 0, "invalid visit saved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Rex.recencyPath()), "invalid input created history")
        try Rex.recordSessionVisit(" This Mac ", " session:trimmed ", now.addingTimeInterval(-1), false)
        XCTAssertEqual(Rex.loadSessionRecency().rank("", "session:trimmed"), 0, "trim failed")
        try Rex.recordSessionVisit("Work Mac", "session:spaced-host", now, false)
        XCTAssertEqual(Rex.loadSessionRecency().rank("Work Mac", "session:spaced-host"), 0, "valid Rex host labels with spaces must retain recency")
    }

    func testRecencyBounded() throws {
        isolateRecency()
        let now = Date()
        for i in 0..<(Rex.recencyLimit + 10) {
            try Rex.recordSessionVisit("", String(format: "session:%03d", i), now.addingTimeInterval(Double(i - Rex.recencyLimit - 10)), false, now, now)
        }
        let doc = try readRecencyTest()
        XCTAssertEqual(doc.visits.count, Rex.recencyLimit)
        XCTAssertEqual(doc.visits[0].sessionID, "session:265")
        XCTAssertEqual(doc.visits[255].sessionID, "session:010")
    }

    func testRecencyDamagedHistoryPreserved() throws {
        let inputs: [Any] = ["{", "", ["version": 99, "visits": []],
                             ["version": 1, "visits": [["session_id": "short"]]], NSNull()]
        for input in inputs {
            isolateRecency()
            let path = Rex.recencyPath()
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            let state: [String: Any] = ["version": 1, "session_pins": [Any](), "session_recency": input]
            let originalData = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
            try originalData.write(to: URL(fileURLWithPath: path))
            XCTAssertEqual(Rex.loadSessionRecency().count, 0, "damaged history loaded")
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), originalData, "read changed input")
            try Rex.recordSessionUse("", "session:new")
            let backups = (try? FileManager.default.contentsOfDirectory(atPath: (path as NSString).deletingLastPathComponent))?
                .filter { $0.contains("state.json.backup-") } ?? []
            XCTAssertEqual(backups.count, 1, "backups: \(backups)")
            let original = try Data(contentsOf: URL(fileURLWithPath: (path as NSString).deletingLastPathComponent + "/" + backups[0]))
            XCTAssertEqual(original, originalData, "backup")
            XCTAssertEqual(Rex.loadSessionRecency().rank("", "session:new"), 0, "did not recover")
        }
    }

    /// Go spawns subprocess writers via os.Args[0] -test.run; the Swift port
    /// cannot add a helper executable target, so the same lock/merge/rename path
    /// runs from concurrent in-process threads.
    func testRecencyConcurrentProcesses() throws {
        isolateRecency()
        let writers = 12
        DispatchQueue.concurrentPerform(iterations: writers) { i in
            // Contention can exceed the lock timeout on loaded CI runners;
            // writers retry, which keeps the merge semantics under test.
            for _ in 0..<30 {
                do {
                    try Rex.recordSessionUse("", "session:writer-\(i)")
                    return
                } catch {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        }
        XCTAssertEqual(Rex.loadSessionRecency().count, writers, "merged writers")
        let temps = (try? FileManager.default.contentsOfDirectory(atPath: (Rex.recencyPath() as NSString).deletingLastPathComponent))?
            .filter { $0.contains(".json.tmp-") } ?? []
        XCTAssertEqual(temps.count, 0, "temporary files remain: \(temps)")
    }

    func testRecencyProcessLockContention() throws {
        isolateRecency()
        let log = fakeRecencyRex()
        try Rex.recordSessionUse("", "session:existing")
        let recencyFile = Rex.recencyPath()
        let before = readTextFile(recencyFile)
        let lockPath = recencyFile + ".lock"
        let lockInfo = try FileManager.default.attributesOfItem(atPath: lockPath)[.systemFileNumber] as? UInt64

        // Hold the lock from a second open file description, the in-process
        // equivalent of Go's subprocess lock holder: flock(2) contention applies
        // across OFDs, and the holder keeps the lock until released below.
        let holdFd = open(lockPath, O_RDWR)
        XCTAssertGreaterThanOrEqual(holdFd, 0)
        XCTAssertEqual(flock(holdFd, LOCK_EX), 0)

        struct ContentionCase {
            let name: String
            let run: () throws -> Void
            let wantContention: Bool
        }
        let cases: [ContentionCase] = [
            ContentionCase(name: "RecordSessionUse", run: { try Rex.recordSessionUse("", "session:blocked") }, wantContention: true),
            ContentionCase(name: "Do", run: { try Rex.doAction(client: "client:test", action: "session.select", kv: "session_id=session:local") }, wantContention: false),
            ContentionCase(name: "DoOn", run: { try Rex.doOn("remote", "client:test", "session.select", kv: "session_id=session:remote") }, wantContention: false),
        ]
        for c in cases {
            let started = Date()
            do {
                try c.run()
                if c.wantContention {
                    XCTFail("\(c.name): expected lock contention")
                }
            } catch {
                if c.wantContention {
                    let code = (error as? POSIXError)?.code.rawValue
                    XCTAssertEqual(code, Int32(EWOULDBLOCK), "\(c.name): expected lock contention, got \(error)")
                } else {
                    XCTFail("\(c.name): optional history failed navigation: \(error)")
                }
            }
            XCTAssertLessThan(Date().timeIntervalSince(started), 1, "\(c.name): lock wait exceeded deadline")
        }
        let after = readTextFile(recencyFile)
        XCTAssertEqual(after, before, "contention changed history")
        let afterLockInfo = try FileManager.default.attributesOfItem(atPath: lockPath)[.systemFileNumber] as? UInt64
        XCTAssertEqual(lockInfo, afterLockInfo, "contention replaced the lock file")
        let calls = readTextFile(log)
        XCTAssertEqual(countOccurrences(calls, "\n"), 2, "expected two fake navigation calls: \(calls)")
        flock(holdFd, LOCK_UN)
        close(holdFd)
        try Rex.recordSessionUse("", "session:after-release")
        XCTAssertEqual(Rex.loadSessionRecency().count, 2, "history did not merge after lock release")
    }

    func testRecencyConcurrentGoroutines() throws {
        isolateRecency()
        DispatchQueue.concurrentPerform(iterations: 24) { i in
            do {
                try Rex.recordSessionUse("", "session:goroutine-\(i)")
            } catch {
                XCTFail("\(error)")
            }
            _ = Rex.loadSessionRecency()
        }
        XCTAssertEqual(Rex.loadSessionRecency().count, 24, "lost goroutine writes")
    }

    func testRecencyDoHooks() throws {
        isolateRecency()
        let log = fakeRecencyRex()
        setenvTemp("RECENCY_EXIT", "1")
        XCTAssertThrowsError(try Rex.doAction(client: "client:test", action: "session.select", kv: "session_id=session:failed"))
        XCTAssertThrowsError(try Rex.doOn("remote", "client:test", "session.select", kv: "session_id=session:failed"))
        XCTAssertEqual(Rex.loadSessionRecency().count, 0, "recorded failed actions")
        setenvTemp("RECENCY_EXIT", "0")
        try Rex.doAction(client: "client:test", action: "session.select", kv: "session_id=session:local")
        let visits = try readRecencyTest().visits
        XCTAssertEqual(visits.count, 1)
        XCTAssertEqual(visits[0].sessionID, "session:local", "expected one acknowledged visit: \(visits)")
        try Rex.doOn("remote", "client:test", "session.select", kv: "session_id=session:remote")
        try Rex.doAction(client: "client:test", action: "block.focus", kv: "session_id=session:not-selection")
        _ = try Rex.run("do", "session.select", "session_id=session:server-only")
        try Rex.doAction(client: "client:test", action: "session.select", kv: "session_id=fixture")
        // Repeated selections remain one visit.
        try Rex.doAction(client: "client:test", action: "session.select", kv: "session_id=session:local")
        XCTAssertEqual(Rex.loadSessionRecency().count, 2)
        XCTAssertEqual(Rex.loadSessionRecency().rank("", "session:local"), 0, "incorrect successful visits")
        let calls = readTextFile(log)
        XCTAssertEqual(countOccurrences(calls, "\n"), 8, "extra Rex calls: \(calls)")
        XCTAssertFalse(calls.contains("api call"), "extra Rex calls: \(calls)")
        // An optional history write error must not fail acknowledged navigation.
        try FileManager.default.createDirectory(atPath: Rex.recencyPath() + ".lock.blocked", withIntermediateDirectories: false)
        try FileManager.default.removeItem(atPath: Rex.recencyPath() + ".lock")
        try FileManager.default.moveItem(atPath: Rex.recencyPath() + ".lock.blocked", toPath: Rex.recencyPath() + ".lock")
        try Rex.doAction(client: "client:test", action: "session.select", kv: "session_id=session:optional")
    }

    func testValidateFocusClientPIDCancellation() throws {
        isolateRecency()
        let dir = testTempDir()
        writeExecutable(dir + "/rex", contents: "#!/bin/sh\nexec sleep 60\n")
        prependPATH(dir)
        let started = Date()
        XCTAssertFalse(Rex.validateFocusClientPIDContext(parentTimeout: 0.05, pid: 42), "shutdown did not cancel the native PID validator")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testValidateFocusClientPID() throws {
        isolateRecency()
        let log = fakeRecencyRex()
        struct PIDCase {
            let kind: String
            let principal: String
            let transport: String
            let state: String
            let pid: Int
            let want: Bool
        }
        let cases: [PIDCase] = [
            PIDCase(kind: "app", principal: "peer", transport: "unix", state: "connected", pid: 42, want: true),
            PIDCase(kind: "app", principal: "peer", transport: "unix", state: "", pid: 42, want: true),
            PIDCase(kind: "cli", principal: "peer", transport: "unix", state: "connected", pid: 42, want: false),
            PIDCase(kind: "app", principal: "tailscale", transport: "unix", state: "connected", pid: 42, want: false),
            PIDCase(kind: "app", principal: "peer", transport: "tcp", state: "connected", pid: 42, want: false),
            PIDCase(kind: "app", principal: "peer", transport: "unix", state: "lost", pid: 42, want: false),
            PIDCase(kind: "app", principal: "peer", transport: "unix", state: "connected", pid: 43, want: false),
            PIDCase(kind: "app", principal: "peer", transport: "unix", state: "connected", pid: 0, want: false),
        ]
        for c in cases {
            let payload: [String: Any] = ["clients": [[
                "info": ["kind": c.kind],
                "connection_state": c.state,
                "principal": ["kind": c.principal, "transport": c.transport, "pid": c.pid],
            ]]]
            let data = try JSONSerialization.data(withJSONObject: payload)
            setenvTemp("RECENCY_CLIENTS", String(data: data, encoding: .utf8)!)
            XCTAssertEqual(Rex.validateFocusClientPID(42), c.want, "\(c.kind) \(c.principal) \(c.transport) \(c.state) \(c.pid)")
        }
        setenvTemp("RECENCY_CLIENTS", "{")
        XCTAssertFalse(Rex.validateFocusClientPID(42))
        XCTAssertFalse(Rex.validateFocusClientPID(0))
        XCTAssertFalse(Rex.validateFocusClientPID(-1))
        setenvTemp("RECENCY_EXIT", "1")
        XCTAssertFalse(Rex.validateFocusClientPID(42), "accepted failed API call")
        let calls = readTextFile(log)
        for call in calls.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n") {
            XCTAssertEqual(String(call), "--autostart=false api call client.list {\"kinds\":[\"app\"]}", "unexpected call: \(call)")
        }
        XCTAssertEqual(Rex.loadSessionRecency().count, 0, "validation mutated history")
    }
}
