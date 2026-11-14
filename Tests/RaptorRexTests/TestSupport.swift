import Foundation
import XCTest
@testable import RaptorRex

// Shared helpers mirroring the Go test utilities (t.TempDir, t.Setenv,
// os.WriteFile of fake executables on PATH).

func rexTempDir() -> String {
    let dir = NSTemporaryDirectory() + "raptor-rex-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

func getEnvValue(_ key: String) -> String? {
    getenv(key).map { String(cString: $0) }
}

func setEnvValue(_ key: String, _ value: String?) {
    if let value {
        setenv(key, value, 1)
    } else {
        unsetenv(key)
    }
}

func readTextFile(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

func countOccurrences(_ haystack: String, _ needle: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var range = haystack.startIndex..<haystack.endIndex
    while let found = haystack.range(of: needle, options: [], range: range) {
        count += 1
        range = found.upperBound..<haystack.endIndex
    }
    return count
}

extension XCTestCase {
    /// t.Setenv: sets the variable and restores the previous value at teardown.
    func setenvTemp(_ key: String, _ value: String?) {
        let old = getEnvValue(key)
        setEnvValue(key, value)
        addTeardownBlock { setEnvValue(key, old) }
    }

    /// t.TempDir.
    func testTempDir() -> String {
        rexTempDir()
    }

    /// paths.CacheDir() with XDG_CACHE_HOME as set by isolateRecency/fakeRex.
    func testCacheDir() -> String {
        let dir = (getEnvValue("XDG_CACHE_HOME") ?? NSTemporaryDirectory()) + "/raptor"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func writeExecutable(_ path: String, contents: String) {
        try! Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        chmod(path, 0o755)
    }

    /// Prepends dir to PATH for the duration of the test.
    func prependPATH(_ dir: String) {
        let current = getEnvValue("PATH") ?? ""
        setenvTemp("PATH", dir + ":" + current)
    }

    /// The fake rex from rex_test.go: logs every invocation and answers the
    /// session/client listings with canned payloads driven by REX_TEST_FAIL.
    @discardableResult
    func fakeRex() -> String {
        let dir = testTempDir()
        setenvTemp("HOME", testTempDir())
        setenvTemp("XDG_CACHE_HOME", testTempDir())
        prependPATH(dir)
        let log = dir + "/calls"
        setenvTemp("REX_TEST_LOG", log)
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$REX_TEST_LOG"
        case "$*" in
          *'local response, listError'*)
            case "$REX_TEST_FAIL" in
              list|malformed|select) echo 'history request failed' >&2; exit 1;;
            esac
            printf '%s\\n' "${REX_TEST_SELECTED:-session:previous}";;
          *session.select*)
            if [ "$REX_TEST_FAIL" = select ]; then echo 'selection failed' >&2; exit 1; fi;;
          *client.list*)
            if [ "$REX_TEST_FAIL" = client ]; then echo '{"clients":[]}'; exit 0; fi
            echo '{"clients":[{"client_id":"client:app","info":{"kind":"app","label":"my-mac"}}]}';;
          *'ls --json')
            if [ "$REX_TEST_FAIL" = list ]; then echo 'host unavailable' >&2; exit 1; fi
            if [ "$REX_TEST_FAIL" = malformed ]; then echo '{}'; exit 0; fi
            echo '{"sessions":[{"session_id":"session:previous"},{"session_id":"session:current"}]}';;
        esac
        """
        writeExecutable(dir + "/rex", contents: script)
        return log
    }

    func seedHistory(_ host: String, _ ids: String...) throws {
        for (i, id) in ids.enumerated() {
            try Rex.recordSessionVisit(host, id, Date().addingTimeInterval(Double(i - ids.count) * 60), false)
        }
    }

    /// isolateRecency from recency_test.go.
    func isolateRecency() {
        let dir = testTempDir()
        setenvTemp("HOME", dir)
        setenvTemp("XDG_CACHE_HOME", dir + "/cache")
    }

    /// fakeRexWithHosts from hosts_test.go.
    @discardableResult
    func fakeRexWithHosts(_ script: String) -> String {
        let dir = testTempDir()
        prependPATH(dir)
        writeExecutable(dir + "/rex", contents: script)
        return dir
    }

    /// fakeHostDiscovery from hosts_resolution_test.go.
    @discardableResult
    func fakeHostDiscovery() -> String {
        let log = testTempDir() + "/calls"
        setenvTemp("HOST_DISCOVERY_LOG", log)
        setenvTemp("HOST_DISCOVERY_CLIENTS", "{\"clients\":[]}")
        setenvTemp("HOST_DISCOVERY_TARGET", "{\"results\":[]}")
        setenvTemp("HOST_DISCOVERY_STATUS", "{}")
        fakeRexWithHosts("""
        #!/bin/sh
        printf '%s\\n' "$*" >> "$HOST_DISCOVERY_LOG"
        if [ "$1" = '-S' ]; then
          [ "$2" = 'remote' ] || exit 1
          shift 2
        fi
        case "$*" in
          'api call client.list {"kinds":["app"]}') printf '%s\\n' "$HOST_DISCOVERY_CLIENTS" ;;
          'api call target.resolve '*) printf '%s\\n' "$HOST_DISCOVERY_TARGET" ;;
          'api call server.status') printf '%s\\n' "$HOST_DISCOVERY_STATUS" ;;
          *) exit 1 ;;
        esac
        """)
        return log
    }

    func discoveryCalls(_ log: String) -> String {
        readTextFile(log)
    }

    /// fakeRecencyRex from recency_test.go.
    @discardableResult
    func fakeRecencyRex() -> String {
        let dir = testTempDir()
        let log = dir + "/calls"
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$RECENCY_CALLS"
        if [ "$1" = --autostart=false ]; then shift; fi
        if [ "$1" = api ]; then printf '%s\\n' "$RECENCY_CLIENTS"; fi
        exit "${RECENCY_EXIT:-0}"
        """
        writeExecutable(dir + "/rex", contents: script)
        prependPATH(dir)
        setenvTemp("RECENCY_CALLS", log)
        setenvTemp("RECENCY_EXIT", "0")
        return log
    }

    /// fakeEventCLI from events_test.go.
    @discardableResult
    func fakeEventCLI(_ script: String) -> String {
        let dir = testTempDir()
        prependPATH(dir)
        writeExecutable(dir + "/rex", contents: "#!/bin/sh\n" + script)
        return dir
    }
}
