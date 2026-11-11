import Foundation
import RaptorCatalog
import RaptorConfig
import RaptorLauncherupdate
import RaptorPullrequest
import RaptorRex
import RaptorWorktree
import XCTest
@testable import RaptorAPI

/// setenv/unsetenv with recorded originals; mirrors Go's t.Setenv restore.
final class TestEnv {
    private var saved: [String: String?] = [:]
    private let teardowns: NSMutableArray = NSMutableArray()

    func addTeardown(_ block: @escaping () -> Void) {
        teardowns.add(block)
    }

    func runTeardowns() {
        for block in teardowns {
            (block as? () -> Void)?()
        }
        teardowns.removeAllObjects()
        restore()
    }

    private func record(_ name: String) {
        if saved[name] == nil {
            if let value = getenv(name) {
                saved[name] = .some(String(cString: value))
            } else {
                saved[name] = .some(nil)
            }
        }
    }

    func set(_ name: String, _ value: String) {
        record(name)
        setenv(name, value, 1)
    }

    func unset(_ name: String) {
        record(name)
        unsetenv(name)
    }

    func get(_ name: String) -> String? {
        guard let value = getenv(name) else { return nil }
        return String(cString: value)
    }

    func restore() {
        for (name, value) in saved {
            if let value {
                setenv(name, value, 1)
            } else {
                unsetenv(name)
            }
        }
        saved = [:]
    }
}

/// XCTestCase base that restores env vars between tests (Go's t.Setenv scope).
class APITestCase: XCTestCase {
    let env = TestEnv()

    override func setUp() {
        super.setUp()
        // Fixture tests stub zoxide through PATH, but the fd scan runs real
        // commands (find exists everywhere), so PATH stubs cannot intercept it.
        // Disable it wholesale: exact-row assertions must not see the operator's
        // home directory. Set it through TestEnv so tearDown restores it.
        env.set("RAPTOR_DISABLE_DIR_SCAN", "1")
    }

    func addTeardown(_ block: @escaping () -> Void) {
        env.addTeardown(block)
    }

    override func tearDown() {
        super.tearDown()
        env.runTeardowns()
    }
}

