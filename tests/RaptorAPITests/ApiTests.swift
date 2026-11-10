import Foundation
import RaptorCatalog
import RaptorConfig
import RaptorRex
import RaptorWorktree
import XCTest
@testable import RaptorAPI

final class ApiTests: APITestCase {
    func testStreamRecovery() throws {
        let h = Handler(ctx: Ctx(), cfg: .default())
        let lines = [
            "{",
            "{\"id\":2,\"method\":\"missing\",\"params\":{}}",
            "{\"id\":3,\"method\":\"directories\",\"params\":[]}",
            "{\"id\":4,\"method\":\"directories\",\"params\":{\"query\":42}}",
            "{\"method\":\"directories\",\"params\":{}}",
            "{\"id\":1.5,\"method\":\"directories\",\"params\":{}}",
            "{\"id\":7,\"method\":\"directories\",\"params\":null}",
            "{\"id\":8,\"method\":\"directories\"}",
            "{\"id\":9,\"method\":\"worktrees.list\",\"params\":{}}",
        ]
        let output = DataOutput()
        // No final newline: the final request must still be processed.
        try h.serve(input: DataInput(lines.joined(separator: "\n")), output: output)
        let responses = output.text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(responses.count, lines.count)
        for (i, line) in responses.enumerated() {
            let res = decodeWire(line)
            if i < lines.count - 1 {
                if res.error == nil || res.error!.isEmpty || res.result != nil {
                    XCTFail("expected error at \(i): \(line)")
                }
            } else {
                let dict = try jsonDict(res.result ?? "")
                if res.id != 9 || !(res.error ?? "").isEmpty || dict["needs_repo"] as? Bool != true
                    || dict["repo"] as? String != "" || dict["items"] == nil || dict["branches"] == nil {
                    XCTFail("unexpected final response: \(line)")
                }
            }
            if i == 1 && res.id != 2 {
                XCTFail("request id not preserved")
            }
        }
    }

    func testBoundedRequests() throws {
        let h = Handler(ctx: Ctx(), cfg: .default())
        let valid = "{\"id\":12,\"method\":\"worktrees.list\",\"params\":{}}"
        for input in [
            String(repeating: "x", count: Handler.maxRequestSize + 1) + "\n" + valid,
            String(repeating: "x", count: Handler.maxRequestSize + 1),
        ] {
            let out = DataOutput()
            try h.serve(input: DataInput(input), output: out)
            let responses = out.text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            let res = decodeWire(responses[0])
            if !(res.error ?? "").contains("maximum size") {
                XCTFail("unexpected response: \(responses[0])")
            }
            if input.hasSuffix(valid) {
                let next = decodeWire(responses[1])
                if next.id != 12 || !(next.error ?? "").isEmpty {
                    XCTFail("stream did not recover: \(responses[1])")
                }
            }
        }
        // Exactly the limit is accepted, including when the newline is a separate read.
        let out = DataOutput()
        let input = valid + String(repeating: " ", count: Handler.maxRequestSize - valid.count) + "\n"
        try h.serve(input: DataInput(input), output: out)
        let res = decodeWire(out.text.trimmingCharacters(in: .whitespacesAndNewlines))
        if !(res.error ?? "").isEmpty {
            XCTFail("boundary rejected: \(out.text)")
        }
    }

    final class BrokenInput: RequestInput {
        func readChunk() throws -> Data {
            throw StreamError.unexpectedEOF
        }
    }

    final class BrokenOutput: ResponseOutput {
        func writeChunk(_ data: Data) throws {
            throw StreamError.closedPipe
        }
    }

    func testStreamIOErrors() {
        let h = Handler(ctx: Ctx(), cfg: .default())
        do {
            try h.serve(input: BrokenInput(), output: DataOutput())
            XCTFail("expected read error")
        } catch {
            XCTAssertEqual(error as? StreamError, .unexpectedEOF)
        }
        do {
            try h.serve(input: DataInput("{}\n"), output: BrokenOutput())
            XCTFail("expected write error")
        } catch {
            XCTAssertEqual(error as? StreamError, .closedPipe)
        }
    }

