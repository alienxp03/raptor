import Foundation
import Darwin

/// Lock-guarded descriptor so the listener thread and stop() agree without
/// touching MainActor state off the main thread.
private final class SocketHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1

    var descriptor: Int32 {
        lock.lock(); defer { lock.unlock() }
        return fd
    }

    func set(_ value: Int32) {
        lock.lock(); fd = value; lock.unlock()
    }

    /// Close and invalidate. A blocked accept wakes with EBADF or EINVAL.
    func closeSocket() {
        lock.lock()
        let current = fd
        fd = -1
        lock.unlock()
        if current >= 0 { Darwin.close(current) }
    }
}

/// Listens on a unix socket in the raptor cache directory. Only same-uid
/// peers are accepted. Blocking accept runs on one background thread; each
/// connection is bounded by socket timeouts.
@MainActor
final class PanelHost {
    var handle: @MainActor (PanelRequest) -> PanelReply
    private let socket = SocketHandle()
    private let path: String

    init(path: String, handle: @escaping @MainActor (PanelRequest) -> PanelReply) {
        self.path = path
        self.handle = handle
    }

    func start() throws {
        // A stale socket from a crashed host must not block the bind.
        unlink(path)
        let fd = socket_(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.posixError() }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let fits = path.withCString { source in
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                strlcpy(destination.baseAddress!.assumingMemoryBound(to: CChar.self), source, destination.count) < destination.count
            }
        }
        guard fits else {
            Darwin.close(fd)
            throw APIError.message("Panel socket path is too long.")
        }
        let bindResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw Self.posixError()
        }
        // Owner-only cache directory already; keep the socket private too.
        chmod(path, 0o600)
        guard listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw Self.posixError()
        }
        socket.set(fd)
        // Snapshot Sendable values; the thread never touches MainActor state.
        let sock = socket
        let handler = handle
        let thread = Thread {
            Self.listenLoop(socket: sock, handler: handler)
        }
        thread.name = "raptor.panel"
        thread.stackSize = 256 * 1024
        thread.start()
    }

    func stop() {
        guard socket.descriptor >= 0 else { return }
        socket.closeSocket()
        unlink(path)
    }

    private nonisolated static func posixError() -> POSIXError {
        // errno is always a value the code enum can represent.
        POSIXError(POSIXErrorCode(rawValue: errno)!)
    }

    private nonisolated static func listenLoop(socket: SocketHandle, handler: @MainActor (PanelRequest) -> PanelReply) {
        while true {
            let server = socket.descriptor
            guard server >= 0 else { return }
            let client = accept(server, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                return // Socket closed by stop().
            }
            var uid: uid_t = 0
            var gid: gid_t = 0
            if getpeereid(client, &uid, &gid) != 0 || uid != getuid() {
                Darwin.close(client)
                continue
            }
            let request = readRequest(client)
            DispatchQueue.main.sync {
                let reply = MainActor.assumeIsolated {
                    guard let request else { return PanelReply(ok: false, error: "invalid request") }
                    return handler(request)
                }
                writeReply(client, reply)
                Darwin.close(client)
            }
        }
    }

    private nonisolated static func readRequest(_ fd: Int32) -> PanelRequest? {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var received = Data()
        while !received.contains(0x0A) {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { return nil }
            received.append(contentsOf: buffer[..<count])
            if received.count > 64 * 1024 { return nil }
        }
        guard let newline = received.firstIndex(of: 0x0A) else { return nil }
        return try? JSONDecoder().decode(PanelRequest.self, from: received[..<newline])
    }

    private nonisolated static func writeReply(_ fd: Int32, _ reply: PanelReply) {
        guard var data = try? JSONEncoder().encode(reply) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { pointer in
            _ = write(fd, pointer.baseAddress, pointer.count)
        }
    }
}

// Darwin's socket() collides with the SocketHandle property name above.
private func socket_(_ domain: Int32, _ type: Int32, _ protocol: Int32) -> Int32 {
    Darwin.socket(domain, type, `protocol`)
}