func makeTempDir() -> String {
    var base = NSTemporaryDirectory()
    while base.hasSuffix("/") { base.removeLast() }
    let dir = base + "/raptor-api-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// t.Run-style labeled failure reporting for table-driven cases.
func subtest(_ label: String, _ body: () throws -> Void) {
    do {
        try body()
    } catch {
        XCTFail("\(label): \(error)")
    }
}

func put(_ path: String, _ text: String, mode: Int = 0o700) throws {
    try FileManager.default.createDirectory(atPath: dirName(path), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data(text.utf8),
                                   attributes: [.posixPermissions: mode])
}

func readFile(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

func fileExists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
}

func dirName(_ path: String) -> String {
    (path as NSString).deletingLastPathComponent
}

/// Go's filepath.Dir behavior for plain absolute paths.
func goDir(_ path: String) -> String {
    dirName(path)
}

// MARK: - wire responses

struct WireResponse {
    var id: Int64 = 0
    var result: String?
    var error: String?
}

/// Decodes one NDJSON protocol line, keeping the raw result substring.
func decodeWire(_ line: String) -> WireResponse {
    var parser = JSONParser(line)
    guard let node = try? parser.parseTop(), case .object(let fields) = node.value else {
        return WireResponse()
    }
    var out = WireResponse()
    let bytes = Array(line.utf8)
    for (key, fieldNode) in fields {
        switch key {
        case "id":
            if case .number(let literal) = fieldNode.value {
                out.id = Int64(literal) ?? 0
            }
        case "result":
            out.result = String(decoding: bytes[fieldNode.start..<fieldNode.end], as: UTF8.self)
        case "error":
            if case .string(let s) = fieldNode.value {
                out.error = s
            }
        default:
            break
        }
    }
    return out
}

/// Raw key→value substrings of one protocol line (for event envelope checks).
func rawFields(_ line: String) -> [String: String] {
    var parser = JSONParser(line)
    guard let node = try? parser.parseTop(), case .object(let fields) = node.value else {
        return [:]
    }
    var out: [String: String] = [:]
    let bytes = Array(line.utf8)
    for (key, fieldNode) in fields {
        out[key] = String(decoding: bytes[fieldNode.start..<fieldNode.end], as: UTF8.self)
    }
    return out
}

func jsonDict(_ text: String) throws -> [String: Any] {
    let obj = try JSONSerialization.jsonObject(with: Data(text.utf8))
    return (obj as? [String: Any]) ?? [:]
}

// MARK: - client over pipes (Go's io.Pipe client helper)

/// A pipe client proves responses arrive before EOF and one backend survives all
/// calls, including validation and Git failures.
func makeClient(_ testCase: XCTestCase, _ h: Handler)
    -> (_ method: String, _ params: JS, _ check: ((String) throws -> Void)?) -> String {
    let requests = Pipe()
    let responses = Pipe()
    let input = PipeInput(requests)
    let output = PipeOutput(responses)
    final class Box: @unchecked Sendable {
        var error: Error?
    }
    let box = Box()
    let serveThread = Thread {
        do {
            try h.serve(input: input, output: output)
        } catch {
            box.error = error
        }
    }
    serveThread.name = "test-client-serve"
    serveThread.start()

    let feed = LineFeed()
    let readerThread = Thread {
        let reader = LineReader(PipeInput(responses))
        while true {
            do {
                let (line, _, eof) = try reader.next()
                if !line.isEmpty {
                    feed.push(LineFeed.Item(line: line, oversized: false, eof: eof, error: nil))
                }
                if eof { break }
            } catch {
                break
            }
        }
    }
    readerThread.name = "test-client-reader"
    readerThread.start()

    testCase.addTeardownBlock {
        try? requests.fileHandleForWriting.close()
        // Wait for serve to finish; a non-nil error fails the test like Go's cleanup.
        for _ in 0..<200 where serveThread.isExecuting {
            usleep(50_000)
        }
        if serveThread.isExecuting {
            XCTFail("serve did not observe EOF")
        }
        if let error = box.error {
            XCTFail("serve error: \(error)")
        }
        try? responses.fileHandleForReading.close()
    }

    var id: Int64 = 0
    return { method, params, check in
        id += 1
        let line = JS.object([
            ("id", .int(id)),
            ("method", .string(method)),
            ("params", params),
        ]).encode() + "\n"
        do {
            try requests.fileHandleForWriting.write(contentsOf: Data(line.utf8))
        } catch {
            XCTFail("write: \(error)")
            return ""
        }
        guard let data = feed.pop(timeout: 30)?.line else {
            XCTFail("no protocol output for \(method)")
            return ""
        }
        let res = decodeWire(String(decoding: data, as: UTF8.self))
        if res.id != id {
            XCTFail("id: got \(res.id) want \(id)")
        }
        if let error = res.error, !error.isEmpty {
            if res.result != nil {
                XCTFail("error response includes result")
            }
            return error
        }
        guard let result = res.result, result.hasPrefix("{") else {
            XCTFail("result must be object: \(res.result ?? "nil")")
            return ""
        }
        if let check {
            do {
                try check(result)
            } catch {
                XCTFail("\(error)")
            }
        }
        return ""
    }
}

// MARK: - result decode helpers

func decodeLauncherRows(_ resultJSON: String) throws -> [LauncherItem] {
    let dict = try jsonDict(resultJSON)
    let items = dict["items"] as? [[String: Any]] ?? []
    return items.map { row in
        LauncherItem(
            kind: row["kind"] as? String ?? "", id: row["id"] as? String ?? "",
            path: row["path"] as? String ?? "", sessionID: row["session_id"] as? String ?? "",
            label: row["label"] as? String ?? "", sessionLabel: row["session_label"] as? String ?? "",
            host: row["host"] as? String ?? "", active: row["active"] as? Bool ?? false,
            local: row["is_local"] as? Bool ?? false, pinned: row["is_pinned"] as? Bool ?? false,
            state: row["state"] as? String ?? "", working: row["working"] as? Bool ?? false)
    }
}

func decodeHostHeaders(_ resultJSON: String) throws -> [HostHeader] {
    let dict = try jsonDict(resultJSON)
    let hosts = dict["hosts"] as? [[String: Any]] ?? []
    return hosts.map {
        HostHeader(
            label: $0["label"] as? String ?? "", local: $0["local"] as? Bool ?? false,
            reachable: $0["reachable"] as? Bool ?? false, error: $0["error"] as? String ?? "")
    }
}

func decodeDirectoryRows(_ resultJSON: String) throws -> [Directory] {
    let dict = try jsonDict(resultJSON)
    let items = dict["items"] as? [[String: Any]] ?? []
    return items.map {
        Directory(
            path: $0["path"] as? String ?? "", label: $0["label"] as? String ?? "",
            pinned: $0["is_pinned"] as? Bool ?? false, state: $0["state"] as? String ?? "",
            working: $0["working"] as? Bool ?? false)
    }
}

func decodeTreeRows(_ resultJSON: String) throws -> (destinationRoot: String, repo: String, needsRepo: Bool,
    items: [(path: String, branch: String, isMain: Bool)], branches: [String], baseBranch: String,
    suggestedBranchPresent: Bool, suggestedBranch: String) {
    let dict = try jsonDict(resultJSON)
    let items = (dict["items"] as? [[String: Any]] ?? []).map {
        (path: $0["path"] as? String ?? "", branch: $0["branch"] as? String ?? "",
            isMain: $0["is_main"] as? Bool ?? false)
    }
    let suggested = dict["suggested_branch"] as? String
    return (
        destinationRoot: dict["destination_root"] as? String ?? "",
        repo: dict["repo"] as? String ?? "",
        needsRepo: dict["needs_repo"] as? Bool ?? false,
        items: items,
        branches: dict["branches"] as? [String] ?? [],
        baseBranch: dict["base_branch"] as? String ?? "",
        suggestedBranchPresent: suggested != nil,
        suggestedBranch: suggested ?? ""
    )
}

// MARK: - fixtures

func fixtureRepo(_ env: TestEnv) throws -> String {
    isolateWorktrunk(env)
    let repo = makeTempDir() + "/.sample"
    try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: false)
    for args in [
        ["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.com"],
        ["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "initial"],
    ] {
        _ = try WorktreeKit.gitOut(dir: repo, args: args)
    }
    return WorktreeKit.repoRoot(dir: repo)
}

func fakeTool(_ env: TestEnv, _ name: String, _ script: String) throws {
    let bin = makeTempDir()
    try put(bin + "/" + name, "#!/bin/sh\n" + script)
    env.set("PATH", bin + ":" + (env.get("PATH") ?? ""))
}

/// Each fixture uses a private Worktrunk config and destination. Tests must not
/// read user hooks or create worktrees in the user's configured root.
func isolateWorktrunk(_ env: TestEnv) {
    let root = makeTempDir()
    let empty = root + "/empty.toml"
    FileManager.default.createFile(atPath: empty, contents: Data())
    env.set("WORKTRUNK_CONFIG_PATH", empty)
    env.set("WORKTRUNK_SYSTEM_CONFIG_PATH", empty)
    env.set("WORKTRUNK_PROJECT_CONFIG_PATH", root + "/no-project.toml")
    env.set("WORKTRUNK_WORKTREE_PATH", root + "/trees/{{ repo }}/{{ branch | sanitize }}")
}

// MARK: - shared handler fixtures

func warmHandler() -> Handler {
    let h = Handler(ctx: Ctx(session: "session:a", block: "block:a"), cfg: .default())
    h.activityLoaded = true
    h.launcherLoaded = true
    h.activityAgents = [AgentEntry(label: "Old agent", sessionID: "session:a", blockID: "block:a")]
    h.launcher.items = [
        LauncherItem(kind: "session", id: "session:b", sessionID: "session:b", label: "Other", local: true),
        LauncherItem(kind: "session", id: "session:a", sessionID: "session:a", label: "Old", local: true),
    ]
    return h
}

func waitSnapshot(_ h: Handler) {
    h.cacheMu.lock()
    let done = h.refreshDone
    h.cacheMu.unlock()
    guard let done else {
        XCTFail("snapshot worker did not finish")
        return
    }
    done.wait(until: Date().addingTimeInterval(10))
    if !done.isFired {
        XCTFail("snapshot worker did not finish")
    }
}

/// Waits for one signal with a test timeout; fails loudly when stalled.
func waitFor(_ timeout: TimeInterval, _ poll: () -> Bool, _ failMessage: String) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if poll() { return true }
        usleep(10_000)
    }
    XCTFail(failMessage)
    return false
}

