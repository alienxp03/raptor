import Foundation
import RaptorPaths
import RaptorService

/// The client side of the resident host IPC. One short-lived connection per
/// open: write a request, read a reply, close. The host lives in the Raptor
/// app (serve mode) and keeps the panel plus backend pre-created. Ported from
/// internal/panel.

/// Request opens (or toggles) the panel. Empty fields keep their defaults.
public struct Request: Codable {
    public var action: String // "open" or "ping"
    public var mode: String
    public var session: String
    public var block: String
    public var client: String
    public var title: String
    public var repo: String

    enum CodingKeys: String, CodingKey {
        case action, mode, session, block, client, title, repo
    }

    public init(
        action: String = "",
        mode: String = "",
        session: String = "",
        block: String = "",
        client: String = "",
        title: String = "",
        repo: String = ""
    ) {
        self.action = action
        self.mode = mode
        self.session = session
        self.block = block
        self.client = client
        self.title = title
        self.repo = repo
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? ""
        session = try c.decodeIfPresent(String.self, forKey: .session) ?? ""
        block = try c.decodeIfPresent(String.self, forKey: .block) ?? ""
        client = try c.decodeIfPresent(String.self, forKey: .client) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(action, forKey: .action)
        // Go omitempty: empty strings stay off the wire.
        if !mode.isEmpty { try c.encode(mode, forKey: .mode) }
        if !session.isEmpty { try c.encode(session, forKey: .session) }
        if !block.isEmpty { try c.encode(block, forKey: .block) }
        if !client.isEmpty { try c.encode(client, forKey: .client) }
        if !title.isEmpty { try c.encode(title, forKey: .title) }
        if !repo.isEmpty { try c.encode(repo, forKey: .repo) }
    }
}

/// The host's one-line answer.
public struct Reply: Codable, Equatable {
    public var ok: Bool
    public var error: String

    enum CodingKeys: String, CodingKey {
        case ok, error
    }

    public init(ok: Bool = false, error: String = "") {
        self.ok = ok
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ok, forKey: .ok)
        if !error.isEmpty { try c.encode(error, forKey: .error) }
    }
}

/// Error carrying a Go-style message.
public struct PanelError: Error, CustomStringConvertible {
    public var message: String
    public var description: String { message }
}

/// Says no resident host answered; callers may fall back.
public struct UnavailableError: Error, CustomStringConvertible {
    public var message = "panel host is not running"
    public var description: String { message }
}

public enum Panel {
    public static let errUnavailable = UnavailableError()

    /// Sends one request and reads one reply.
    public static func call(_ req: Request) throws -> Reply {
        var req = req
        if req.action.isEmpty {
            req.action = "open"
        }
        guard let fd = dial(path: RaptorPaths.panelSocket(), timeout: 1) else {
            throw errUnavailable
        }
        defer { close(fd) }
        // Go: SetDeadline(now + 2s) over the whole exchange.
        setDeadline(fd: fd, seconds: 2)
        setBlocking(fd: fd)
        guard let payload = try? JSONEncoder().encode(req) else {
            throw PanelError(message: "encode panel request")
        }
        var wire = payload
        wire.append(UInt8(ascii: "\n"))
        if !writeAll(fd: fd, data: wire) {
            throw errUnavailable
        }
        let line = try readLine(fd: fd)
        do {
            return try JSONDecoder().decode(Reply.self, from: line)
        } catch {
            throw PanelError(message: "invalid panel host reply: \(error)")
        }
    }

    /// Opens the panel, starting the resident host once when it is down.
    /// ErrUnavailable propagates when even the restart fails so callers can
    /// fall back to Launch Services.
    public static func open(_ req: Request) throws {
        var reply = Reply()
        var err: Error?
        do {
            reply = try call(req)
            err = nil
        } catch {
            err = error
        }
        if err is UnavailableError {
            do {
                try Service.kickstart()
            } catch {
                throw errUnavailable
            }
            let deadline = Date().addingTimeInterval(3)
            while true {
                do {
                    reply = try call(req)
                    err = nil
                } catch {
                    err = error
                }
                if err == nil || !(err is UnavailableError) || Date() > deadline {
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        if let err {
            throw err
        }
        if !reply.ok {
            throw PanelError(message: reply.error)
        }
    }

    // MARK: - Unix socket plumbing (POSIX, synchronous like Go's net.DialTimeout)

    /// Connects to a unix socket with a connect timeout. Returns the fd or nil.
    static func dial(path: String, timeout: TimeInterval) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            dest.baseAddress!.copyMemory(from: bytes, byteCount: bytes.count)
            dest[bytes.count] = 0
        }
        // Non-blocking connect so DialTimeout can be honored.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let connectResult = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult == 0 {
            return fd
        }
        if errno == EINPROGRESS {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, Int32(timeout * 1000))
            if ready > 0 {
                var soError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
                if soError == 0 {
                    return fd
                }
            }
        }
        close(fd)
        return nil
    }

    /// Go's SetDeadline equivalent: one socket timeout for sends and receives.
    static func setDeadline(fd: Int32, seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func setBlocking(fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
    }

    static func writeAll(fd: Int32, data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return false }
            while offset < data.count {
                let n = write(fd, base.advanced(by: offset), data.count - offset)
                if n <= 0 {
                    return false
                }
                offset += n
            }
            return true
        }
    }

    /// Reads one '\n'-terminated line like bufio.Reader.ReadBytes('\n').
    static func readLine(fd: Int32) throws -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 {
                throw PanelError(message: "panel host closed the connection: \(errnoText())")
            }
            buffer.append(contentsOf: chunk[0..<n])
            if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                return buffer[...newlineIndex]
            }
        }
    }

    static func errnoText() -> String {
        String(cString: strerror(errno))
    }
}
