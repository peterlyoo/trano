import Foundation
import TerminalCore

enum TwinBridgeCLI {
    private static let commands: Set<String> = ["report", "respond", "hook", "diff", "commit"]
    static func handles(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if arguments.first == "decision-adapter", environment["TRANO_TWIN_API_SOCKET"] != nil { return true }
        return arguments.count >= 2 && arguments[0] == "twin" && commands.contains(arguments[1])
    }
    static func execute(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
        readInput: () -> Data = { TwinBridgeCLI.readBoundedInput() },
        call: (String, APIRequest) throws -> APIResponse = { try APIClient(path: $0).call($1) },
        write: (Data) -> Void = { FileHandle.standardOutput.write($0) },
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        decisionCall: @escaping (String, JSONValue) throws -> JSONValue = { try DecisionAdapterClient(path: $0).call($1) }) throws -> Int32 {
        if arguments.first == "decision-adapter" {
            guard environment["TRANO_TWIN_API_SOCKET"] != nil, arguments.count >= 2,
                  ["ask", "submit", "poll", "gate", "help", "--help", "-h"].contains(arguments[1]) else {
                throw TerminalError.invalid("Scoped twin decisions support ask, submit, poll and gate only")
            }
            let socket = try socketPath(environment)
            return DecisionAdapterCommand.run(arguments: Array(arguments.dropFirst()), socketPath: socket,
                input: { readInput() }, output: write, transport: { request in
                    guard let type = request["type"], [.string("submit"), .string("poll"), .string("gate")].contains(type),
                          try JSONEncoder().encode(request).count <= 512 * 1024 else { throw TerminalError.invalid("Invalid scoped twin decision request") }
                    let response = try decisionCall(socket, request)
                    guard try JSONEncoder().encode(response).count <= 512 * 1024 else { throw TerminalError.invalid("Scoped decision response exceeds 512 KiB") }
                    return response
                }, sleep: wait, now: { Date(timeIntervalSince1970: now()) }, environment: environment)
        }
        guard handles(arguments, environment: environment), arguments.count >= 3, let identity = UUID(uuidString: arguments[2]) else {
            throw TerminalError.invalid("Twin helper requires report, respond, hook, diff or commit and a run UUID")
        }
        let command = arguments[1]
        var roundText: String?, message: String?, index = 3
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw TerminalError.invalid("Twin helper option requires a value") }
            switch arguments[index] {
            case "--round":
                guard roundText == nil else { throw TerminalError.invalid("Twin round cannot be repeated") }
                roundText = arguments[index + 1]
            case "--message":
                guard command == "commit", message == nil else { throw TerminalError.invalid("Only twin commit accepts one message") }
                message = arguments[index + 1]
            default: throw TerminalError.invalid("Unknown twin helper option")
            }
            index += 2
        }
        guard let text = roundText ?? environment["TRANO_TWIN_ROUND"], let round = Int(text), (1...8).contains(round) else {
            throw TerminalError.invalid("Twin helper requires a round from 1 to 8")
        }
        if command == "commit" {
            guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  message.utf8.count <= 4096, !message.utf8.contains(0) else { throw TerminalError.invalid("Twin commit requires a message of at most 4096 bytes") }
        }
        let socket = try socketPath(environment)
        var params: [String: JSONValue] = ["runID": .string(identity.uuidString.lowercased()), "round": .number(Double(round))]
        if ["report", "respond", "hook"].contains(command) {
            let data = readInput(), limit = command == "hook" ? 512 * 1024 : 16 * 1024
            guard !data.isEmpty, data.count <= limit,
                  let object = try? JSONDecoder().decode(JSONValue.self, from: data), case .object = object else {
                throw TerminalError.invalid("Twin helper input must be a bounded JSON object")
            }
            params[command == "hook" ? "payload" : "envelope"] = object
        }
        if let message { params["message"] = .string(message) }
        let request = APIRequest(method: "twins." + command, params: params)
        guard try JSONEncoder().encode(request).count <= 1_048_576 else { throw TerminalError.invalid("Twin helper API frame exceeds 1 MiB") }
        let started = now()
        guard started.isFinite else { throw TerminalError.runtime("Twin helper clock is unavailable") }
        var waited: TimeInterval = 0
        while true {
            let response = try call(socket, request)
            guard response.apiVersion == 1 else { throw TerminalError.runtime("Unsupported twin helper API version") }
            if let error = response.error { throw TerminalError.runtime(error) }
            guard let result = response.result ?? (command == "hook" ? .null : nil) else { throw TerminalError.runtime("Twin helper API returned no result") }
            if command == "commit", result["status"] == .string("busy") {
                let current = now()
                guard current.isFinite else { throw TerminalError.runtime("Twin helper clock is unavailable") }
                let remaining = min(30 - waited, 30 - max(0, current - started))
                if remaining <= 0 { try emit(result, write: write); return 75 }
                let requested: TimeInterval
                if case .number(let value)? = result["retryAfterMs"], value.isFinite { requested = min(1, max(0.25, value / 1000)) }
                else { requested = 0.25 }
                let delay = min(requested, remaining)
                wait(delay); waited += delay
                continue
            }
            if command == "diff" {
                guard case .string(let diff)? = result["diff"], diff.utf8.count <= 8 * 1024 * 1024 else { throw TerminalError.runtime("Twin diff response is invalid or too large") }
                write(Data(diff.utf8))
            } else if command != "hook" || result != .null {
                try emit(result, write: write)
            }
            return 0
        }
    }
    private static func socketPath(_ environment: [String: String]) throws -> String {
        let path: String
        if let scoped = environment["TRANO_TWIN_API_SOCKET"] { path = scoped }
        else {
            let root = environment["TRANO_DATA_DIR"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/trano").path
            guard absolute(root) else { throw TerminalError.invalid("Invalid twin helper data directory") }
            path = root + (root.hasSuffix("/") ? "" : "/") + "api.sock"
        }
        guard absolute(path), path.utf8.count < 104 else { throw TerminalError.invalid("Invalid twin helper API socket path") }
        return path
    }
    private static func absolute(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
    private static func readBoundedInput() -> Data {
        let limit = 512 * 1024 + 1
        var result = Data()
        while result.count < limit {
            let next = FileHandle.standardInput.readData(ofLength: min(16 * 1024, limit - result.count))
            if next.isEmpty { break }
            result.append(next)
        }
        return result
    }
    private static func emit(_ value: JSONValue, write: (Data) -> Void) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value); data.append(10); write(data)
    }
}
