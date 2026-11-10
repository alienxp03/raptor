import XCTest
@testable import RaptorRex

final class HostsResolutionTests: XCTestCase {
    func testAppClientOnRequiresUniqueAppLabel() throws {
        struct ClientCase {
            let name: String
            let label: String
            let clients: String
            let want: String
        }
        let cases: [ClientCase] = [
            ClientCase(name: "unique among unrelated", label: "studio", clients: "{\"clients\":[{\"client_id\":\"client:other\",\"info\":{\"kind\":\"app\",\"label\":\"other\"}},{\"client_id\":\"client:cli\",\"info\":{\"kind\":\"cli\",\"label\":\"studio\"}},{\"client_id\":\"client:remote\",\"info\":{\"kind\":\"app\",\"label\":\"studio\"}}]}", want: "client:remote"),
            ClientCase(name: "duplicate", label: "studio", clients: "{\"clients\":[{\"client_id\":\"client:one\",\"info\":{\"kind\":\"app\",\"label\":\"studio\"}},{\"client_id\":\"client:two\",\"info\":{\"kind\":\"app\",\"label\":\"studio\"}}]}", want: ""),
            ClientCase(name: "lost duplicate", label: "studio", clients: "{\"clients\":[{\"client_id\":\"client:one\",\"info\":{\"kind\":\"app\",\"label\":\"studio\"}},{\"client_id\":\"client:two\",\"connection_state\":\"lost\",\"info\":{\"kind\":\"app\",\"label\":\"studio\"}}]}", want: ""),
            ClientCase(name: "unrelated only", label: "studio", clients: "{\"clients\":[{\"client_id\":\"client:other\",\"info\":{\"kind\":\"app\",\"label\":\"other\"}}]}", want: ""),
            ClientCase(name: "no label fallback", label: "", clients: "{\"clients\":[{\"client_id\":\"client:other\",\"info\":{\"kind\":\"app\",\"label\":\"other\"}}]}", want: ""),
            ClientCase(name: "missing id", label: "studio", clients: "{\"clients\":[{\"info\":{\"kind\":\"app\",\"label\":\"studio\"}}]}", want: ""),
            ClientCase(name: "malformed", label: "studio", clients: "{", want: ""),
        ]
        for c in cases {
            let log = fakeHostDiscovery()
            setenvTemp("HOST_DISCOVERY_CLIENTS", c.clients)
            XCTAssertEqual(Rex.appClientOn("remote", c.label), c.want, "\(c.name)")
            let calls = discoveryCalls(log)
            if c.label.isEmpty {
                XCTAssertEqual(calls, "", "\(c.name): empty label performed discovery: \(calls)")
            } else {
                XCTAssertEqual(calls, "-S remote api call client.list {\"kinds\":[\"app\"]}\n", "\(c.name)")
            }
        }
    }

