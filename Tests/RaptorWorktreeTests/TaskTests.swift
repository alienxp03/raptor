import XCTest
import RaptorConfig
@testable import RaptorWorktree

/// Ported from internal/worktree/task_test.go.
final class TaskTests: XCTestCase {
    /// Snapshot includes Git internals, dirty files, directories, and symlinks.
    private func taskSnapshot(_ root: String) throws -> [String: String] {
        var result: [String: String] = [:]
        func walk(_ dir: String) throws {
            for name in try FileManager.default.contentsOfDirectory(atPath: dir).sorted() {
                let path = dir + "/" + name
                let attrs = try FileManager.default.attributesOfItem(atPath: path)
                let type = attrs[.type] as? FileAttributeType ?? FileAttributeType.typeUnknown
                let content: String
                switch type {
                case .typeSymbolicLink:
                    content = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? ""
                case .typeRegular:
                    content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                default:
                    content = ""
                }
                let mtime = (attrs[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970 * 1_000_000_000) } ?? 0
                let mode = attrs[.posixPermissions] as? Int ?? 0
                result[path] = "\(type.rawValue) \(mode) \(mtime) \(content)"
                if type == .typeDirectory {
                    try walk(path)
                }
            }
        }
        try walk(root)
        return result
    }

    private func assertUnchanged(_ label: String, before: [String: String], root: String) throws {
        XCTAssertEqual(before, try taskSnapshot(root), "\(label) changed")
    }

    func testSuggestTaskNameReadOnly() throws {
        for detached in [false, true] {
            let env = TestEnv()
            defer { env.restore() }
            let label = detached ? "detached" : "branch"
            let repo = try fixtureRepo(env)
            if detached {
                _ = try WorktreeKit.gitOut(dir: repo, args: ["checkout", "--detach"])
            }
            try "keep".write(toFile: repo + "/dirty", atomically: true, encoding: .utf8)
            let root = try makeTempDir()
            let cfg = RaptorConfig(worktreeRoot: root + "/not-created")
            let beforeRepo = try taskSnapshot(repo)
            let beforeRoot = try taskSnapshot(root)
            let name = try WorktreeKit.suggestTaskName(repo: repo, cfg: cfg)
            let parts = name.components(separatedBy: "-")
            XCTAssertEqual(parts.count, 2, "\(label): not two distinct words: \(name)")
            XCTAssertNotEqual(parts.first, parts.last, "\(label): not two distinct words: \(name)")
            let known = " " + taskWordList.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") + " "
            for part in parts {
                XCTAssertTrue(known.contains(" \(part) "), "\(label): word not in whitelist: \(part)")
            }
            try assertUnchanged("\(label): repository", before: beforeRepo, root: repo)
            try assertUnchanged("\(label): destination", before: beforeRoot, root: root)
            // No reservation: the same deterministic candidate remains available.
            for _ in 0..<2 {
                let got = try WorktreeKit.suggestTaskName(repo: repo, cfg: cfg, names: [name])
                XCTAssertEqual(got, name, "\(label): name was claimed")
            }
        }
    }

    func testSuggestTaskNameCollisionsAndExhaustion() throws {
        let env = TestEnv()
        defer { env.restore() }
        let repo = try fixtureRepo(env)
        let cfg = RaptorConfig(worktreeRoot: try makeTempDir())
        for branch in ["amber-birch", "cedar-dune/topic"] {
            _ = try WorktreeKit.gitOut(dir: repo, args: ["branch", branch])
        }
        // Include packed refs in prefix collision checks.
        _ = try WorktreeKit.gitOut(dir: repo, args: ["pack-refs", "--all"])
        let dir = WorktreeKit.path(repo: repo, branch: "elm-frost", cfg: cfg)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "keep".write(toFile: WorktreeKit.path(repo: repo, branch: "grove-hazel", cfg: cfg), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: WorktreeKit.path(repo: repo, branch: "iris-jade", cfg: cfg),
                                                   withDestinationPath: cfg.worktreeRoot + "/missing")
        try FileManager.default.createSymbolicLink(atPath: WorktreeKit.path(repo: repo, branch: "kelp-larch", cfg: cfg),
                                                   withDestinationPath: dir)
        let blocked = ["amber-birch", "cedar-dune", "elm-frost", "grove-hazel", "iris-jade", "kelp-larch", "invalid branch"]
        let names = blocked + ["maple-north"]
        let beforeRepo = try taskSnapshot(repo)
        let beforeRoot = try taskSnapshot(cfg.worktreeRoot)
        let got = try WorktreeKit.suggestTaskName(repo: repo, cfg: cfg, names: names)
        XCTAssertEqual(got, "maple-north", "suggestion")
        for candidates in [blocked, [String]()] {
            var suggested = ""
            do {
                suggested = try WorktreeKit.suggestTaskName(repo: repo, cfg: cfg, names: candidates)
            } catch {
                XCTAssertTrue(String(describing: error).contains("all \(candidates.count)"),
                              "expected exhaustion: \(error)")
                continue
            }
            XCTFail("expected exhaustion: \(suggested)")
        }
        try assertUnchanged("collision selection: repository", before: beforeRepo, root: repo)
        try assertUnchanged("collision selection: destination", before: beforeRoot, root: cfg.worktreeRoot)
        // Instant Create and the form must select the same candidate.
        let tree = try WorktreeKit.createTask(repo: repo, cfg: cfg, names: names)
        XCTAssertEqual(tree.branch, got, "create differs from suggestion")
    }