    func testWorktreeListSuggestedBranch() throws {
        let repo = try fixtureRepo(env)
        let root = makeTempDir()
        let cfg = RaptorConfig(worktreeRoot: root + "/not-created")
        let call = makeClient(self, Handler(ctx: Ctx(), cfg: cfg))
        let beforeBranches = WorktreeKit.localBranches(repo: repo)
        let beforeTrees = WorktreeKit.list(repo: repo)
        var name = ""
        let err = call("worktrees.list", .object(["repo": .string(repo), "query": .string("no-matching-worktree")])) { result in
            let dict = try jsonDict(result)
            guard let suggested = dict["suggested_branch"] as? String, !suggested.isEmpty else {
                throw MessageError("missing suggested_branch")
            }
            name = suggested
        }
        if err.isEmpty {
            let parts = name.split(separator: "-").map(String.init)
            if parts.count != 2 || parts[0] == parts[1] {
                XCTFail("not two distinct words: \(name)")
            }
            try WorktreeKit.validate(repo: repo, branch: name, base: "main", path: WorktreeKit.path(repo: repo, branch: name, cfg: cfg))
            if beforeBranches != WorktreeKit.localBranches(repo: repo) || beforeTrees != WorktreeKit.list(repo: repo) {
                XCTFail("list claimed a name or created a worktree")
            }
            if fileExists(cfg.worktreeRoot) {
                XCTFail("list created destination")
            }
            // The suggestion is not reserved; create still rejects a later collision.
            _ = try WorktreeKit.gitOut(dir: repo, args: ["branch", name])
            let createErr = call("worktrees.create", .object(["repo": .string(repo), "branch": .string(name), "base": .string("main")]), nil)
            if !createErr.contains("already exists") {
                XCTFail("stale suggestion bypassed validation: \(createErr)")
            }
        } else {
            XCTFail(err)
        }
    }

    func testWorktreeListOmitsUnavailableSuggestion() throws {
        for scenario in ["no-repo", "unborn", "destination-error"] {
            try subtest(scenario, {
                let cfg = RaptorConfig(worktreeRoot: makeTempDir())
                var params: [String: JS] = [:]
                if scenario == "unborn" {
                    let repo = makeTempDir()
                    _ = try WorktreeKit.gitOut(dir: repo, args: ["init", "-b", "main"])
                    params["repo"] = .string(repo)
                } else if scenario == "destination-error" {
                    let repo = try fixtureRepo(env)
                    params["repo"] = .string(repo)
                    let looped = cfg.worktreeRoot + "/loop"
                    try FileManager.default.createSymbolicLink(atPath: looped, withDestinationPath: looped)
                    env.set("WORKTRUNK_WORKTREE_PATH", looped + "/{{ repo }}/{{ branch | sanitize }}")
                }
                let call = makeClient(self, Handler(ctx: Ctx(), cfg: cfg))
                var present = true
                var metadataOK = false
                let err = call("worktrees.list", .object(params)) { result in
                    let dict = try jsonDict(result)
                    present = dict["suggested_branch"] != nil
                    metadataOK = dict["items"] != nil && dict["branches"] != nil && dict["destination_root"] != nil
                }
                if !err.isEmpty {
                    throw MessageError(err)
                }
                if present {
                    XCTFail("\(scenario): empty suggestion must be omitted")
                }
                if !metadataOK {
                    XCTFail("\(scenario): normal metadata lost")
                }
            })
        }
    }