    func testClientLabelChecksOriginAndLocalUniqueness() throws {
        let unique = "{\"clients\":[{\"client_id\":\"client:origin\",\"info\":{\"kind\":\"app\",\"label\":\"studio\"}},{\"client_id\":\"client:other\",\"info\":{\"kind\":\"app\",\"label\":\"other\"}}]}"
        struct LabelCase {
            let name: String
            let ref: String
            let resolution: String
            let clients: String
            let want: String
        }
        let cases: [LabelCase] = [
            LabelCase(name: "full id", ref: "client:origin", resolution: "", clients: unique, want: "studio"),
            LabelCase(name: "unknown origin", ref: "client:absent", resolution: "", clients: unique, want: ""),
            LabelCase(name: "suffix", ref: "abcd", resolution: "{\"results\":[{\"query\":\"abcd\",\"status\":\"resolved\",\"target\":{\"kind\":\"client\",\"client_id\":\"client:origin\"}}]}", clients: unique, want: "studio"),
            LabelCase(name: "ambiguous origin", ref: "studio", resolution: "{\"results\":[{\"query\":\"studio\",\"status\":\"ambiguous\"}]}", clients: unique, want: ""),
            LabelCase(name: "multiple apps no origin", ref: "", resolution: "{\"results\":[{\"query\":\"\",\"status\":\"ambiguous\"}]}", clients: unique, want: ""),
            LabelCase(name: "unique default", ref: "", resolution: "{\"results\":[{\"query\":\"\",\"status\":\"resolved\",\"target\":{\"kind\":\"client\",\"client_id\":\"client:origin\"}}]}", clients: "{\"clients\":[{\"client_id\":\"client:origin\",\"info\":{\"kind\":\"app\",\"label\":\"studio\"}}]}", want: "studio"),
            LabelCase(name: "duplicate origin label", ref: "client:origin", resolution: "", clients: "{\"clients\":[{\"client_id\":\"client:origin\",\"info\":{\"kind\":\"app\",\"label\":\"studio\"}},{\"client_id\":\"client:other\",\"info\":{\"kind\":\"app\",\"label\":\"studio\"}}]}", want: ""),
            LabelCase(name: "cli origin", ref: "client:origin", resolution: "", clients: "{\"clients\":[{\"client_id\":\"client:origin\",\"info\":{\"kind\":\"cli\",\"label\":\"studio\"}}]}", want: ""),
            LabelCase(name: "lost origin", ref: "client:origin", resolution: "", clients: "{\"clients\":[{\"client_id\":\"client:origin\",\"connection_state\":\"lost\",\"info\":{\"kind\":\"app\",\"label\":\"studio\"}}]}", want: ""),
        ]
        for c in cases {
            let log = fakeHostDiscovery()
            setenvTemp("HOST_DISCOVERY_CLIENTS", c.clients)
            setenvTemp("HOST_DISCOVERY_TARGET", c.resolution)
            XCTAssertEqual(Rex.clientLabel(c.ref), c.want, "\(c.name)")
            let calls = discoveryCalls(log)
            XCTAssertFalse(calls.contains("-S "), "\(c.name): unexpected origin discovery: \(calls)")
            XCTAssertFalse(calls.contains("client.inspect"), "\(c.name): unexpected origin discovery: \(calls)")
            if c.ref.hasPrefix("client:") {
                XCTAssertFalse(calls.contains("target.resolve"), "\(c.name): full origin ID required resolution: \(calls)")
            }
        }
    }

    func testSameSessionUsesNativeAmbiguityRules() throws {
        struct SameCase {
            let name: String
            let full: String
            let ref: String
            let result: String
            let want: Bool
        }
        let cases: [SameCase] = [
            SameCase(name: "exact", full: "session:1234abcd", ref: "session:1234abcd", result: "", want: true),
            SameCase(name: "different full", full: "session:1234abcd", ref: "session:5678abcd", result: "", want: false),
            SameCase(name: "empty origin", full: "session:1234abcd", ref: "", result: "", want: false),
            SameCase(name: "blank origin", full: "session:1234abcd", ref: "  ", result: "", want: false),
            SameCase(name: "empty full", full: "", ref: "abcd", result: "", want: false),
            SameCase(name: "unique suffix", full: "session:1234abcd", ref: "abcd", result: "{\"results\":[{\"query\":\"abcd\",\"status\":\"resolved\",\"target\":{\"kind\":\"session\",\"session_id\":\"session:1234abcd\"}}]}", want: true),
            SameCase(name: "ambiguous suffix", full: "session:1234abcd", ref: "abcd", result: "{\"results\":[{\"query\":\"abcd\",\"status\":\"ambiguous\",\"candidates\":[{\"kind\":\"session\",\"session_id\":\"session:1234abcd\"},{\"kind\":\"session\",\"session_id\":\"session:5678abcd\"}]}]}", want: false),
            SameCase(name: "label wins over suffix", full: "session:1234abcd", ref: "abcd", result: "{\"results\":[{\"query\":\"abcd\",\"status\":\"resolved\",\"target\":{\"kind\":\"session\",\"session_id\":\"session:other\"}}]}", want: false),
            SameCase(name: "not found", full: "session:1234abcd", ref: "abcd", result: "{\"results\":[{\"query\":\"abcd\",\"status\":\"not_found\"}]}", want: false),
            SameCase(name: "unknown status", full: "session:1234abcd", ref: "abcd", result: "{\"results\":[{\"query\":\"abcd\",\"status\":\"new\",\"target\":{\"kind\":\"session\",\"session_id\":\"session:1234abcd\"}}]}", want: false),
            SameCase(name: "wrong kind", full: "session:1234abcd", ref: "abcd", result: "{\"results\":[{\"query\":\"abcd\",\"status\":\"resolved\",\"target\":{\"kind\":\"block\",\"session_id\":\"session:1234abcd\"}}]}", want: false),
            SameCase(name: "wrong query", full: "session:1234abcd", ref: "abcd", result: "{\"results\":[{\"query\":\"other\",\"status\":\"resolved\",\"target\":{\"kind\":\"session\",\"session_id\":\"session:1234abcd\"}}]}", want: false),
            SameCase(name: "malformed", full: "session:1234abcd", ref: "abcd", result: "{", want: false),
        ]
        for c in cases {
            let log = fakeHostDiscovery()
            setenvTemp("HOST_DISCOVERY_TARGET", c.result)
            XCTAssertEqual(Rex.sameSession(c.full, c.ref), c.want, "\(c.name)")
            let calls = discoveryCalls(log)
            if c.result.isEmpty {
                XCTAssertEqual(calls, "", "\(c.name): exact/empty references performed RPC: \(calls)")
            } else {
                XCTAssertEqual(calls, "api call target.resolve {\"kinds\":[\"session\"],\"queries\":[\"abcd\"]}\n", "\(c.name): unexpected resolution: \(calls)")
            }
        }
    }

