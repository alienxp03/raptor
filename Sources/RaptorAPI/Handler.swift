import Foundation
import RaptorCatalog
import RaptorConfig
import RaptorDispatch
import RaptorLauncherupdate
import RaptorPaths
import RaptorPullrequest
import RaptorRex
import RaptorTheme
import RaptorWorktree

/// Serves the persistent, line-delimited JSON protocol for native clients.
public final class Handler {
    /// Bounds one request, excluding its newline. Oversized lines are drained
    /// without growing memory, then the next request can be processed.
    public static let maxRequestSize = 1024 * 1024

    /// Bounds the concurrent per-host directory fetches.
    static let launcherDirWorkers = 4

    static let activitySnapshotTTL: TimeInterval = 2

    // cacheMu protects the snapshot caches, refresh state, and context capture.
    let cacheMu = NSLock()
    var ctx: Ctx
    let cfg: RaptorConfig

    var activityAgents: [AgentEntry] = []
    var activityAt = Date()
    var activityGeneration: UInt64 = 0
    var generation: UInt64 = 0
    var launcherGeneration: UInt64 = 0
    var revalidating = false
    var launcher = LauncherCacheEntry()
    var launcherLoaded = false
    var activityLoaded = false
    var refreshDone: Broadcast?
    var snapshotChanged = Broadcast()
    var refreshPending = false
    var refreshLauncher = false
    var presentation: UInt64 = 0
    var notify: (() -> Void)?
    var loadSnapshot: SnapshotLoader?
    var ranks = SessionRecency()
    var loadRecency: (() -> SessionRecency)?
    var focus: FocusWorker?
    var validateFocus: ((CancelToken, Int) -> Bool)?
    var resolveFocus: ((String) -> (host: String, ok: Bool))?
    var recordFocus: ((String, String, Date, Bool) -> Void)?
    var deleteTickets: [String: SessionDeletionTicket] = [:]
    var worktreeReviewTickets: [String: WorktreeReviewTicket] = [:]
    var deletionTombstones: [DeletionTombstone] = []
    var loadDeletionSession: ((String, String) throws -> DeletionSessionState)?
    var runDeletionCommand: ((String, String, String) -> DeletionCommand)?
    var closeDeletedSession: ((String, String) throws -> Void)?

    public init(ctx: Ctx, cfg: RaptorConfig) {
        self.ctx = ctx
        self.cfg = cfg
        ranks = Rex.loadSessionRecency()
    }

    func ctxSnapshot() -> (session: String, block: String, client: String, title: String) {
        cacheMu.lock()
        defer { cacheMu.unlock() }
        return (ctx.session, ctx.block, ctx.client, ctx.title)
    }

    // MARK: - protocol loop

    /// Serve writes protocol responses and opt-in rex.changed notifications.
    /// Invalid envelopes use id 0 when their integer id cannot be read.
    public func serve(input: RequestInput, output: ResponseOutput) throws {
        try serveContext(input: input, output: output, cancel: CancelToken())
    }