    func testWorktreeLifecycle() throws {
        let repo = try fixtureRepo(env)
        let cfg = RaptorConfig(worktreeRoot: makeTempDir())
        let call = makeClient(self, Handler(ctx: Ctx(), cfg: cfg))
        let params: [String: JS] = ["repo": .string(repo), "branch": .string("feat/native"), "base": .string("main")]
        var previewPath = ""
        var previewValidationError = ""
        func readPreview(_ result: String) throws {
            let dict = try jsonDict(result)
            previewPath = dict["path"] as? String ?? ""
            previewValidationError = dict["validation_error"] as? String ?? ""
        }
        var err = call("worktrees.preview", .object(params), readPreview)
        if !err.isEmpty { XCTFail(err) }
        let want = try WorktreeKit.previewPath(repo: repo, branch: "feat/native")
        if previewPath != want || !previewValidationError.isEmpty {
            XCTFail("preview: \(previewPath) / \(previewValidationError)")
        }
        let bad: [String: JS] = ["repo": .string(repo), "branch": .string("invalid branch"), "base": .string("main")]
        err = call("worktrees.preview", .object(bad), readPreview)
        if !err.isEmpty || previewValidationError.isEmpty {
            XCTFail("validation must be result: \(previewValidationError) \(err)")
        }
        err = call("worktrees.create", .object(bad), nil)
        if err.isEmpty {
            XCTFail("invalid branch accepted")
        }
        var badBase = bad
        badBase["branch"] = .string("feat/valid")
        badBase["base"] = .string("missing")
        err = call("worktrees.preview", .object(badBase), readPreview)
        if !previewValidationError.contains("base branch not found") {
            XCTFail("base validation: \(previewValidationError) \(err)")
        }
        var createdPath = ""
        err = call("worktrees.create", .object(params)) { result in
            createdPath = try jsonDict(result)["path"] as? String ?? ""
        }
        if !err.isEmpty { XCTFail(err) }
        if createdPath != want {
            XCTFail("path \(createdPath)")
        }
        err = call("worktrees.create", .object(params), nil)
        if err.isEmpty {
            XCTFail("duplicate create accepted")
        }
        err = call("worktrees.preview", .object(params), readPreview)
        if !previewValidationError.contains("already exists") {
            XCTFail("duplicate preview: \(previewValidationError) \(err)")
        }
        var listed = (
            destinationRoot: "", repo: "", needsRepo: false,
            items: [(path: "", branch: "", isMain: false)] as [(path: String, branch: String, isMain: Bool)],
            branches: [String](), baseBranch: "", suggestedBranchPresent: false, suggestedBranch: "")
        err = call("worktrees.list", .object(["repo": .string(repo)])) { result in
            listed = try decodeTreeRows(result)
        }
        if !err.isEmpty { XCTFail(err) }
        if listed.destinationRoot != goDir(want) || listed.repo != repo || listed.needsRepo
            || listed.items.count != 2 || !listed.items[0].isMain || listed.baseBranch != "main" {
            XCTFail("list: \(listed)")
        }
        if listed.branches != ["feat/native", "main"] {
            XCTFail("metadata branches: \(listed)")
        }
        for query in ["fnt", "sample", "does-not-match"] {
            err = call("worktrees.list", .object(["repo": .string(repo), "query": .string(query)])) { result in
                listed = try decodeTreeRows(result)
            }
            if !err.isEmpty { XCTFail(err) }
            let trees = WorktreeKit.list(repo: repo)
            let indices = Catalog.filterWorktrees(trees, query)
            if listed.items.count != indices.count {
                XCTFail("query \(query) differs from shared matcher")
            }
            for (i, index) in indices.enumerated() {
                if listed.items[i].path != trees[index].path {
                    XCTFail("query order differs")
                }
            }
        }
        for path in [repo, cfg.worktreeRoot + "/unknown", ""] {
            let removeErr = call("worktrees.remove", .object(["repo": .string(repo), "path": .string(path)]), nil)
            if removeErr.isEmpty {
                XCTFail("unsafe removal allowed: \(path)")
            }
        }
        let dirty = want + "/untracked.txt"
        try Data("keep".utf8).write(to: URL(fileURLWithPath: dirty))
        let remove: [String: JS] = ["repo": .string(repo), "path": .string(want)]
        err = call("worktrees.remove", .object(remove), nil)
        if err.isEmpty {
            XCTFail("dirty tree removed")
        }
        if !fileExists(dirty) {
            XCTFail("dirty content lost")
        }
        try FileManager.default.removeItem(atPath: dirty)
        _ = try WorktreeKit.gitOut(dir: repo, args: ["worktree", "lock", want])
        err = call("worktrees.remove", .object(remove), nil)
        if err.isEmpty {
            XCTFail("locked tree removed")
        }
        _ = try WorktreeKit.gitOut(dir: repo, args: ["worktree", "unlock", want])
        err = call("worktrees.remove", .object(remove), nil)
        if !err.isEmpty {
            XCTFail(err)
        }
        if fileExists(want) {
            XCTFail("tree still exists")
        }
        err = call("worktrees.remove", .object(remove), nil)
        if err.isEmpty {
            XCTFail("stale removal accepted")
        }
        _ = try WorktreeKit.gitOut(dir: repo, args: ["show-ref", "--verify", "refs/heads/feat/native"])
        err = call("worktrees.list", .object(["repo": .string(repo)])) { result in
            listed = try decodeTreeRows(result)
        }
        if !err.isEmpty || listed.items.count != 1 {
            XCTFail("final list: \(listed) \(err)")
        }
    }