    func testSameSessionOnResolvesOnlyOnRemote() throws {
        let log = fakeHostDiscovery()
        setenvTemp("HOST_DISCOVERY_TARGET", "{\"results\":[{\"query\":\"abcd\",\"status\":\"resolved\",\"target\":{\"kind\":\"session\",\"session_id\":\"session:remoteabcd\"}}]}")
        XCTAssertTrue(Rex.sameSessionOn("remote", "session:remoteabcd", "abcd"))
        XCTAssertEqual(discoveryCalls(log), "-S remote api call target.resolve {\"kinds\":[\"session\"],\"queries\":[\"abcd\"]}\n")
    }

    func testHostDiscoveryFailsClosedWhenRexFails() throws {
        fakeRexWithHosts("#!/bin/sh\nexit 1\n")
        XCTAssertFalse(Rex.sameSession("session:1234abcd", "abcd"))
        XCTAssertEqual(Rex.clientLabel("abcd"), "")
        XCTAssertEqual(Rex.appClientOn("remote", "studio"), "", "failed discovery must not guess a target")
    }

    func testLocalHostnameUsesSupportedDisplaySources() throws {
        struct HostnameCase {
            let name: String
            let status: String
            let want: String
        }
        let cases: [HostnameCase] = [
            HostnameCase(name: "tailscale", status: "{\"hostname\":\"unsupported\",\"tailscale\":{\"dns_name\":\"studio.tail123.ts.net.\"}}", want: "studio"),
            HostnameCase(name: "os fallback", status: "{\"hostname\":\"unsupported\"}", want: ""),
            HostnameCase(name: "malformed fallback", status: "{", want: ""),
        ]
        for c in cases {
            let log = fakeHostDiscovery()
            setenvTemp("HOST_DISCOVERY_STATUS", c.status)
            Rex.resetLocalHostnameForTesting()
            addTeardownBlock { Rex.resetLocalHostnameForTesting() }
            var want = c.want
            if want.isEmpty {
                let name = Rex.osHostname() ?? ""
                want = name
                if want.isEmpty {
                    want = Rex.localHostLabel
                }
            }
            XCTAssertEqual(Rex.localHostname(), want, "\(c.name)")
            _ = Rex.localHostname()
            XCTAssertEqual(discoveryCalls(log), "api call server.status\n", "\(c.name): unsupported or repeated hostname discovery")
        }
    }
}