    func testSuggestTaskNameErrors() throws {
        let env = TestEnv()
        defer { env.restore() }
        let unborn = try makeTempDir()
        _ = try WorktreeKit.gitOut(dir: unborn, args: ["init"])
        for repo in [unborn, try makeTempDir(), try makeTempDir() + "/missing"] {
            var name = ""
            do {
                name = try WorktreeKit.suggestTaskName(repo: repo, cfg: RaptorConfig(worktreeRoot: try makeTempDir()))
            } catch {
                XCTAssertTrue(String(describing: error).contains("committed HEAD"),
                              "\(repo): invalid repo accepted: \(error)")
                continue
            }
            XCTFail("\(repo): invalid repo accepted: \(name)")
        }
        let repo = try fixtureRepo(env)
        let root = try makeTempDir()
        // A symlink loop gives a deterministic Lstat error, even when run as root.
        let loop = root + "/loop"
        try FileManager.default.createSymbolicLink(atPath: loop, withDestinationPath: loop)
        let cfg = RaptorConfig(worktreeRoot: loop)
        env.set("WORKTRUNK_WORKTREE_PATH", loop + "/{{ branch | sanitize }}")
        let beforeRepo = try taskSnapshot(repo)
        let beforeRoot = try taskSnapshot(root)
        var name = ""
        do {
            name = try WorktreeKit.suggestTaskName(repo: repo, cfg: cfg, names: ["amber-birch", "cedar-dune"])
        } catch {
            XCTAssertFalse(String(describing: error).contains("all 2"), "filesystem error hidden: \(error)")
            try assertUnchanged("error handling: repository", before: beforeRepo, root: repo)
            try assertUnchanged("error handling: destination", before: beforeRoot, root: root)
            return
        }
        XCTFail("filesystem error hidden: \(name)")
    }

