import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct DecisionAdapterClient {
    public let path: String
    public init(path: String) { self.path = path }
    public func call(_ request: JSONValue) throws -> JSONValue {
        let data = try JSONEncoder().encode(request)
        guard data.count <= 512 * 1024 else { throw TerminalError.invalid("Decision frame exceeds 512 KiB") }
        let fd = try UnixSocket.make()
        defer { close(fd) }
        guard try UnixSocket.address(path, { connect(fd, $0, $1) }) == 0 else { throw TerminalError.runtime("Decision adapter is unavailable") }
        try UnixSocket.sendLine(data, fd: fd)
        _ = shutdown(fd, SHUT_WR)
        let response = try UnixSocket.receiveLine(fd: fd)
        guard response.count <= 512 * 1024 else { throw TerminalError.invalid("Decision response exceeds 512 KiB") }
        let value = try JSONDecoder().decode(JSONValue.self, from: response)
        guard value["ok"] == .bool(true) || value["ok"] == .bool(false) else { throw TerminalError.invalid("Invalid decision adapter response") }
        return value
    }
}

extension TerminalRuntime {
    public func decisionEnvironment(_ environment: [String: String]) throws -> [String: String] {
        try transaction {
            let shell = try ManagedDirectory.ensure(root, component: "shell")
            let bin = try ManagedDirectory.ensure(shell, component: "bin")
            let shim = bin.appendingPathComponent("easydecision-adapter")
            let marker = bin.appendingPathComponent(".trano-decision-adapter")
            func ownedFile(_ path: URL) throws -> Bool {
                var info = stat()
                if lstat(path.path, &info) != 0 {
                    if errno == ENOENT { return false }
                    throw TerminalError.invalid("Cannot inspect native decision adapter")
                }
                guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
                    throw TerminalError.invalid("Native decision adapter must be an owned private regular file")
                }
                return true
            }
            let hasShim = try ownedFile(shim), hasMarker = try ownedFile(marker)
            guard !hasShim || hasMarker else { throw TerminalError.invalid("Refusing to replace unmanaged decision adapter") }
            if hasMarker, (try String(contentsOf: marker, encoding: .utf8)) != "trano-decision-adapter-v1\n" {
                throw TerminalError.invalid("Unknown native decision adapter ownership marker")
            }
            let script = "#!/bin/sh\nexec \"$TRANO_CLI_PATH\" decision-adapter \"$@\"\n"
            let current = hasShim ? try String(contentsOf: shim, encoding: .utf8) : nil
            if current != script { try Self.atomicWrite(Data(script.utf8), to: shim) }
            if !hasMarker { try Self.atomicWrite(Data("trano-decision-adapter-v1\n".utf8), to: marker) }
            guard chmod(shim.path, 0o700) == 0 else { throw TerminalError.runtime("Cannot make native decision adapter executable") }
            var result = environment
            let paths = (result["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init).filter { $0 != bin.path }
            result["PATH"] = ([bin.path] + paths).joined(separator: ":")
            result["EASYDECISION_ADAPTER_BIN"] = shim.path
            result["EASYDECISION_SOCKET"] = root.appendingPathComponent("api.sock").path
            result["TRANO_SHELL_DIR"] = shell.path
            result["TRANO_DATA_DIR"] = root.path
            if let helperExecutable { result["TRANO_CLI_PATH"] = helperExecutable }
            return result
        }
    }
}

public enum DecisionAdapterCommand {
    public static func run(arguments: [String], socketPath: String, input: () throws -> Data, output: (Data) -> Void,
                           transport: ((JSONValue) throws -> JSONValue)? = nil,
                           sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }, now: () -> Date = { Date() },
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        func emit(_ value: JSONValue) {
            if var data = try? JSONEncoder().encode(value) { data.append(10); output(data) }
        }
        func fail(_ code: String, _ detail: String) -> Int32 {
            emit(.object(["ok": .bool(false), "error": .string(code), "detail": .string(detail)]))
            return 2
        }
        let command = arguments.first ?? "help"
        if ["help", "--help", "-h"].contains(command) {
            output(Data("easydecision-adapter ask|submit (JSON stdin)\neasydecision-adapter poll UUID [--wait-ms N] [--interval-ms N]\neasydecision-adapter abandon UUID\neasydecision-adapter gate --agent codex|claude --session-id ID\n".utf8))
            return 0
        }
        if ["context", "ack"].contains(command) { return fail("UNSUPPORTED_FEATURE", "Hosted discussions are unavailable in Trano") }
        guard ["ask", "submit", "poll", "abandon", "gate"].contains(command) else { return fail("UNKNOWN_COMMAND", command) }
        func integer(_ name: String, fallback: Int, maximum: Int) throws -> Int {
            guard let index = arguments.firstIndex(of: name) else { return fallback }
            guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value > 0, value <= maximum else {
                throw TerminalError.invalid(name + " must be a positive integer no greater than " + String(maximum))
            }
            return value
        }
        func option(_ name: String) throws -> String {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                throw TerminalError.invalid("Missing " + name)
            }
            return arguments[index + 1]
        }
        let initial: JSONValue
        let wait: Int
        let interval: Int
        var requestID: String?
        do {
            wait = try integer("--wait-ms", fallback: command == "ask" ? 30_000 : 0, maximum: 300_000)
            interval = try integer("--interval-ms", fallback: 2000, maximum: 300_000)
            if command == "ask" || command == "submit" {
                let data = try input()
                guard data.count <= 512 * 1024 else { return fail("INVALID_INPUT", "Question exceeds 512 KiB") }
                let question = try JSONDecoder().decode(JSONValue.self, from: data)
                guard let id = question["request_id"]?.text, UUID(uuidString: id) != nil else { return fail("INVALID_INPUT", "Question requires a UUID request_id") }
                requestID = id
                var fields: [String: JSONValue] = ["type": .string("submit"), "question": question]
                if environment["TRANO_SESSION"] != nil || environment["TRANO_LAUNCH_ID"] != nil {
                    guard let pane = environment["TRANO_SESSION"], !pane.isEmpty,
                          let generation = environment["TRANO_LAUNCH_ID"], !generation.isEmpty else {
                        return fail("INVALID_INPUT", "Native decisions require both TRANO_SESSION and TRANO_LAUNCH_ID")
                    }
                    fields["trano_binding"] = .object(["pane_id": .string(pane), "generation": .string(generation)])
                }
                initial = .object(fields)
            } else if command == "gate" {
                let agent = try option("--agent"), session = try option("--session-id")
                guard ["claude", "codex"].contains(agent), !session.isEmpty else { return fail("INVALID_ARGUMENT", "gate requires an agent and session ID") }
                initial = .object(["type": .string("gate"), "agent": .string(agent), "session_id": .string(session)])
            } else {
                guard arguments.count > 1, UUID(uuidString: arguments[1]) != nil else { return fail("INVALID_ARGUMENT", command + " requires a UUID") }
                requestID = arguments[1]
                initial = .object(["type": .string(command), "request_id": .string(arguments[1])])
            }
        } catch { return fail("INVALID_INPUT", error.localizedDescription) }
        do {
            let exchange = transport ?? { try DecisionAdapterClient(path: socketPath).call($0) }
            func send(_ request: JSONValue) throws -> JSONValue {
                let response = try exchange(request)
                guard response["ok"] == .bool(true) || response["ok"] == .bool(false) else {
                    throw TerminalError.runtime("The endpoint does not support the decision adapter protocol")
                }
                return response
            }
            var response = try send(initial)
            let deadline = now().addingTimeInterval(Double(wait) / 1000)
            if command == "ask" || command == "poll", let requestID {
                while response["ok"] == .bool(true), response["status"] == .string("pending"), now() < deadline {
                    sleep(min(Double(interval) / 1000, max(0, deadline.timeIntervalSince(now()))))
                    response = try send(.object(["type": .string("poll"), "request_id": .string(requestID)]))
                }
            }
            emit(response)
            return response["ok"] == .bool(true) ? 0 : 2
        } catch {
            emit(.object(["ok": .bool(false), "error": .string("NATIVE_FALLBACK_REQUIRED"), "reason": .string("APP_UNAVAILABLE")]))
            return 75
        }
    }

    public static func readStandardInput() throws -> Data {
        var result = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 8192), !chunk.isEmpty {
            result.append(chunk)
            guard result.count <= 512 * 1024 else { throw TerminalError.invalid("Question exceeds 512 KiB") }
        }
        return result
    }
}
