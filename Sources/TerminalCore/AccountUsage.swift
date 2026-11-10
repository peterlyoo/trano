import Foundation
import Darwin
import CoreFoundation

public enum AccountUsageStatus: String, Codable {
    case unknown, available, limited, authenticationRequired = "authentication_required", unavailable
}

public struct AccountUsageWindow: Codable, Equatable {
    public let id: String
    public let usedPercent: Double
    public let resetsAt: Date?
}

public struct AccountUsageSnapshot: Codable, Equatable, Identifiable {
    public var id: String { accountID }
    public let accountID: String
    public let provider: AgentKind
    public var status: AccountUsageStatus
    public let observedAt: Date
    public let windows: [AccountUsageWindow]
    public let source: String
    public var message: String?
    public var retryAt: Date? {
        guard status == .limited else { return nil }
        return windows.filter { $0.usedPercent >= 100 }.compactMap(\.resetsAt).max()
    }
}

public enum AccountUsageAdapter {
    public static func claude(accountID: String, data: Data, now: Date = Date()) throws -> AccountUsageSnapshot {
        let payload = try object(data)
        let limits = payload["rate_limits"] as? [String: Any] ?? [:]
        var windows: [AccountUsageWindow] = []
        for id in ["five_hour", "seven_day", "spend_limit"] {
            guard let raw = limits[id], !(raw is NSNull) else { continue }
            guard let window = raw as? [String: Any], let percent = number(window["used_percentage"]),
                  (0...100).contains(percent), let reset = number(window["resets_at"]), reset > 0 else {
                throw TerminalError.invalid("Invalid Claude quota window")
            }
            if reset > now.timeIntervalSince1970 {
                windows.append(AccountUsageWindow(id: id, usedPercent: percent, resetsAt: Date(timeIntervalSince1970: reset)))
            }
        }
        return AccountUsageSnapshot(accountID: accountID, provider: .claude,
                                    status: windows.isEmpty ? .unknown : (windows.contains { $0.usedPercent >= 100 } ? .limited : .available),
                                    observedAt: now, windows: windows, source: "claude.statusline",
                                    message: windows.isEmpty ? "Claude has not reported a current quota window" : nil)
    }

    public static func codex(accountID: String, data: Data, now: Date = Date()) throws -> AccountUsageSnapshot {
        let payload = try object(data)
        guard let limits = payload["rateLimits"] as? [String: Any] else { throw TerminalError.invalid("Missing Codex quota response") }
        var windows: [AccountUsageWindow] = []
        for id in ["primary", "secondary"] {
            guard let raw = limits[id], !(raw is NSNull) else { continue }
            guard let window = raw as? [String: Any], let percent = number(window["usedPercent"]), (0...100).contains(percent) else {
                throw TerminalError.invalid("Invalid Codex quota window")
            }
            let reset = number(window["resetsAt"]).flatMap { $0 > now.timeIntervalSince1970 ? Date(timeIntervalSince1970: $0) : nil }
            windows.append(AccountUsageWindow(id: id, usedPercent: percent, resetsAt: reset))
        }
        let permission = payload["ordinaryUsageAllowed"] as? Bool
        let reached = limits["rateLimitReachedType"] as? String
        let limited = permission == false || limits["spendControlReached"] as? Bool == true ||
            ["rate_limit_reached", "workspace_owner_credits_depleted", "workspace_member_credits_depleted", "workspace_owner_usage_limit_reached", "workspace_member_usage_limit_reached"].contains(reached ?? "")
        let status: AccountUsageStatus = permission == true ? .available : (limited ? .limited : .unknown)
        return AccountUsageSnapshot(accountID: accountID, provider: .codex, status: status,
                                    observedAt: now, windows: windows, source: "codex.account/rateLimits/read",
                                    message: status == .unknown ? "Codex did not report whether ordinary usage is allowed" : nil)
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 1_048_576, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TerminalError.invalid("Invalid account usage payload")
        }
        return value
    }

    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
}