// MARK: - snapshots machinery load hooks

extension Handler {
    /// Convenience mirroring Go's h.call(method, params) in tests.
    func call(_ method: String, _ params: String) -> (MethodResult?, Error?) {
        call(CancelToken(), method, Array(params.utf8))
    }

    func callJSON(_ method: String, _ params: JS) -> (MethodResult?, Error?) {
        call(CancelToken(), method, Array(params.encode().utf8))
    }
}

// MARK: - recency test fixtures

func recencyHandler(_ env: TestEnv) -> Handler {
    env.set("XDG_CACHE_HOME", makeTempDir())
    let h = Handler(ctx: Ctx(), cfg: .default())
    h.recordFocus = { _, _, _, _ in
        XCTFail("unexpected history write")
    }
    return h
}

func sessionRows(_ h: Handler, _ query: String) -> [String] {
    let (value, error) = h.call("sessions", "{\"query\":\"\(query)\"}")
    if let error {
        XCTFail("\(error)")
        return []
    }
    guard case .sessions(_, let items, _, _, _) = value else {
        XCTFail("unexpected sessions result")
        return []
    }
    return items.map { "\($0.host)/\($0.sessionID)" }
}

func observation(_ sid: String, _ pid: Int, _ at: Date, _ initial: Bool) -> String {
    let params = JS.object([
        ("session_id", .string(sid)),
        ("client_pid", .string(String(pid))),
        ("observed_at", .string(formatRFC3339Nano(at))),
        ("initial", .bool(initial)),
    ])
    return params.encode()
}

