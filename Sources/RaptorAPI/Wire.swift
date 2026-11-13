import Foundation

/// IO errors mirroring the Go test seams (io.ErrUnexpectedEOF / io.ErrClosedPipe).
public enum StreamError: Error, Equatable {
    case unexpectedEOF
    case closedPipe
    case message(String)
}

/// Cancellation token standing in for Go's context.Context.
public final class CancelToken: @unchecked Sendable {
    private let cond = NSCondition()
    private var cancelled = false

    public init() {}

    public func cancel() {
        cond.lock()
        cancelled = true
        cond.broadcast()
        cond.unlock()
    }

    public var isCancelled: Bool {
        cond.lock()
        defer { cond.unlock() }
        return cancelled
    }

    /// Blocks until cancel() (used by test hooks standing in for ctx.Done()).
    public func wait() {
        cond.lock()
        while !cancelled {
            cond.wait()
        }
        cond.unlock()
    }
}

/// Source of request bytes: empty Data means EOF, throws on hard IO errors.
public protocol RequestInput: AnyObject {
    func readChunk() throws -> Data
}

/// Sink for NDJSON response bytes; throws on write errors.
public protocol ResponseOutput: AnyObject {
    func writeChunk(_ data: Data) throws
}

/// In-memory input over fixed bytes (Go's strings.NewReader).
public final class DataInput: RequestInput {
    private var bytes: [UInt8]
    private var index = 0

    public init(_ data: Data) {
        bytes = [UInt8](data)
    }

    public init(_ text: String) {
        bytes = Array(text.utf8)
    }

    public func readChunk() throws -> Data {
        if index >= bytes.count {
            return Data()
        }
        let chunk = Array(bytes[index..<min(index + 64 * 1024, bytes.count)])
        index += chunk.count
        return Data(chunk)
    }
}

/// In-memory output buffer (Go's bytes.Buffer).
public final class DataOutput: ResponseOutput {
    public private(set) var data = Data()

    public init() {}

    public func writeChunk(_ block: Data) throws {
        data.append(block)
    }

    public var text: String {
        String(decoding: data, as: UTF8.self)
    }

    /// Clears the buffer (tests reuse one output across requests).
    public func reset() {
        data.removeAll()
    }
}

/// Pipe-backed endpoints (Foundation Pipe / io.Pipe stand-ins).
public final class PipeInput: RequestInput {
    private let handle: FileHandle

    public init(_ pipe: Pipe) {
        handle = pipe.fileHandleForReading
    }

    public init(_ handle: FileHandle) {
        self.handle = handle
    }

    public func readChunk() throws -> Data {
        // availableData raises an uncatchable Objective-C exception when the
        // read fails at the OS level (the app closed its pipe end), and the
        // backend dies mid-loop: the app then reports a closed connection
        // until relaunched. POSIX read reports the same condition as an errno
        // instead, and an empty chunk still means EOF.
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                return Data(buffer.prefix(count))
            }
            if count == 0 {
                return Data()
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                // A pipe can be nonblocking (or have its shared flags changed).
                // No bytes available is not EOF. Wait without spinning, then
                // retry the read; the serve loop handles owner cancellation.
                var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
                if Darwin.poll(&descriptor, 1, 200) >= 0 || errno == EINTR { continue }
            }
            throw StreamError.closedPipe
        }
    }
}

public final class PipeOutput: ResponseOutput {
    private let handle: FileHandle

    public init(_ pipe: Pipe) {
        handle = pipe.fileHandleForWriting
    }

    public init(_ handle: FileHandle) {
        self.handle = handle
    }

    public func writeChunk(_ data: Data) throws {
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw StreamError.closedPipe
        }
    }
}

/// Delimits NDJSON frames with the Go reader's byte budget: lines above
/// MaxRequestSize are drained (discarded) and reported oversized; the limit
/// excludes the newline. Data before EOF still yields a final line.
final class LineReader {
    private let input: RequestInput
    private var buffer: [UInt8] = []

    init(_ input: RequestInput) {
        self.input = input
    }

    /// Returns (line, oversized, eof). Throws hard IO errors.
    func next() throws -> (line: Data, oversized: Bool, eof: Bool) {
        var line: [UInt8] = []
        var oversized = false
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let part = Array(buffer[0..<newline])
                buffer.removeSubrange(0...newline)
                if !oversized {
                    if line.count + part.count > Handler.maxRequestSize {
                        oversized = true
                        line = []
                    } else {
                        line.append(contentsOf: part)
                    }
                }
                return (Data(line), oversized, false)
            }
            let part = buffer
            buffer.removeAll()
            if !oversized {
                if line.count + part.count > Handler.maxRequestSize {
                    oversized = true
                    line = []
                } else {
                    line.append(contentsOf: part)
                }
            }
            let chunk = try input.readChunk()
            if chunk.isEmpty {
                return (Data(line), oversized, true)
            }
            buffer.append(contentsOf: [UInt8](chunk))
        }
    }
}

/// Broadcast gate standing in for Go's closed chan struct{}: waiters wake when
/// fired; the gate stays fired.
final class Broadcast {
    private let cond = NSCondition()
    private var fired = false

    func fire() {
        cond.lock()
        fired = true
        cond.broadcast()
        cond.unlock()
    }

    var isFired: Bool {
        cond.lock()
        defer { cond.unlock() }
        return fired
    }

    /// Waits until fired or the deadline passes.
    func wait(until deadline: Date) {
        cond.lock()
        while !fired {
            if !cond.wait(until: deadline) {
                break
            }
        }
        cond.unlock()
    }
}

/// Capacity-1 wakeup standing in for Go's `chan struct{}` with a buffered send.
final class Wakeup {
    private let cond = NSCondition()
    private var signaled = false

    func notify() {
        cond.lock()
        signaled = true
        cond.signal()
        cond.unlock()
    }

    /// Consumes one pending signal, waiting up to the timeout.
    func wait(_ timeout: TimeInterval) {
        cond.lock()
        let deadline = Date().addingTimeInterval(timeout)
        while !signaled {
            if !cond.wait(until: deadline) {
                break
            }
        }
        signaled = false
        cond.unlock()
    }
}

/// One-item handoff from the input pump thread to the serve loop.
final class LineFeed {
    struct Item {
        var line: Data
        var oversized: Bool
        var eof: Bool
        var error: Error?
    }

    private let cond = NSCondition()
    private var items: [Item] = []

    func push(_ item: Item) {
        cond.lock()
        items.append(item)
        cond.signal()
        cond.unlock()
    }

    /// Pops within the timeout; nil when nothing arrived.
    func pop(timeout: TimeInterval) -> Item? {
        cond.lock()
        defer { cond.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while items.isEmpty {
            if !cond.wait(until: deadline) {
                break
            }
        }
        return items.isEmpty ? nil : items.removeFirst()
    }
}
