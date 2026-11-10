import Foundation
import Darwin

public struct ServiceHandoffResult: Codable, Equatable {
    public let buildID: String
    public let pid: Int32
    public let replaced: Bool
}

public enum ServiceHandoff {
    public static func ensure(runtime: TerminalRuntime, executable: URL, expected: BuildIdentity = .process, timeout: TimeInterval = 20) throws -> ServiceHandoffResult {
        guard expected.isBundled, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw TerminalError.runtime("The background service requires a packaged Trano build.")
        }
        let deadline = Date().addingTimeInterval(timeout)
        let lock = open(runtime.root.appendingPathComponent("service-start.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw TerminalError.runtime("Cannot open background service startup lock") }
        defer { close(lock) }
        var attributes = stat()
        guard fstat(lock, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_uid == getuid(), fchmod(lock, 0o600) == 0 else {
            throw TerminalError.runtime("Background service startup lock must be an owned regular file.")
        }
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else { throw TerminalError.runtime("Another app is starting the background service.") }
            usleep(50_000)
        }
        defer { _ = flock(lock, LOCK_UN) }
        let client = APIClient(path: runtime.root.appendingPathComponent("api.sock").path)
        var replaced = false
        if let current = try? client.call(APIRequest(method: "server.info")) {
            let running = identity(current)
            switch ServiceHandoffPolicy.action(expected: expected, running: running, kind: current.result?["serviceKind"]?.text) {
            case .keep: return try result(current, replaced: false)
            case .manualRestart: throw TerminalError.runtime("The existing API service predates safe update handoff. Restart that background service once; terminal jobs can keep running.")
            case .replace:
                let previous = try result(current, replaced: false)
                let response = try client.call(APIRequest(method: "service.shutdown", params: [
                    "expectedBuildID": .string(previous.buildID), "expectedPID": .number(Double(previous.pid)),
                    "replacementBuildID": .string(expected.buildID)
                ]))
                guard response.error == nil, response.result?["accepted"] == .bool(true) else {
                    throw TerminalError.runtime(response.error ?? "The background service declined update handoff.")
                }
                replaced = true
                while let response = try? client.call(APIRequest(method: "server.info")) {
                    if identity(response) == expected { return try result(response, replaced: true) }
                    guard Date() < deadline else { throw TerminalError.runtime("The previous background service has not stopped yet.") }
                    usleep(50_000)
                }
            }
        }
        var attempts = 0
        var process: Process?
        while Date() < deadline {
            if let response = try? client.call(APIRequest(method: "server.info")) {
                guard identity(response) == expected || response.result?["serviceKind"] == .string("cli") else {
                    throw TerminalError.runtime("Another Trano build started the background service. Relaunch the current app.")
                }
                return try result(response, replaced: replaced)
            }
            if process == nil || process?.isRunning == false {
                guard attempts < 3 else { throw TerminalError.runtime("The background service failed to start.") }
                let next = Process()
                next.executableURL = executable
                next.arguments = ["--service"]
                var environment = ProcessInfo.processInfo.environment
                environment["TRANO_DATA_DIR"] = runtime.root.path
                for key in ["TRANO_SESSION", "TRANO_LAUNCH_ID", "REX_BLOCK", "REX_SESSION", "REX_SERVER"] { environment.removeValue(forKey: key) }
                next.environment = environment
                next.standardInput = FileHandle.nullDevice
                next.standardOutput = FileHandle.nullDevice
                next.standardError = FileHandle.nullDevice
                try next.run()
                process = next
                attempts += 1
            }
            usleep(50_000)
        }
        throw TerminalError.runtime("The background service did not become ready in time.")
    }

    private static func identity(_ response: APIResponse) -> BuildIdentity? {
        guard response.error == nil,
              let version = response.result?["version"]?.text,
              let buildNumber = response.result?["buildNumber"]?.text,
              let buildID = response.result?["buildID"]?.text else { return nil }
        return BuildIdentity(info: ["CFBundleShortVersionString": version, "CFBundleVersion": buildNumber, "TranoBuildID": buildID])
    }

    private static func result(_ response: APIResponse, replaced: Bool) throws -> ServiceHandoffResult {
        guard let identity = identity(response),
              case .number(let pid)? = response.result?["pid"], pid > 0, pid <= Double(Int32.max), pid.rounded() == pid else {
            throw TerminalError.runtime("The background service returned incomplete identity metadata.")
        }
        return ServiceHandoffResult(buildID: identity.buildID, pid: Int32(pid), replaced: replaced)
    }
}