    func testTaskFromCurrentHEADKeepsDirtyFiles() throws {
        for detached in [false, true] {
            let env = TestEnv()
            defer { env.restore() }
            let label = detached ? "detached" : "branch"
            let repo = try fixtureRepo(env)
            _ = try WorktreeKit.gitOut(dir: repo, args: ["checkout", "-b", "feature/source"])
            _ = try WorktreeKit.gitOut(dir: repo, args: ["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "source"])
            let head = try WorktreeKit.gitOut(dir: repo, args: ["rev-parse", "HEAD"])
            if detached {
                _ = try WorktreeKit.gitOut(dir: repo, args: ["checkout", "--detach"])
            }
            let dirty = repo + "/uncommitted"
            try "keep me".write(toFile: dirty, atomically: true, encoding: .utf8)
            let cfg = RaptorConfig(worktreeRoot: try makeTempDir() + "/worktree root")
            let tree = try WorktreeKit.createTask(repo: repo, cfg: cfg)
            let parts = tree.branch.components(separatedBy: "-")
            XCTAssertEqual(parts.count, 2, "\(label): \(tree.branch)")
            let known = " " + taskWordList.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") + " "
            for part in parts {
                XCTAssertTrue(known.contains(" \(part) "), "\(label): branch \(tree.branch) not built from the word list")
            }
            let got = try WorktreeKit.gitOut(dir: tree.path, args: ["rev-parse", "HEAD"])
            XCTAssertEqual(got, head, "\(label): base")
            let current = try WorktreeKit.gitOut(dir: tree.path, args: ["branch", "--show-current"])
            XCTAssertEqual(current, tree.branch, label)
            let data = try String(contentsOfFile: dirty, encoding: .utf8)
            XCTAssertEqual(data, "keep me", "\(label): origin dirty file lost")
            XCTAssertFalse(FileManager.default.fileExists(atPath: tree.path + "/uncommitted"),
                           "\(label): copied dirty origin state")
        }
    }

    func testTaskRetriesExistingNamesAndDestinations() throws {
        let env = TestEnv()
        defer { env.restore() }
        let repo = try fixtureRepo(env)
        let cfg = RaptorConfig(worktreeRoot: try makeTempDir())
        _ = try WorktreeKit.gitOut(dir: repo, args: ["branch", "task/existing"])
        let occupied = WorktreeKit.path(repo: repo, branch: "task/occupied", cfg: cfg)
        try FileManager.default.createDirectory(atPath: occupied, withIntermediateDirectories: true)
        let names = ["task/existing", "task/occupied", "task/fresh"]
        let tree = try WorktreeKit.createTask(repo: repo, cfg: cfg, names: names)
        XCTAssertEqual(tree.branch, "task/fresh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: occupied), "existing destination removed")
    }

    func testTaskWordsAreUniqueSingleWordsAndShufflePreservesThem() throws {
        let words = taskWordList.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        XCTAssertGreaterThanOrEqual(words.count, 400, "word list too short: \(words.count)")
        var seen = Set<String>()
        for word in words {
            XCTAssertFalse(seen.contains(word) || word.isEmpty, "duplicate/empty word: \(word)")
            for scalar in word.unicodeScalars {
                XCTAssertTrue(scalar.value >= 97 && scalar.value <= 122, "not a lowercase single word: \(word)")
            }
            seen.insert(word)
        }
        let shuffled = WorktreeKit.shuffledTaskWords()
        XCTAssertEqual(shuffled.count, words.count, "shuffle changed word count")
        var remaining = seen
        for word in shuffled {
            XCTAssertTrue(remaining.remove(word) != nil, "unknown/repeated shuffled word: \(word)")
        }
        XCTAssertTrue(remaining.isEmpty, "shuffle lost words")
    }

    func testTaskNamesAreTwoWordPairsWithoutRepeats() throws {
        let pairs = WorktreeKit.taskNamePairs(["amber", "birch", "cedar", "dune", "elm", "frost"])
        let want = ["amber-dune", "birch-elm", "cedar-frost"]
        XCTAssertEqual(pairs.count, want.count, "\(pairs)")
        var seen = Set<String>()
        for (i, pair) in pairs.enumerated() {
            XCTAssertEqual(pair, want[i], "pair \(i)")
            let parts = pair.components(separatedBy: "-")
            XCTAssertEqual(parts.count, 2, "not two words: \(pair)")
            for part in parts {
                XCTAssertFalse(seen.contains(part), "word reused across pairs: \(part)")
                seen.insert(part)
            }
        }
        let shuffled = WorktreeKit.shuffledTaskWords()
        let generated = WorktreeKit.taskNamePairs(shuffled)
        XCTAssertEqual(generated.count, shuffled.count / 2, "pair count")
    }

    func testTaskCollisionsChooseAnotherWordWithoutSuffix() throws {
        let env = TestEnv()
        defer { env.restore() }
        let repo = try fixtureRepo(env)
        let cfg = RaptorConfig(worktreeRoot: try makeTempDir())
        _ = try WorktreeKit.gitOut(dir: repo, args: ["branch", "otter"])
        _ = try WorktreeKit.gitOut(dir: repo, args: ["branch", "willow/topic"])
        let occupied = WorktreeKit.path(repo: repo, branch: "cedar", cfg: cfg)
        try FileManager.default.createDirectory(atPath: occupied, withIntermediateDirectories: true)
        let tree = try WorktreeKit.createTask(repo: repo, cfg: cfg, names: ["otter", "cedar", "willow", "falcon"])
        XCTAssertEqual(tree.branch, "falcon")
        do {
            _ = try WorktreeKit.createTask(repo: repo, cfg: cfg, names: ["otter", "cedar", "falcon"])
            XCTFail("expected exhaustion")
        } catch {
            XCTAssertTrue(String(describing: error).contains("all 3"), "expected exhaustion, got \(error)")
        }
        XCTAssertEqual(WorktreeKit.list(repo: repo).count, 2, "collision handling created extra worktrees")
    }

    func testTaskRequiresCommittedHEAD() throws {
        let env = TestEnv()
        defer { env.restore() }
        let repo = try makeTempDir()
        _ = try WorktreeKit.gitOut(dir: repo, args: ["init"])
        XCTAssertThrowsError(try WorktreeKit.createTask(repo: repo, cfg: RaptorConfig(worktreeRoot: try makeTempDir())),
                             "unborn repository accepted")
    }
}
