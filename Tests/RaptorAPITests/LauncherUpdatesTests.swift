import Foundation
import RaptorCatalog
import RaptorLauncherupdate
import RaptorRex
import XCTest
@testable import RaptorAPI

final class LauncherUpdatesTests: APITestCase {
    func testCreatedSessionVisibleOnFirstWarmRead() throws {
        let cache = makeTempDir()
        // Fake rex: sessions.create must never reach a real Rex install.
        let stub = makeTempDir()
        // The scan must lag the mutation: an instant completed scan would
        // legitimately supersede the creation overlay.
        try "#!/bin/sh\ncase \"$*\" in\n  *'new --json'*) echo '{\"session_id\":\"new-session\"}' ;;\n  *'ls --json'*) sleep 2; echo '{\"sessions\":[]}' ;;\n  *) echo '{}' ;;\nesac\n"
            .write(toFile: stub + "/rex", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub + "/rex")
        env.set("PATH", stub + ":" + (env.get("PATH") ?? ""))
        env.set("XDG_CACHE_HOME", cache)
        // A snapshot whose scan started before the creation cannot know about it.
        let h = Handler(ctx: Ctx(session: "origin"), cfg: .default())
        let started = Date()
        h.commitLauncherAt(
            [LauncherItem(kind: "session", id: "origin", sessionID: "origin", label: "Origin", local: true)],
            [HostHeader(label: "This Mac", local: true, reachable: true)], started)

        // The mutation records only an authoritative Rex result. It must appear on
        // the very next warm read, without waiting for a fresh multi-host scan.
        Launcherupdate.record(Session(id: "new-session", label: "new-worktree", host: "This Mac", local: true, path: "/wt/new"))
        let output = DataOutput()
        try h.serve(input: DataInput("{\"id\":1,\"method\":\"sessions\",\"params\":{\"query\":\"\"}}"), output: output)
        let response = decodeWire(output.text.trimmingCharacters(in: .whitespacesAndNewlines))
        let resultDict = try jsonDict(response.result ?? "{}")
        let items = resultDict["items"] as? [[String: Any]] ?? []
        var created: [String: Any]?
        for item in items where item["session_id"] as? String == "new-session" {
            created = item
        }
        if created == nil || created?["label"] as? String != "new-worktree" || created?["is_local"] as? Bool != true {
            XCTFail("first warm read lost the created session: \(items)")
        }

        XCTAssertEqual(created?["path"] as? String, "new-session",
                       "Creation overlays must include the session identity as path for native decoding")

        // The mutation response carries the same authoritative rows for native
        // clients to publish before hiding.
        output.reset()
        try h.serve(input: DataInput("{\"id\":2,\"method\":\"sessions.create\",\"params\":{\"host\":\"\",\"dir\":\"/wt/new\"}}"), output: output)
        let mutation = decodeWire(output.text.trimmingCharacters(in: .whitespacesAndNewlines))
        let mutationDict = (try jsonDict(mutation.result ?? "{}"))
        let sessionID = mutationDict["session_id"] as? String ?? ""
        let launcherItems = mutationDict["launcher_items"] as? [[String: Any]] ?? []
        if sessionID.isEmpty {
            XCTFail("sessions.create result changed shape: \(output.text)")
        }
        var found = false
        for item in launcherItems where item["session_id"] as? String == "new-session" {
            found = true
        }
        if !found {
            XCTFail("mutation response must include the created row: \(launcherItems)")
        }
        let createdRow = launcherItems.first { $0["session_id"] as? String == "new-session" }
        XCTAssertEqual(createdRow?["path"] as? String, "new-session",
                       "Mutation responses must include path before the native client hides the picker")
    }

    func testOverlayDoesNotResurrectAfterAuthoritativeScan() throws {
        let cache = makeTempDir()
        env.set("XDG_CACHE_HOME", cache)
        Launcherupdate.record(Session(id: "gone", label: "gone", host: "This Mac", local: true, path: "/wt/gone"))
        let created = Date()

        // A completed scan started after the creation owns the list. The overlay
        // must not re-add a session that scan no longer reports.
        let h = Handler(ctx: Ctx(session: "origin"), cfg: .default())
        h.commitLauncherAt(
            [LauncherItem(kind: "session", id: "origin", sessionID: "origin", label: "Origin", local: true)],
            [HostHeader(label: "This Mac", local: true, reachable: true)], created.addingTimeInterval(60))

        let output = DataOutput()
        try h.serve(input: DataInput("{\"id\":1,\"method\":\"sessions\",\"params\":{\"query\":\"\"}}"), output: output)
        if output.text.contains("\"gone\"") {
            XCTFail("authoritative scan result was resurrected: \(output.text)")
        }
    }

    func testLatePreCreationScanKeepsCreatedRow() throws {
        let cache = makeTempDir()
        env.set("XDG_CACHE_HOME", cache)
        let h = Handler(ctx: Ctx(session: "origin"), cfg: .default())
        let started = Date()
        // The creation lands while a scan is in flight; the worker then publishes
        // rows that predate it. The warm cache must still expose the session.
        // (Go's RFC3339Nano keeps nanoseconds; Launcherupdate.encodeDate truncates
        // to milliseconds, so the creation must land a whole millisecond later.)
        usleep(5_000)
        Launcherupdate.record(Session(id: "late", label: "late", host: "This Mac", local: true, path: "/wt/late"))
        h.commitLauncherAt(
            [LauncherItem(kind: "session", id: "origin", sessionID: "origin", label: "Origin", local: true)],
            [HostHeader(label: "This Mac", local: true, reachable: true)], started)

        let output = DataOutput()
        try h.serve(input: DataInput("{\"id\":1,\"method\":\"sessions\",\"params\":{\"query\":\"\"}}"), output: output)
        if !output.text.contains("\"late\"") {
            XCTFail("in-flight pre-creation scan dropped a created session: \(output.text)")
        }
        // The on-disk cache is overlaid too, so a restarted resident host and the
        // standalone CLI see the same rows on their first read.
        let data = try readFile(cache + "/raptor/launcher-cache.json")
        if data.contains("\"late\"") {
            XCTFail("overlay must stay a read-time merge, not mutate the underlying cache")
        }
    }
}
