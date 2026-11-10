import Foundation
import Darwin

// Compile ONLY this file as aux/.../Fixture.app/Contents/MacOS/raptor-cli.
// Synthetic protocol peer. No Rex, Git, worktree or file operation.
@main
struct TransportFixture {
    static func main() throws {
        let expected = ["--session", "S", "--block", "B", "--client", "C", "--title", "A title", "api"]
        guard Array(CommandLine.arguments.dropFirst()) == expected else { exit(3) }
        var requests: [String] = []
        while let line = readLine() {
            guard let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = request["id"] as? Int, let method = request["method"] as? String else { exit(4) }
            let params = request["params"] as? [String: Any] ?? [:]
            let query = params["query"] as? String ?? ""
            requests.append("\(id):\(method):\(query)")
            if let gate = params["gate"] as? String {
                FileManager.default.createFile(atPath: gate + ".ready", contents: Data())
                while !FileManager.default.fileExists(atPath: gate + ".release") {
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
            if method == "eof" { exit(2) }
            if method == "hang" { while true { Thread.sleep(forTimeInterval: 1) } }
            if method == "interleaved" {
                try FileHandle.standardOutput.write(contentsOf: Data("{\"event\":\"rex.changed\"}\n".utf8))
            }
            var response: [String: Any] = ["id": id, "result": [:] as [String: String]]
            switch method {
            case "pullrequests.resolve", "pullrequests.prepare":
                guard let input = params["input"] as? String,
                      let number = URL(string: input)?.lastPathComponent,
                      Int(number) != nil, params["repo"] == nil else { exit(5) }
                response["result"] = ["repo": "/ambient", "path": "/pr-" + number, "title": "Fixture PR"]
            case "pullrequests.open":
                guard let path = params["path"] as? String,
                      params["target"] as? String == (path == "/pr-13" ? "tab" : "session") else { exit(6) }
                let prepared = requests.contains { $0.contains(":pullrequests.prepare:") }
                if prepared && path == "/pr-13" { exit(2) }
                // A restarted backend can open from durable path state alone.
                // Preparing on the restarted connection would fail again.
                response["result"] = prepared
                    ? ["path": path, "session_id": "kept-S", "window_id": "kept-W", "block_id": "kept-B", "error": "Selection failed"]
                    : ["path": path, "session_id": "kept-S", "window_id": "kept-W", "block_id": "kept-B"]
            case "audit": response["result"] = ["branches": requests]
            case "sessions", "agents": response["result"] = ["items": [["path": query]]]
            case "error": response = ["id": id, "error": "fixture error"]
            case "graceful-close":
                signal(SIGTERM, SIG_IGN)
                response["result"] = ["path": String(getpid())]
            case "bad-id": response["id"] = id + 1
            case "both": response["error"] = "bad envelope"
            case "no-result": response = ["id": id]
            case "event-id": response = ["id": id, "event": "rex.changed"]
            case "unknown-event": response = ["event": "unexpected"]
            default: break
            }
            var data = method == "malformed" ? Data("not json".utf8) : try JSONSerialization.data(withJSONObject: response)
            data.append(0x0A)
            try FileHandle.standardOutput.write(contentsOf: data.prefix(5))
            Thread.sleep(forTimeInterval: 0.01)
            try FileHandle.standardOutput.write(contentsOf: data.dropFirst(5))
            if method == "reply-and-eof" || (method == "pullrequests.open" && requests.contains { $0.contains(":pullrequests.prepare:") }) { exit(0) }
            if method == "events.subscribe",
               let params = request["params"] as? [String: Any], params["enabled"] as? Bool == true {
                // No new request is needed to read this notification.
                Thread.sleep(forTimeInterval: 0.08)
                try FileHandle.standardOutput.write(contentsOf: Data("{\"event\":\"rex.changed\"}\n".utf8))
            }
        }
    }
}
