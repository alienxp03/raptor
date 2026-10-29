import Foundation

// Standalone, headless checks. Compile with Backend.swift and PickerRequest.swift only.
@main
struct PickerRequestChecks {
    static func main() throws {
        let base = "raptor://picker?mode=dirs&session=SID&block=BID&client=CID"
        let options = try parse(base)
        precondition(options.mode == "dirs" && options.session == "SID")
        precondition(options.block == "BID" && options.client == "CID")
        precondition(options.repo == nil && options.title.isEmpty && !options.demo)
        precondition(options.backendArguments == ["--session", "SID", "--block", "BID", "--client", "CID", "--title", "", "api"])

        let noBlock = try parse("raptor://picker/?mode=wt&session=S&client=C")
        precondition(noBlock.mode == "wt" && noBlock.block.isEmpty && noBlock.repo == nil)
        let unicode = try parse("raptor://picker?mode=wt&session=S&client=C&repo=%2FUsers%2F%E7%8C%AB%20%26%20caf%C3%A9")
        precondition(unicode.repo == "/Users/猫 & café")
        let percent = try parse("raptor://picker?mode=wt&session=S&client=C&repo=%2Ftmp%2F%2520%252F%25ZZ+plus")
        precondition(percent.repo == "/tmp/%20%2F%ZZ+plus", "Values must decode once; plus is literal")

        let payload = "--demo --mode dirs; $(touch /tmp/raptor-test) & action=dispatch\n/path"
        var components = URLComponents(string: "raptor://picker")!
        components.queryItems = [
            URLQueryItem(name: "mode", value: "wt"),
            URLQueryItem(name: "session", value: "--demo"),
            URLQueryItem(name: "client", value: "--mode"),
            URLQueryItem(name: "repo", value: payload),
        ]
        let inert = try LaunchOptions(pickerURL: components.url!)
        precondition(inert.repo == payload && inert.mode == "wt" && !inert.demo)
        precondition(inert.session == "--demo" && inert.client == "--mode" && inert.title.isEmpty)

        let invalid = [
            "https://picker?mode=dirs&session=S&client=C",
            "raptor://other?mode=dirs&session=S&client=C",
            "raptor:picker?mode=dirs&session=S&client=C",
            "raptor:///picker?mode=dirs&session=S&client=C",
            "raptor://user@picker?mode=dirs&session=S&client=C",
            "raptor://:password@picker?mode=dirs&session=S&client=C",
            "raptor://picker:123?mode=dirs&session=S&client=C",
            "raptor://picker/path?mode=dirs&session=S&client=C",
            "raptor://picker//?mode=dirs&session=S&client=C",
            "raptor://picker/%2F?mode=dirs&session=S&client=C",
            base + "#fragment", base + "#",
            "raptor://picker", "raptor://picker?",
            "raptor://picker?session=S&client=C",
            "raptor://picker?mode=dirs&client=C",
            "raptor://picker?mode=dirs&session=S",
            "raptor://picker?mode=other&session=S&client=C",
            "raptor://picker?mode=DIRS&session=S&client=C",
            base + "&session=other", base + "&%73ession=other",
            base + "&mode=wt", base + "&repo=a&repo=b",
            base + "&block=other", base + "&client=other",
            base + "&title=Title", base + "&target=tab", base + "&path=/tmp",
            base + "&action=dispatch", base + "&demo=true", base + "&unknown=value",
            base + "&=value", base + "&repo", base + "&repo=",
            "raptor://picker?mode=&session=S&client=C",
            "raptor://picker?mode=dirs&session=&client=C",
            "raptor://picker?mode=dirs&session=S&client=",
            "raptor://picker?mode=dirs&session&client=C",
            "raptor://picker?mode=dirs&session=S&client",
            "raptor://picker?mode=dirs&session=S&client=C&block=",
        ]
        for value in invalid { reject(value) }

        let prefix = "raptor://picker?mode=wt&session=S&client=C&repo="
        let limit = prefix + String(repeating: "x", count: 16 * 1024 - prefix.utf8.count)
        let atLimit = try parse(limit)
        precondition(atLimit.repo?.utf8.count == 16 * 1024 - prefix.utf8.count)
        reject(limit + "x")
        reject(prefix + String(repeating: "%E7%8C%AB", count: 2000))
        reject("raptor://picker?mode=dirs&session=" + String(repeating: "S", count: 16 * 1024) + "&client=C")
        print("PASS: picker URL context, optional block, Unicode, single decoding, inert payloads, invalid URLs and keys, 16 KiB limit")
    }

    private static func parse(_ value: String) throws -> LaunchOptions {
        try LaunchOptions(pickerURL: URL(string: value)!)
    }

    private static func reject(_ value: String) {
        guard let url = URL(string: value) else { return }
        do {
            _ = try LaunchOptions(pickerURL: url)
            preconditionFailure("Invalid picker URL accepted: \(value)")
        } catch {}
    }
}