func dateClose(_ a: Date, _ b: Date) -> Bool {
    abs(a.timeIntervalSince(b)) < 0.000001
}

/// Thread-safe queue of recorded focus observations.
final class ObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(sid: String, at: Date, initial: Bool)] = []

    func push(_ item: (sid: String, at: Date, initial: Bool)) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    func pop(timeout: TimeInterval) -> (sid: String, at: Date, initial: Bool)? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            lock.lock()
            if !items.isEmpty {
                let first = items.removeFirst()
                lock.unlock()
                return first
            }
            lock.unlock()
            if Date() >= deadline {
                XCTFail("focus worker stalled")
                return nil
            }
            usleep(10_000)
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }
}

/// Counting signal with buffer semantics for load hooks (Go's buffered chan).
final class SignalQueue {
    private let cond = NSCondition()
    private var items: [Int] = []

    func send(_ n: Int) {
        cond.lock()
        items.append(n)
        cond.signal()
        cond.unlock()
    }

    /// Returns one item within the timeout.
    func waitOne(_ timeout: TimeInterval) -> Int? {
        cond.lock()
        let deadline = Date().addingTimeInterval(timeout)
        while items.isEmpty {
            if !cond.wait(until: deadline) {
                break
            }
        }
        let item = items.isEmpty ? nil : items.removeFirst()
        cond.unlock()
        if item == nil {
            XCTFail("expected signal did not arrive")
        }
        return item
    }

    func tryOne(_ timeout: TimeInterval) -> Int? {
        cond.lock()
        let deadline = Date().addingTimeInterval(timeout)
        while items.isEmpty {
            if !cond.wait(until: deadline) {
                break
            }
        }
        let item = items.isEmpty ? nil : items.removeFirst()
        cond.unlock()
        return item
    }
}

/// Atomic counter for load hooks.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func add(_ delta: Int = 1) -> Int {
        lock.lock()
        value += delta
        let current = value
        lock.unlock()
        return current
    }

    func load() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Notification recorder (Go's notify hooks appending to channels).
final class NotificationBox: @unchecked Sendable {
    private let cond = NSCondition()
    private var items: [String] = []

    func push(_ item: String) {
        cond.lock()
        items.append(item)
        cond.signal()
        cond.unlock()
    }

    /// Returns true when an item arrived before the timeout.
    func waitOne(_ timeout: TimeInterval) -> String? {
        cond.lock()
        let deadline = Date().addingTimeInterval(timeout)
        while items.isEmpty {
            if !cond.wait(until: deadline) {
                break
            }
        }
        let item = items.isEmpty ? nil : items.removeFirst()
        cond.unlock()
        return item
    }

    func popIfAvailable() -> String? {
        cond.lock()
        defer { cond.unlock() }
        return items.isEmpty ? nil : items.removeFirst()
    }

    var count: Int {
        cond.lock()
        defer { cond.unlock() }
        return items.count
    }
}