    func testDirectoryQueries() throws {
        let repo = try fixtureRepo(env)
        let sub = repo + "/subdir"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: false)
        let other = makeTempDir()
        let dirs = [other, sub, repo, other]
        env.set("RAPTOR_TEST_DIRS", dirs.joined(separator: "\n"))
        try fakeTool(env, "zoxide", "printf '%s\\n' \"$RAPTOR_TEST_DIRS\"\n")
        let cfg = RaptorConfig(enter: "session")
        let call = makeClient(self, Handler(ctx: Ctx(), cfg: cfg))
        for reposOnly in [false, true] {
            for query in ["", "sbd", "sample", "no-such-match"] {
                var failed = ""
                var got: [Directory] = []
                var target = ""
                var targets: [String] = []
                let err = call("directories", .object(["query": .string(query), "repos_only": .bool(reposOnly)])) { result in
                    let dict = try jsonDict(result)
                    got = try decodeDirectoryRows(result)
                    target = dict["target"] as? String ?? ""
                    targets = dict["targets"] as? [String] ?? []
                    failed = dict["error"] as? String ?? ""
                }
                if !err.isEmpty { XCTFail(err) }
                let items = Catalog.directoryItems(dirs, reposOnly)
                var want: [Directory] = []
                for index in Catalog.filterDirectories(items, query) {
                    want.append(items[index])
                }
                if got != want || target != cfg.enter || targets != cfg.availableTargets(hasBlock: false) {
                    XCTFail("directory query: \(got) want \(want)")
                }
            }
        }
    }

    func testDirectoryListFollowsZoxide() throws {
        let repo = try fixtureRepo(env)
        env.set("RAPTOR_TEST_CWD", repo)
        try fakeTool(env, "rex", "printf '%s\\n' \"$RAPTOR_TEST_CWD\"\n")
        try fakeTool(env, "zoxide", "printf '%s\\n' /other \"$RAPTOR_TEST_CWD\"\n")
        let call = makeClient(self, Handler(ctx: Ctx(block: "origin"), cfg: .default()))
        let cases: [(query: String, paths: [String]?)] = [
            ("", ["/other", repo]),
            ("no-such-match", nil),
            ("other", ["/other"]),
        ]
        for c in cases {
            var paths: [String]?
            let err = call("directories", .object(["query": .string(c.query)])) { result in
                let items = try decodeDirectoryRows(result)
                if !items.isEmpty {
                    paths = items.map { $0.path }
                }
            }
            if !err.isEmpty { XCTFail(err) }
            if paths != c.paths {
                XCTFail("query \(c.query): got \(paths ?? []) want \(c.paths ?? [])")
            }
        }
    }

    func testRepoResolutionAndErrors() throws {
        let repo = try fixtureRepo(env)
        env.set("RAPTOR_TEST_CWD", repo)
        try fakeTool(env, "rex", "printf '%s\\n' \"$RAPTOR_TEST_CWD\"\n")
        let call = makeClient(self, Handler(ctx: Ctx(block: "origin"), cfg: .default()))
        var repoGot = "unset"
        var needsRepo = true
        var err = call("worktrees.list", .object([:])) { result in
            let dict = try jsonDict(result)
            repoGot = dict["repo"] as? String ?? ""
            needsRepo = dict["needs_repo"] as? Bool ?? true
        }
        if !err.isEmpty || repoGot != repo || needsRepo {
            XCTFail("inference: \(repoGot) \(err)")
        }
        for method in ["worktrees.list", "worktrees.preview", "worktrees.create", "worktrees.remove"] {
            let failErr = call(method, .object(["repo": .string(makeTempDir())]), nil)
            if !failErr.contains("not a git repository") {
                XCTFail("invalid repo \(method): \(failErr)")
            }
        }
        let noOrigin = makeClient(self, Handler(ctx: Ctx(), cfg: .default()))
        for method in ["worktrees.preview", "worktrees.create", "worktrees.remove"] {
            let failErr = noOrigin(method, .object([:]), nil)
            if failErr != "choose a repository" {
                XCTFail("missing repo \(method): \(failErr)")
            }
        }
        for target in ["tab", "pane_right", "here", "unknown"] {
            let failErr = noOrigin("dispatch", .object(["target": .string(target), "path": .string(repo)]), nil)
            if failErr.isEmpty {
                XCTFail("dispatch \(target) should fail")
            }
        }
        let noPathErr = noOrigin("dispatch", .object(["target": .string("tab")]), nil)
        if noPathErr != "path is required" {
            XCTFail(noPathErr)
        }
    }

    func testDispatchUsesOrigin() throws {
        let cache = makeTempDir()
        env.set("XDG_CACHE_HOME", cache)
        let log = makeTempDir() + "/rex.log"
        env.set("RAPTOR_TEST_LOG", log)
        try fakeTool(env, "rex", #"""
        printf '%s\n' "$*" >> "$RAPTOR_TEST_LOG"
        case "$1" in
        window) printf '{"window_id":"new-window"}\n' ;;
        focus) ;;
        *) exit 1 ;;
        esac
        """#)
        let cfg = RaptorConfig()
        let call = makeClient(self, Handler(ctx: Ctx(session: "origin-session", block: "origin-block"), cfg: cfg))
        var hasError = false
        let err = call("dispatch", .object(["target": .string("tab"), "path": .string("/tmp/project")])) { result in
            let dict = try jsonDict(result)
            hasError = dict["error"] != nil
        }
        if !err.isEmpty {
            XCTFail(err)
        }
        // Dispatch reports its outcome (path/session IDs) and, when a launcher
        // snapshot already exists, authoritative rows covering any new session.
        if hasError {
            XCTFail("successful dispatch must not carry an error")
        }
        let data = try readFile(log)
        let want = "window new -s origin-session project -c /tmp/project --json\nfocus -s origin-session new-window\n"
        if data != want {
            XCTFail("origin not forwarded: \(data)")
        }
        if fileExists(cache + "/rex/raptor-last-pane") {
            XCTFail("tab dispatch must not write Last Pane history")
        }
    }
}
