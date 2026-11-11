import Foundation
import XCTest
@testable import RaptorRex

final class DeletionRexTests: XCTestCase {
    func fixture() throws -> String {
        let root = FileManager.default.currentDirectoryPath + "/aux/delete-rex-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        setenvTemp("DELETE_REX_LOG", root + "/calls")
        prependPATH(root)
        writeExecutable(root + "/rex", contents: #"""
        #!/usr/bin/python3
        import sys, json, os, base64, re, subprocess
        args = sys.argv[1:]
        host = ''
        if args[:1] == ['-S']:
            host, args = args[1], args[2:]
        assert args[:2] == ['api', 'call'], args
        method = args[2]
        p = json.loads(args[3])
        with open(os.environ['DELETE_REX_LOG'], 'a') as f:
            f.write(json.dumps([host, method, p]) + '\n')
        if method == 'server.status':
            result = {'host_id': 'remote-id' if host else 'local-id'}
        elif method == 'hosts.list':
            result = {'hosts': [{'label': 'devbox', 'endpoints': ['fixture.invalid'], 'host_id': os.environ.get('DELETE_PIN', 'remote-id')}]}
        elif method == 'session.list':
            result = {'sessions': [{'session_id': 'session:target'}]}
        elif method == 'session.list_blocks':
            result = {'blocks': [{'block_id': 'block:user', 'creator_name': 'com.superlogical.terminal', 'host_id': os.environ.get('DELETE_BLOCK_HOST', 'remote-id' if host else 'local-id')}]}
        elif method == 'com.superlogical.terminal.process':
            result = {'last_exit': {'exit_code': 0}} if p['block_id'] == 'block:helper' else {'foreground': {'cwd': os.environ.get('DELETE_CWD', '/remote/tree')}, 'last_exit': None}
        elif method == 'block_creator.list':
            result = {'creators': [{'name': 'com.superlogical.terminal', 'host_id': 'remote-id' if host else 'local-id'}]}
        elif method == 'session.new_block':
            command = p['options']['command']
            assert command[:2] == ['/bin/sh', '-c']
            marker = re.search(r'RAPTOR-[A-Fa-f0-9-]+:', command[2]).group(0)
            error_marker = re.search(r'RAPTOR-STDERR-[A-Fa-f0-9-]+:', command[2]).group(0)
            with open(os.environ['DELETE_REX_LOG'] + '.marker', 'w') as f: json.dump([marker, error_marker], f)
            if os.environ.get('DELETE_EXECUTE_FIXTURE') == '1':
                output = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
                with open(os.environ['DELETE_REX_LOG'] + '.output', 'wb') as f: f.write(output.stdout)
            result = {'block_id': 'block:helper'}
        elif method == 'com.superlogical.terminal.format':
            with open(os.environ['DELETE_REX_LOG'] + '.marker') as f: marker, error_marker = json.load(f)
            if os.environ.get('DELETE_EXECUTE_FIXTURE') == '1':
                with open(os.environ['DELETE_REX_LOG'] + '.output') as f: content = f.read()
            else:
                content = base64.b64encode(('fixture output\n' + marker + '0').encode()).decode() + '\n' + error_marker + '\n'
            result = {'content': content, 'eof': True}
        elif method == 'block.close':
            assert p['session_id'] == 'session:target'
            assert p['block_id'] == 'block:helper'
            result = {}
        else:
            raise Exception(method)
        print(json.dumps(result))
        """#)
        return root
    }

    func testLiveStateUsesHostSpecificProcessCwd() throws {
        _ = try fixture()
        for host in ["", "devbox"] {
            let state = try Rex.deletionSessionState(host, "session:target")
            XCTAssertEqual(state.directories, ["/remote/tree"])
            XCTAssertEqual(state.hostID, host.isEmpty ? "local-id" : "remote-id")
        }
        setenvTemp("DELETE_PIN", "")
        XCTAssertEqual(try Rex.deletionSessionState("devbox", "session:target").hostID, "remote-id")
        setenvTemp("DELETE_BLOCK_HOST", "wrong-host")
        XCTAssertThrowsError(try Rex.deletionSessionState("devbox", "session:target"))
        setenvTemp("DELETE_BLOCK_HOST", "remote-id")
        setenvTemp("DELETE_CWD", "")
        XCTAssertThrowsError(try Rex.deletionSessionState("devbox", "session:target"))
        XCTAssertThrowsError(try Rex.deletionSessionState("devbox", "target"))
    }

    func testRemoteFramingPreservesBinaryStdoutAndSeparateStderr() throws {
        let root = try fixture()
        setenvTemp("DELETE_EXECUTE_FIXTURE", "1")
        let result = try Rex.deletionCommand("devbox", "session:target", "remote-id", directory: root,
                                             name: "/bin/sh", arguments: ["-c", "printf 'a\\000b'; printf 'diagnostic' >&2; exit 7"])
        XCTAssertEqual(result.stdout, "a\0b")
        XCTAssertEqual(result.stderr, "diagnostic")
        XCTAssertEqual(result.code, 7)
        let local = try Rex.deletionCommand("", "session:target", "local-id", directory: root,
                                            name: "/usr/bin/printf", arguments: ["local fixture"])
        XCTAssertEqual(local.stdout, "local fixture")
        XCTAssertEqual(local.code, 0)
    }

    func testPinnedRemoteExecutionAndStrictQuoting() throws {
        let root = try fixture()
        let result = try Rex.deletionCommand("devbox", "session:target", "remote-id",
                                             directory: "/remote/it's a tree", name: "wt",
                                             arguments: ["remove", "--", "/remote/a'; touch /unsafe; '"])
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(result.stdout, "fixture output")
        let calls = try String(contentsOfFile: root + "/calls", encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [Any]
        }
        for call in calls where call[1] as? String != "hosts.list" { XCTAssertEqual(call[0] as? String, "devbox") }
        XCTAssertEqual(calls.last?[1] as? String, "block.close")
        let creation = try XCTUnwrap(calls.first { $0[1] as? String == "session.new_block" }?[2] as? [String: Any])
        let options = try XCTUnwrap(creation["options"] as? [String: Any])
        let argv = try XCTUnwrap(options["command"] as? [String])
        XCTAssertTrue(argv[2].contains("'\\''"))
        XCTAssertFalse(argv[2].contains("ssh"))
        setenvTemp("DELETE_PIN", "different-id")
        XCTAssertThrowsError(try Rex.deletionCommand("devbox", "session:target", "remote-id", directory: "/remote/tree", name: "wt", arguments: ["remove"]))
    }
}