    /// ServeContext also cancels long-lived Rex children when the owner shuts down.
    public func serveContext(input: RequestInput, output: ResponseOutput, cancel: CancelToken) throws {
        let stopFocus = startFocusWorker(cancel)
        defer { stopFocus() }

        // A standard-input pipe can remain in a blocking read after SIGTERM.
        // Keep that read off the owner thread so it can reap its Rex children.
        let feed = LineFeed()
        let pump = Thread { [weak self] in
            guard self != nil else { return }
            let reader = LineReader(input)
            while !cancel.isCancelled {
                let item: LineFeed.Item
                do {
                    let (line, oversized, eof) = try reader.next()
                    item = LineFeed.Item(line: line, oversized: oversized, eof: eof, error: nil)
                } catch {
                    item = LineFeed.Item(line: Data(), oversized: false, eof: false, error: error)
                }
                feed.push(item)
                if item.eof || item.error != nil {
                    return
                }
            }
        }
        pump.name = "api-input-pump"
        pump.start()

        let outputLock = NSLock()
        var outputErr: Error?
        func write(_ text: String) -> Error? {
            outputLock.lock()
            defer { outputLock.unlock() }
            if outputErr == nil {
                do {
                    var data = Data(text.utf8)
                    data.append(0x0A)
                    try output.writeChunk(data)
                } catch {
                    outputErr = error
                }
            }
            return outputErr
        }

        final class WatchState {
            var pump: APIEventPump?
        }
        let watch = WatchState()

        func stop() {
            cacheMu.lock()
            presentation += 1
            notify = nil
            refreshPending = false
            cacheMu.unlock()
            watch.pump?.close()
            watch.pump = nil
        }
        defer { stop() }

        while true {
            guard !cancel.isCancelled else { return }
            guard let next = feed.pop(timeout: 0.05) else { continue }
            if let error = next.error {
                throw error
            }
            let line = next.line
            let oversized = next.oversized
            let eof = next.eof
            if line.isEmpty && !oversized && eof {
                stop()
                outputLock.lock()
                defer { outputLock.unlock() }
                if let outputErr {
                    throw outputErr
                }
                return
            }

            var resID: Int64 = 0
            var resResult: MethodResult?
            var resError: String?

            if oversized {
                resError = "request exceeds maximum size"
            } else {
                let parsed = parseRequest(line)
                switch parsed {
                case .failure(let failure):
                    if let id = failure.id {
                        resID = id
                    }
                    resError = failure.message
                case .success(let req):
                    if let id = req.id {
                        resID = id
                    }
                    if req.id == nil || req.method.isEmpty {
                        resError = "request requires integer id and method"
                    } else if !req.paramsIsObject {
                        resError = "params must be an object"
                    } else if req.method == "events.subscribe" {
                        let params: JSONValue
                        do {
                            var parser = JSONParser(req.params)
                            params = try parser.parseTop().value
                        } catch {
                            params = .null
                            resError = "invalid character looking for beginning of value"
                        }
                        if resError == nil {
                            do {
                                let enabled = try Params.bool(params, "enabled")
                                stop()
                                if enabled {
                                    captureRecency(true)
                                    cacheMu.lock()
                                    notify = { [weak self] in
                                        guard self != nil else { return }
                                        _ = write("{\"event\":\(JS.escapeGo("rex.changed"))}")
                                    }
                                    cacheMu.unlock()
                                    let pump = APIEventPump { [weak self] in
                                        self?.requestLiveRefresh()
                                    }
                                    watch.pump = pump
                                    pump.start()
                                }
                                resResult = .empty
                            } catch {
                                resError = String(describing: error)
                            }
                        }
                    } else {
                        let (result, callErr) = call(cancel, req.method, req.params)
                        if cancel.isCancelled {
                            return
                        }
                        if let callErr {
                            resError = String(describing: callErr)
                        } else {
                            resResult = result
                        }
                    }
                }
            }

            var fields: [(String, JS)] = [("id", .int(resID))]
            if let result = resResult {
                fields.append(("result", .raw(result.encode())))
            }
            if let error = resError {
                fields.append(("error", .string(error)))
            }
            if let writeErr = write(JS.object(fields).encode()) {
                throw writeErr
            }
            if eof {
                return
            }
        }
    }

    // MARK: - request envelope

    struct ParsedRequest {
        var id: Int64?
        var method: String
        var params: [UInt8]
        var paramsIsObject: Bool
    }

    struct ParseFailure: Error {
        var id: Int64?
        var message: String
    }

    enum RequestParseOutcome {
        case success(ParsedRequest)
        case failure(ParseFailure)
    }

    func parseRequest(_ line: Data) -> RequestParseOutcome {
        let lineBytes = [UInt8](line)
        var parser = JSONParser(lineBytes)
        let node: JSONNode
        do {
            node = try parser.parseTop()
        } catch {
            return .failure(ParseFailure(id: nil, message: "invalid request: invalid character looking for beginning of value"))
        }
        guard case .object(let fields) = node.value else {
            return .failure(ParseFailure(id: nil, message: "invalid request: cannot unmarshal into request envelope"))
        }
        var id: Int64?
        var idError: String?
        var method = ""
        var params: [UInt8]?
        var paramsIsObject = false
        var decodeError: String?
        for (key, fieldNode) in fields {
            let value = fieldNode.value
            switch key {
            case "id":
                switch value {
                case .null:
                    break
                case .number(let literal):
                    if let parsed = Int64(literal) {
                        id = parsed
                    } else {
                        idError = "json: cannot unmarshal number \(literal) into Go struct field request.id of type int64"
                    }
                default:
                    idError = "json: cannot unmarshal \(value.kindName) into Go struct field request.id of type int64"
                }
            case "method":
                if case .string(let s) = value {
                    method = s
                } else if case .null = value {
                    break
                } else {
                    decodeError = "json: cannot unmarshal \(value.kindName) into Go struct field request.method of type string"
                }
            case "params":
                if case .null = value {
                    break
                }
                // Raw slice of the original line, like Go's json.RawMessage.
                params = Array(lineBytes[fieldNode.start..<fieldNode.end])
                if case .object = value {
                    paramsIsObject = true
                }
            default:
                continue
            }
        }
        if let idError {
            return .failure(ParseFailure(id: id, message: "invalid request: " + idError))
        }
        if let decodeError {
            return .failure(ParseFailure(id: id, message: "invalid request: " + decodeError))
        }
        return .success(ParsedRequest(
            id: id, method: method, params: params ?? [], paramsIsObject: paramsIsObject))
    }
}
