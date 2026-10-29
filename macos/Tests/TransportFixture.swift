import Foundation
import Darwin

// Compile ONLY this file as aux/.../Fixture.app/Contents/MacOS/raptor-cli.
// Synthetic protocol peer. No Rex, Git, worktree or file operation.
@main
struct TransportFixture {
    static func main() throws {
        let expected = ["--session", "S", "--block", "B", "--client", "C", "--title", "A title", "api"]
        guard Array(CommandLine.arguments.dropFirst()) == expected else { exit(3) }
        while let line = readLine() {
            guard let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = request["id"] as? Int, let method = request["method"] as? String else { exit(4) }
            if method == "eof" { exit(2) }
            if method == "hang" { while true { Thread.sleep(forTimeInterval: 1) } }
            var response: [String: Any] = ["id": id, "result": [:] as [String: String]]
            switch method {
            case "error": response = ["id": id, "error": "fixture error"]
            case "bad-id": response["id"] = id + 1
            case "both": response["error"] = "bad envelope"
            case "no-result": response = ["id": id]
            default: break
            }
            var data = method == "malformed" ? Data("not json".utf8) : try JSONSerialization.data(withJSONObject: response)
            data.append(0x0A)
            try FileHandle.standardOutput.write(contentsOf: data.prefix(5))
            Thread.sleep(forTimeInterval: 0.01)
            try FileHandle.standardOutput.write(contentsOf: data.dropFirst(5))
        }
    }
}
