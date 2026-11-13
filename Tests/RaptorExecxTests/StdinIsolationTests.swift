import Foundation
import XCTest
@testable import RaptorExecx

final class StdinIsolationTests: XCTestCase {
    func testCaptureCannotChangeParentPipeFlags() throws {
        let marker = "RAPTOR_EXECX_STDIN_HARNESS"
        if ProcessInfo.processInfo.environment[marker] == "1" {
            // This branch runs only in an external XCTest process with a private
            // pipe on fd 0. Even a regressed Execx cannot alter the main runner.
            let result = try Execx.run(name: "/usr/bin/python3", args: ["-c", """
            import os, stat
            before = os.fstat(0)
            null = os.stat('/dev/null')
            os.set_blocking(0, False)
            assert stat.S_ISCHR(before.st_mode) and before.st_rdev == null.st_rdev
            assert os.read(0, 1) == b''
            print('isolated')
            """])
            XCTAssertEqual(result.code, 0, result.stderr)
            XCTAssertEqual(result.stdout, "isolated\n")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("requires /usr/bin/python3")
        }
        let input = Pipe()
        let output = Pipe()
        let fd = input.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        XCTAssertNotEqual(flags, -1)
        XCTAssertEqual(flags & O_NONBLOCK, 0)
        let child = Process()
        #if os(macOS)
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["-XCTest", "RaptorExecxTests.StdinIsolationTests/testCaptureCannotChangeParentPipeFlags",
                           Bundle(for: Self.self).bundleURL.path]
        #else
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["RaptorExecxTests.StdinIsolationTests/testCaptureCannotChangeParentPipeFlags"]
        #endif
        var environment = ProcessInfo.processInfo.environment
        environment[marker] = "1"
        child.environment = environment
        child.standardInput = input.fileHandleForReading
        child.standardOutput = output
        child.standardError = output
        try child.run()
        let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0, log)
        XCTAssertTrue(log.contains("Executed 1 test"), log)
        XCTAssertEqual(fcntl(fd, F_GETFL), flags, "child changed parent pipe flags")
        try input.fileHandleForWriting.close()
        try input.fileHandleForReading.close()
    }
}