extension TerminalRuntime {
    public func accountUsage(now: Date = Date()) throws -> [AccountUsageSnapshot] {
        try transaction {
            let url = root.appendingPathComponent("account-usage.json")
            let saved = FileManager.default.fileExists(atPath: url.path) ? try JSONDecoder().decode([AccountUsageSnapshot].self, from: AccountFile.read(url, limit: 1_048_576)) : []
            return try state().accounts.map { account in
                var value = saved.first { $0.accountID == account.id } ?? AccountUsageSnapshot(accountID: account.id, provider: account.provider, status: .unknown, observedAt: .distantPast, windows: [], source: "none", message: "Usage has not been reported")
                if value.status == .available && now.timeIntervalSince(value.observedAt) > 300 {
                    value.status = .unknown; value.message = "Refresh usage before switching automatically"
                }
                return value
            }
        }
    }

    @discardableResult public func recordClaudeAccountUsage(accountID: String, data: Data) throws -> AccountUsageSnapshot {
        try saveAccountUsage(AccountUsageAdapter.claude(accountID: accountID, data: data))
    }

    @discardableResult public func recordAccountLimit(accountID: String, source: String, resetAt: Date? = nil) throws -> AccountUsageSnapshot {
        guard let account = try state().accounts.first(where: { $0.id == accountID }) else { throw TerminalError.invalid("Unknown account") }
        let prior = try accountUsage().first { $0.accountID == accountID }
        let windows = resetAt.map { [AccountUsageWindow(id: "reported_limit", usedPercent: 100, resetsAt: $0)] } ?? prior?.windows ?? []
        return try saveAccountUsage(AccountUsageSnapshot(accountID: accountID, provider: account.provider, status: .limited, observedAt: Date(), windows: windows, source: source, message: "Provider reported a rate limit"))
    }

    @discardableResult public func recordAccountFailure(accountID: String, authentication: Bool) throws -> AccountUsageSnapshot {
        guard let account = try state().accounts.first(where: { $0.id == accountID }) else { throw TerminalError.invalid("Unknown account") }
        return try saveAccountUsage(AccountUsageSnapshot(accountID: accountID, provider: account.provider, status: authentication ? .authenticationRequired : .unavailable,
                                                        observedAt: Date(), windows: [], source: "provider", message: authentication ? "Sign in to this account" : "Provider is temporarily unavailable"))
    }

