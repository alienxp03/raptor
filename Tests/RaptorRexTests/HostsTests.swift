import XCTest
@testable import RaptorRex

final class HostsTests: XCTestCase {
    func testHostsListsLocalFirstThenRemoteLabels() throws {
        fakeRexWithHosts("""
        #!/bin/sh
        case "$*" in
          'api call hosts.list') echo '{"hosts":[{"id":"host:1","label":"hades"},{"id":"host:2","label":"azuanz.local"}]}' ;;
          *) exit 1 ;;
        esac
        """)
        let hosts = Rex.hosts()
        XCTAssertEqual(hosts.count, 3)
        XCTAssertTrue(hosts[0].local)
        XCTAssertEqual(hosts[0].label, Rex.localHostLabel)
        XCTAssertEqual(hosts[1].label, "hades")
        XCTAssertFalse(hosts[1].local)
        // Duplicate local labels collapse.
        XCTAssertEqual(hosts[2].label, "azuanz.local")
    }

    func testHostsKeepsLocalWhenListingFails() throws {
        fakeRexWithHosts("#!/bin/sh\nexit 1\n")
        let hosts = Rex.hosts()
        XCTAssertEqual(hosts.count, 1)
        XCTAssertTrue(hosts[0].local)
    }

    func testSessionGroupsOrderActivityAndUnreachable() throws {
        let dir = testTempDir()
        prependPATH(dir)
        let script = """
        #!/bin/sh
        case "$*" in
          'api call hosts.list') echo '{"hosts":[{"id":"host:1","label":"hades"},{"id":"host:2","label":"gone"}]}' ;;
          'ls --json') echo '{"sessions":[{"session_id":"a","label":"local"},{"session_id":"b","label":"origin"}]}' ;;
          '-S hades --timeout 3s ls --json') echo '{"sessions":[{"session_id":"r1","label":"wispy-brook"}]}' ;;
          '-S gone --timeout 3s ls --json') echo 'down' >&2; exit 255 ;;
          'do'*) echo '{"sessions":[]}' ;;
          '-S hades --timeout 4s do'*) echo '{"sessions":[{"session_id":"r1","active_window_id":"w","windows":[{"window_id":"w","focused_block_id":"b","blocks":[{"block_id":"b","records":[{"app":"pi","state":"working"}]}]}]}]}' ;;
        esac
        """
        writeExecutable(dir + "/rex", contents: script)
        let groups = Rex.sessionGroups("b", nil)
        XCTAssertEqual(groups.count, 3)
        let local = groups[0], hades = groups[1], gone = groups[2]
        XCTAssertTrue(local.local)
        XCTAssertEqual(local.label, Rex.localHostLabel)
        XCTAssertTrue(local.reachable)
        XCTAssertEqual(local.entries.count, 2)
        XCTAssertTrue(local.entries[1].active, "origin session: \(local.entries[1])")
        XCTAssertTrue(hades.reachable)
        XCTAssertEqual(hades.entries.count, 1)
        XCTAssertEqual(hades.entries[0].state, "working")
        XCTAssertTrue(hades.entries[0].working)
        XCTAssertFalse(gone.reachable)
        XCTAssertNotEqual(gone.error, "")
        XCTAssertEqual(gone.entries.count, 0)
    }

    func testZoxideListOnRemoteFallsBackToShim() throws {
        let dir = testTempDir()
        let log = dir + "/ssh-calls"
        prependPATH(dir)
        let ssh = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$SSH_LOG"
        echo '/home/azuan/workspace'
        """
        writeExecutable(dir + "/ssh", contents: ssh)
        setenvTemp("SSH_LOG", log)
        let dirs = Rex.zoxideListOn("hades")
        XCTAssertEqual(dirs, ["/home/azuan/workspace"])
        let got = readTextFile(log)
        XCTAssertTrue(got.contains("hades"), "ssh calls = \(got)")
    }

    func testZoxideListOnLocalNeverRunsSSH() throws {
        let dir = testTempDir()
        prependPATH(dir)
        writeExecutable(dir + "/ssh", contents: "#!/bin/sh\necho 'ssh must not run' >&2\nexit 1\n")
        writeExecutable(dir + "/zoxide", contents: "#!/bin/sh\necho /local/one\necho /local/two\n")
        writeExecutable(dir + "/rex", contents: "#!/bin/sh\nexit 1\n")
        let dirs = Rex.zoxideListOn("")
        XCTAssertEqual(dirs.first, "/local/one")
        XCTAssertEqual(dirs.count, 2)
    }

    func testCreateSessionOnReusesLabelFirst() throws {
        let dir = testTempDir()
        let log = dir + "/calls"
        prependPATH(dir)
        setenvTemp("REX_TEST_LOG", log)
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$REX_TEST_LOG"
        case "$*" in
          'ls --json') echo '{"sessions":[{"session_id":"s1","label":"raptor"}]}' ;;
        esac
        """
        writeExecutable(dir + "/rex", contents: script)
        let (sid, existing) = try Rex.createSessionOn("", "/Users/x/Workspace/raptor")
        XCTAssertEqual(sid, "s1")
        XCTAssertTrue(existing)
        let got = readTextFile(log)
        XCTAssertFalse(got.contains("new "), "an existing session label must not create: \(got)")
    }
}
