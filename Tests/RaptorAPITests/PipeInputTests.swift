import Darwin
import Foundation
import XCTest
@testable import RaptorAPI

final class PipeInputTests: XCTestCase {
    func testNonblockingPipeWaitsForBytesAndOnlyEndsOnEOF() throws {
        let pipe = Pipe()
        let reader = PipeInput(pipe)
        let fd = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        XCTAssertNotEqual(flags, -1)
        XCTAssertNotEqual(fcntl(fd, F_SETFL, flags | O_NONBLOCK), -1)
        defer { try? pipe.fileHandleForWriting.close() }

        final class State: @unchecked Sendable {
            let lock = NSLock()
            let received = DispatchSemaphore(value: 0)
            var chunks: [Data] = []
            var failure: Error?
            func append(_ data: Data) {
                lock.lock(); chunks.append(data); lock.unlock()
                received.signal()
            }
            func fail(_ error: Error) {
                lock.lock(); failure = error; lock.unlock()
                received.signal()
            }
        }
        let state = State()
        let worker = Thread {
            do {
                for _ in 0..<3 { state.append(try reader.readChunk()) }
            } catch { state.fail(error) }
        }
        worker.start()
        // An empty, open nonblocking pipe returns EAGAIN, not EOF or a failure.
        guard state.received.wait(timeout: .now() + 0.1) == .timedOut else {
            return XCTFail("Reader treated temporary unavailability as a closed pipe")
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("first\n".utf8))
        XCTAssertEqual(state.received.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(state.received.wait(timeout: .now() + 0.1), .timedOut,
                       "The next idle read must also wait rather than terminate")
        try pipe.fileHandleForWriting.write(contentsOf: Data("second\n".utf8))
        XCTAssertEqual(state.received.wait(timeout: .now() + 2), .success)
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(state.received.wait(timeout: .now() + 2), .success)
        state.lock.lock()
        let chunks = state.chunks
        let failure = state.failure
        state.lock.unlock()
        XCTAssertNil(failure)
        XCTAssertEqual(chunks, [Data("first\n".utf8), Data("second\n".utf8), Data()])
    }
}
