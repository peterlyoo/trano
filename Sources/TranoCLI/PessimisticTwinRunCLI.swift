import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import TerminalCore

enum TwinRunCLI {
    struct ExpiryGuard {
        let expiresAt: Date
        private var interruptedAt: TimeInterval?
        private var killed = false
        mutating func poll(now: Date, uptime: TimeInterval) -> Int32? {
            if interruptedAt == nil, now >= expiresAt { interruptedAt = uptime; return SIGINT }
            if let interruptedAt, !killed, uptime >= interruptedAt + 5 { killed = true; return SIGKILL }
            return nil
        }
        func exitCode(_ code: Int32, now: Date) -> Int32 { interruptedAt != nil || now >= expiresAt ? 78 : code }
        func expired(now: Date) -> Bool { interruptedAt != nil || now >= expiresAt }
    }
    struct Invocation: Equatable { let runID: String; let round: Int }
    static func parse(_ arguments: [String]) throws -> Invocation {
        guard arguments.count == 4, arguments[0] == "run", let runID = UUID(uuidString: arguments[1]),
              arguments[2] == "--round", let round = Int(arguments[3]), (1...8).contains(round) else {
            throw TerminalError.invalid("Owned twin invocation requires run RUN_ID --round N")
        }
        return Invocation(runID: runID.uuidString.lowercased(), round: round)
    }
    static func command(executable: String, arguments: [String], environment: [String: String], removeEnvironment: [String]) -> AccountCommand {
        var command = AccountCommand(arguments: arguments, environment: environment, removeEnvironment: removeEnvironment)
        command.executable = executable
        return command
    }
    static func environment(_ base: [String: String], command: AccountCommand, paneID: String, generation: String, helper: String, socket: String) -> [String: String] {
        let inherited: Set<String> = ["HOME", "USER", "LOGNAME", "PATH", "SHELL", "TZ", "TERM", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "LANG", "LANGUAGE", "LC_ALL", "LC_CTYPE", "LC_MESSAGES", "LC_COLLATE", "LC_NUMERIC", "LC_MONETARY", "LC_TIME", "LC_PAPER", "LC_NAME", "LC_ADDRESS", "LC_TELEPHONE", "LC_MEASUREMENT", "LC_IDENTIFICATION", "__CF_USER_TEXT_ENCODING", "COMMAND_MODE"]
        var result = base.filter { inherited.contains($0.key) }
        for key in ["REX_BLOCK", "REX_SESSION", "REX_SERVER"] + command.removeEnvironment { result.removeValue(forKey: key) }
        result.merge(command.environment) { _, new in new }
        result["PATH"] = cleanPath(result["PATH"], socket: socket)
        result.removeValue(forKey: "EASYDECISION_ADAPTER_BIN")
        result["TRANO_SESSION"] = paneID
        result["TRANO_LAUNCH_ID"] = generation
        result["TRANO_CLI_PATH"] = helper
        result["TRANO_TWIN_API_SOCKET"] = socket
        result["EASYDECISION_SOCKET"] = socket
        return result
    }
    private static func cleanPath(_ path: String?, socket: String) -> String {
        let root = URL(fileURLWithPath: socket).deletingLastPathComponent().path
        let managed = ["bin", "git-bin", "shell/bin"].compactMap { canonical(root + "/" + $0) }
        func owned(_ path: String) -> Bool { managed.contains { path == $0 || path.hasPrefix($0 + "/") } }
        var seen = Set<String>(), kept: [String] = []
        for component in (path ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").prefix(256) {
            guard let value = canonical(String(component)), !owned(value),
                  canonical(value + "/git").map({ !owned($0) }) ?? true else { continue }
            if seen.insert(value).inserted { kept.append(value) }
        }
        return kept.isEmpty ? "/usr/bin:/bin:/usr/sbin:/sbin" : kept.joined(separator: ":")
    }
    private static func canonical(_ path: String) -> String? {
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let resolved = realpath(normalized, nil) else { return normalized }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    static func finish(recordExit: () throws -> Void, endLaunch: () throws -> Void) throws { try recordExit(); try endLaunch() }
    static func activateSuspendedProvider(record: () throws -> Void, register: () throws -> Void, giveTerminal: () throws -> Void, resume: () throws -> Void) throws {
        try record()
        try register()
        try giveTerminal()
        try resume()
    }
}
