import Foundation

public struct SupervisorCommandOperations {
    public let state: () throws -> SupervisorState
    public let start: (SupervisorConfiguration) throws -> SupervisorState
    public let stop: (String, Int32) throws -> SupervisorState
    public let continueWork: (SupervisorContinuationRequest) throws -> SupervisorContinuationResult
    public let watch: (SupervisorWatchCursor, TimeInterval) throws -> SupervisorWatchResult

    public init(state: @escaping () throws -> SupervisorState,
                start: @escaping (SupervisorConfiguration) throws -> SupervisorState,
                stop: @escaping (String, Int32) throws -> SupervisorState,
                continueWork: @escaping (SupervisorContinuationRequest) throws -> SupervisorContinuationResult = { _ in throw TerminalError.invalid("Guarded continuation is unavailable") },
                watch: @escaping (SupervisorWatchCursor, TimeInterval) throws -> SupervisorWatchResult) {
        self.state = state
        self.start = start
        self.stop = stop
        self.continueWork = continueWork
        self.watch = watch
    }
}

public enum SupervisorCommand {
    public static func perform(arguments: [String], defaultCWD: String,
                               operations: SupervisorCommandOperations) throws -> JSONValue {
        guard let command = arguments.first else {
            throw TerminalError.invalid("Usage: supervisor state|start|stop|watch|continue")
        }
        let tail = Array(arguments.dropFirst())
        switch command {
        case "state":
            guard tail.isEmpty else { throw TerminalError.invalid("supervisor state takes no arguments") }
            return try .encoded(operations.state())
        case "continue":
            guard tail.count == 1 else { throw TerminalError.invalid("Usage: supervisor continue REQUEST_JSON") }
            return try .encoded(operations.continueWork(decodeContinuation(Data(tail[0].utf8))))
        case "start":
            let options = try parseOptions(tail, allowed: ["--provider", "--cwd", "--account"])
            let configuration = try configuration(provider: options["--provider"], accountID: options["--account"],
                                                  cwd: options["--cwd"] ?? defaultCWD)
            return try .encoded(operations.start(configuration))
        case "stop":
            guard tail.count == 2, let pid = Int32(tail[1]), pid > 1, UUID(uuidString: tail[0]) != nil else {
                throw TerminalError.invalid("Usage: supervisor stop PANE_ID BACKEND_PID")
            }
            return try .encoded(operations.stop(tail[0], pid))
        case "watch":
            guard let rawCursor = tail.first, rawCursor.utf8.count <= 1_048_576 else {
                throw TerminalError.invalid("Supervisor watch requires a bounded cursor JSON value")
            }
            let options = try parseOptions(Array(tail.dropFirst()), allowed: ["--timeout"])
            let timeout = try watchTimeout(options["--timeout"] ?? "2700")
            let cursor = try JSONDecoder().decode(SupervisorWatchCursor.self, from: Data(rawCursor.utf8))
            guard cursor.targets.count <= 4096 else { throw TerminalError.invalid("Supervisor cursor contains too many targets") }
            return try .encoded(operations.watch(cursor, timeout))
        default:
            throw TerminalError.invalid("Unknown Supervisor command")
        }
    }

    private static func parseOptions(_ arguments: [String], allowed: Set<String>) throws -> [String: String] {
        guard arguments.count % 2 == 0 else { throw TerminalError.invalid("Supervisor option requires a value") }
        var result: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[index]
            guard allowed.contains(key), result[key] == nil else {
                throw TerminalError.invalid("Unknown or repeated Supervisor option")
            }
            result[key] = arguments[index + 1]
        }
        return result
    }

    static func decodeContinuation(_ data: Data) throws -> SupervisorContinuationRequest {
        guard data.count <= 262_144,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["authority", "offer", "text"] else {
            throw TerminalError.invalid("Continuation requires a bounded authority, offer and text request")
        }
        return try JSONDecoder().decode(SupervisorContinuationRequest.self, from: data)
    }

    static func configuration(provider: String?, accountID: String?, cwd: String) throws -> SupervisorConfiguration {
        guard let agent = AgentKind(rawValue: provider ?? "claude"), agent != .shell else {
            throw TerminalError.invalid("Supervisor provider must be claude or codex")
        }
        guard cwd.hasPrefix("/"), cwd.utf8.count <= 4096, !cwd.contains("\0"),
              accountID == nil || UUID(uuidString: accountID!) != nil else {
            throw TerminalError.invalid("Invalid Supervisor working directory or account")
        }
        return SupervisorConfiguration(provider: agent, accountID: accountID, cwd: cwd)
    }

    private static func watchTimeout(_ value: String) throws -> TimeInterval {
        guard let timeout = TimeInterval(value), timeout.isFinite, timeout > 0, timeout <= 3600 else {
            throw TerminalError.invalid("Supervisor watch timeout must be between 0 and 3600 seconds")
        }
        return timeout
    }
}

public enum SupervisorAPI {
    public static func route(_ request: APIRequest, operations: SupervisorCommandOperations) throws -> JSONValue? {
        guard ["supervisor.state", "supervisor.start", "supervisor.stop", "supervisor.continue"].contains(request.method) else { return nil }
        guard request.apiVersion == 1 else { throw TerminalError.invalid("Unsupported Supervisor API version") }
        switch request.method {
        case "supervisor.state":
            guard request.params.isEmpty else { throw TerminalError.invalid("supervisor.state takes no parameters") }
            return try .encoded(operations.state())
        case "supervisor.continue":
            guard Set(request.params.keys) == ["request"], case .object? = request.params["request"] else {
                throw TerminalError.invalid("supervisor.continue requires one request object")
            }
            let data = try JSONEncoder().encode(request.params["request"]!)
            return try .encoded(operations.continueWork(SupervisorCommand.decodeContinuation(data)))
        case "supervisor.start":
            guard Set(request.params.keys).isSubset(of: ["provider", "accountID", "cwd"]),
                  let cwd = request.params["cwd"]?.text,
                  request.params["provider"] == nil || request.params["provider"]?.text != nil,
                  request.params["accountID"] == nil || request.params["accountID"]?.text != nil else {
                throw TerminalError.invalid("Invalid supervisor.start parameters")
            }
            let configuration = try SupervisorCommand.configuration(provider: request.params["provider"]?.text,
                accountID: request.params["accountID"]?.text, cwd: cwd)
            return try .encoded(operations.start(configuration))
        case "supervisor.stop":
            guard Set(request.params.keys) == ["paneID", "backendPID"],
                  let paneID = request.params["paneID"]?.text, UUID(uuidString: paneID) != nil,
                  case .number(let rawPID) = request.params["backendPID"], rawPID.isFinite,
                  rawPID.rounded(.towardZero) == rawPID, rawPID > 1, rawPID <= Double(Int32.max) else {
                throw TerminalError.invalid("supervisor.stop requires the expected paneID and backendPID")
            }
            return try .encoded(operations.stop(paneID, Int32(rawPID)))
        default: return nil
        }
    }
}
