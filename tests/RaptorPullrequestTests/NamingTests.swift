import XCTest
import RaptorRex
@testable import RaptorPullrequest

/// Ported from internal/pullrequest/naming_test.go.
final class NamingTests: XCTestCase {
    func testDestinationLabel() {
        let cases: [(SetupState, String)] = [
            (SetupState(branch: "fix/cancellation-page-back-navigation", url: "https://github.com/loveholidays/aurora/pull/10990"),
             "aurora-pr-10990-fix-cancellation-page-back-navigation"),
            (SetupState(branch: "feat/nested/topic", url: "https://github.com/acme/project/pull/42"),
             "project-pr-42-feat-nested-topic"),
            (SetupState(path: "/worktrees/project/feat-login", branch: "feat/login"),
             "feat-login"),
        ]
        for (state, want) in cases {
            XCTAssertEqual(destinationLabel(state), want, "label = \(destinationLabel(state)), want \(want)")
        }
    }

    func testRepeatedPROpenReusesNamedDestinationAndSetup() {
        for target in ["session", "tab"] {
            subtest(target) {
                let env = TestEnv()
                defer { env.restore() }
                let (repo, _) = try fixture(env)
                let ctx = Ctx(session: "origin", block: "source", client: "client")
                let first = try Pullrequest.prepare(repo: repo, input: "42")
                let (opened, openErr) = openResult(first.path, target, ctx)
                XCTAssertNil(openErr, "\(String(describing: openErr))")
                try Pullrequest.setup(path: first.path, retry: false)
                let (second, prepErr) = prepareInfo(repo, "https://github.com/acme/project/pull/42")
                XCTAssertNil(prepErr, "\(String(describing: prepErr))")
                XCTAssertTrue(second.existing)
                XCTAssertEqual(second.path, first.path)
                let (reused, reusedErr) = openResult(second.path, target, ctx)
                XCTAssertNil(reusedErr, "\(String(describing: reusedErr))")
                XCTAssertEqual(reused, opened, "second open: \(reused), first \(opened)")
                try Pullrequest.setup(path: second.path, retry: false)
                let calls = try readLog(env)
                var create = "rex new project-pr-42-feat-fix "
                if target == "tab" {
                    create = "rex window new -s origin project-pr-42-feat-fix "
                }
                XCTAssertEqual(calls.components(separatedBy: create).count - 1, 1, "repeated open duplicated creation: \(calls)")
                XCTAssertEqual(calls.components(separatedBy: "wt hook pre-start ").count - 1, 1, "repeated open duplicated setup: \(calls)")
            }
        }
    }
}