    @discardableResult public func refreshAccountUsage(accountID: String) throws -> AccountUsageSnapshot {
        guard let account = try state().accounts.first(where: { $0.id == accountID }) else { throw TerminalError.invalid("Unknown account") }
        if account.provider == .claude { return try accountUsage().first { $0.accountID == accountID }! }
        let directory = try accountRoot(accountID)
        let fd = open(directory.appendingPathComponent(".trano-refresh.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw TerminalError.runtime("Cannot lock account refresh") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw TerminalError.runtime("An account refresh is already running") }
        defer { _ = flock(fd, LOCK_UN) }
        let command = try accountCommand(accountID)
        var environment = ProcessInfo.processInfo.environment
        for key in command.removeEnvironment + ["REX_BLOCK", "REX_SESSION", "REX_SERVER", "TRANO_LAUNCH_ID", "CODEX_SQLITE_HOME"] { environment.removeValue(forKey: key) }
        environment.merge(command.environment) { _, new in new }
        let shim = root.appendingPathComponent("bin").resolvingSymlinksInPath().path
        environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init).filter { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path != shim }.joined(separator: ":")
        let value: AccountUsageSnapshot
        do {
            let response = try AccountRPC.request(method: "account/rateLimits/read", parameters: .null, environment: environment)
            if case .object(let error)? = response["error"] {
                let authentication = error["code"] == .number(-32600) && error["message"]?.text == "codex account authentication required to read rate limits"
                value = AccountUsageSnapshot(accountID: accountID, provider: .codex, status: authentication ? .authenticationRequired : .unavailable, observedAt: Date(), windows: [], source: "codex.account/rateLimits/read", message: authentication ? "Sign in to this account" : "Codex could not refresh usage")
            } else if let result = response["result"] {
                value = try AccountUsageAdapter.codex(accountID: accountID, data: JSONEncoder().encode(result))
            } else { throw TerminalError.invalid("Codex returned no usage result") }
        } catch {
            value = AccountUsageSnapshot(accountID: accountID, provider: .codex, status: .unavailable, observedAt: Date(), windows: [], source: "codex.account/rateLimits/read", message: "Usage refresh failed; check the Codex installation and connection")
        }
        return try saveAccountUsage(value)
    }

    @discardableResult private func saveAccountUsage(_ value: AccountUsageSnapshot) throws -> AccountUsageSnapshot {
        try transaction {
            guard try state().accounts.contains(where: { $0.id == value.accountID && $0.provider == value.provider }) else { throw TerminalError.invalid("Usage provider does not match the account") }
            var saved = try accountUsage()
            saved.removeAll { $0.accountID == value.accountID }; saved.append(value)
            try Self.atomicWrite(JSONEncoder().encode(saved), to: root.appendingPathComponent("account-usage.json"))
            return value
        }
    }
}

enum AccountRPC {
    static func request(method: String, parameters: JSONValue, environment: [String: String], timeout: TimeInterval = 12) throws -> [String: JSONValue] {
        let process = Process(), input = Pipe(), output = Pipe()
        let handles = [input.fileHandleForReading, input.fileHandleForWriting, output.fileHandleForReading, output.fileHandleForWriting]
        for handle in handles { _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC) }
        defer { for handle in handles { try? handle.close() } }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["codex", "app-server", "--stdio"]
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let readFD = output.fileHandleForReading.fileDescriptor
        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        defer {
            if process.isRunning { process.terminate() }
            let deadline = ProcessInfo.processInfo.systemUptime + 0.2
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        func send(_ object: [String: JSONValue]) throws {
            var data = try JSONEncoder().encode(object); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": .number(1), "method": .string("initialize"), "params": .object(["clientInfo": .object(["name": .string("trano"), "version": .string("0.1.0")])])])
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var pending = Data(), received = 0, initialized = false
        var buffer = [UInt8](repeating: 0, count: 16384)
        while ProcessInfo.processInfo.systemUptime < deadline {
            let count = read(readFD, &buffer, buffer.count)
            if count > 0 {
                received += count
                guard received <= 1_048_576 else { throw TerminalError.invalid("Codex account response exceeds limit") }
                pending.append(contentsOf: buffer.prefix(count))
                while let newline = pending.firstIndex(of: 10) {
                    let line = pending.prefix(upTo: newline); pending.removeSubrange(...newline)
                    guard !line.isEmpty else { continue }
                    let response = try JSONDecoder().decode([String: JSONValue].self, from: line)
                    if response["id"] == .number(1), !initialized {
                        guard response["result"] != nil else { throw TerminalError.runtime("Codex initialization failed") }
                        initialized = true
                        try send(["method": .string("initialized")])
                        try send(["id": .number(2), "method": .string(method), "params": parameters])
                    } else if response["id"] == .number(2) { return response }
                }
            } else if count == 0 || !process.isRunning { throw TerminalError.runtime("Codex closed the account connection") }
            else if errno != EAGAIN && errno != EINTR { throw TerminalError.runtime("Cannot read Codex account response") }
            else {
                var descriptor = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
                _ = poll(&descriptor, 1, 20)
            }
        }
        throw TerminalError.runtime("Codex account refresh timed out")
    }
}

enum AccountFile {
    static func read(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TerminalError.invalid("Account data is missing or is a symlink") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= limit else {
            throw TerminalError.invalid("Account data must be a bounded, owned regular file")
        }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let size = Darwin.read(fd, &buffer, buffer.count)
            if size == 0 { return result }
            if size < 0 && errno == EINTR { continue }
            guard size > 0, result.count + size <= limit else { throw TerminalError.invalid("Cannot read bounded account data") }
            result.append(contentsOf: buffer.prefix(size))
        }
    }
}
