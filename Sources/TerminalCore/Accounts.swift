import Foundation

public struct AccountProfile: Codable, Identifiable, Equatable {
    public var id = UUID().uuidString.lowercased()
    public let provider: AgentKind
    public var label: String
    public var enabled = true
    public var pinned = false
    public var unavailableUntil: Date?
    public init(provider: AgentKind, label: String) { self.provider = provider; self.label = label }
}

public struct AccountCommand: Codable {
    public var executable = "/usr/bin/env"
    public var arguments: [String]
    public var environment: [String: String]
    public var removeEnvironment: [String]
    public init(arguments: [String], environment: [String: String], removeEnvironment: [String]) {
        self.arguments = arguments; self.environment = environment; self.removeEnvironment = removeEnvironment
    }
}

public struct AccountLimitSignal {
    public let accountID: String
    public let retryAt: Date
    public let verified: Bool
    public init(accountID: String, retryAt: Date, verified: Bool) { self.accountID = accountID; self.retryAt = retryAt; self.verified = verified }
}

public enum AccountFailover {
    public static func next(current: AccountProfile, accounts: [AccountProfile], signal: AccountLimitSignal?,
                            optIn: Bool, toolsInFlight: Bool, resumableSessionID: String?, adapterQualified: Bool, now: Date = Date()) -> AccountProfile? {
        guard optIn, !toolsInFlight, adapterQualified, !current.pinned,
              let resumableSessionID, !resumableSessionID.isEmpty,
              let signal, signal.verified, signal.accountID == current.id, signal.retryAt > now else { return nil }
        return accounts.first {
            $0.id != current.id && $0.provider == current.provider && $0.enabled && !$0.pinned && ($0.unavailableUntil ?? .distantPast) <= now
        }
    }
}

public enum ManagedDirectory {
    public static func ensure(_ parent: URL, component: String) throws -> URL {
        guard !component.isEmpty, !component.contains("/"), component != ".", component != ".." else { throw TerminalError.invalid("Invalid managed directory component") }
        let path = parent.appendingPathComponent(component, isDirectory: true)
        let manager = FileManager.default
        if !manager.fileExists(atPath: path.path) { try manager.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        let attributes = try manager.attributesOfItem(atPath: path.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw TerminalError.invalid("Managed paths must be owned directories, not symlinks") }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path
    }
}

extension TerminalRuntime {
    public func addAccount(provider: AgentKind, label: String) throws -> AccountProfile {
        guard provider != .shell else { throw TerminalError.invalid("Choose Claude or Codex") }
        try Self.validateAccountLabel(label)
        return try transaction {
            let profile = AccountProfile(provider: provider, label: label)
            let base = try ManagedDirectory.ensure(root, component: "accounts")
            let directory = try ManagedDirectory.ensure(base, component: profile.id)
            do {
                try Self.atomicWrite(Data("trano-account-v1\n".utf8), to: directory.appendingPathComponent(".trano-account"))
                if provider == .codex {
                    try Self.atomicWrite(Data("cli_auth_credentials_store = \"file\"\n".utf8), to: directory.appendingPathComponent("config.toml"))
                } else {
                    try Self.atomicWrite(Data("{}\n".utf8), to: directory.appendingPathComponent("settings.json"))
                }
                try update { $0.accounts.append(profile) }
                try applyExtensions(extensionPlan(accountID: profile.id, extensionIDs: []))
                return profile
            } catch {
                try? update { $0.accounts.removeAll { $0.id == profile.id } }
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }
    }

    private static func validateAccountLabel(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 100,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw TerminalError.invalid("Use an account label of 1...100 characters without control characters")
        }
    }

    public func updateAccount(_ id: String, label: String? = nil, enabled: Bool? = nil, pinned: Bool? = nil) throws {
        if let label { try Self.validateAccountLabel(label) }
        try update { state in
            guard let index = state.accounts.firstIndex(where: { $0.id == id }) else { throw TerminalError.invalid("Unknown account") }
            if let label { state.accounts[index].label = label }
            if let enabled { state.accounts[index].enabled = enabled }
            if let pinned { state.accounts[index].pinned = pinned }
        }
    }

    public func reorderAccounts(_ ids: [String]) throws {
        try update { state in
            guard ids.count == state.accounts.count, Set(ids).count == ids.count,
                  Set(ids) == Set(state.accounts.map(\.id)) else { throw TerminalError.invalid("Account order must include each account exactly once") }
            let accounts = Dictionary(uniqueKeysWithValues: state.accounts.map { ($0.id, $0) })
            state.accounts = ids.map { accounts[$0]! }
        }
    }

    public func setAccountCooldown(_ id: String, until: Date?) throws {
        if let until, !until.timeIntervalSince1970.isFinite { throw TerminalError.invalid("Invalid cooldown time") }
        try update { state in
            guard let index = state.accounts.firstIndex(where: { $0.id == id }) else { throw TerminalError.invalid("Unknown account") }
            state.accounts[index].unavailableUntil = until
        }
    }

    public func accountRoot(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil, try state().accounts.contains(where: { $0.id == id }) else { throw TerminalError.invalid("Unknown account") }
        let base = try ManagedDirectory.ensure(root, component: "accounts")
        let directory = try ManagedDirectory.ensure(base, component: id)
        guard try AccountFile.read(directory.appendingPathComponent(".trano-account"), limit: 64) == Data("trano-account-v1\n".utf8) else { throw TerminalError.invalid("Account directory is not owned by Trano") }
        return directory
    }

    public func accountCommand(_ id: String, login: Bool = false, arguments: [String] = []) throws -> AccountCommand {
        guard let profile = try state().accounts.first(where: { $0.id == id }), profile.enabled else { throw TerminalError.invalid("Account is unavailable") }
        let directory = try accountRoot(id)
        if !login { try applyExtensions(extensionPlan(accountID: id, extensionIDs: enabledExtensions(accountID: id))) }
        let removed = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CONFIG_DIR", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_HOME", "CODEX_SQLITE_HOME", "OPENAI_BASE_URL"]
        if profile.provider == .claude {
            return AccountCommand(arguments: login ? ["claude", "auth", "login", "--claudeai"] : ["claude", "--mcp-config", directory.appendingPathComponent("trano-mcp.json").path, "--settings", directory.appendingPathComponent("trano-settings.json").path] + arguments,
                                  environment: ["CLAUDE_CONFIG_DIR": directory.path, "TRANO_ACCOUNT_ID": id], removeEnvironment: removed)
        }
        return AccountCommand(arguments: login ? ["codex", "login"] : ["codex", "--no-daemon", "--profile", "trano"] + arguments,
                              environment: ["CODEX_HOME": directory.path, "TRANO_ACCOUNT_ID": id], removeEnvironment: removed)
    }

    public func launchAccount(_ id: String, cwd: String, login: Bool = false) throws -> LaunchResult {
        _ = try accountCommand(id, login: login)
        guard let helperExecutable, FileManager.default.isExecutableFile(atPath: helperExecutable) else { throw TerminalError.runtime("The bundled trano CLI is required") }
        let result = try launch(cwd: cwd)
        let command = [helperExecutable, "account", "exec", id] + (login ? ["--login"] : [])
        do { try send(result.pane.id, text: command.map(ShellQuote.quote).joined(separator: " "), enter: true) }
        catch { try? terminate(result.pane.id); throw error }
        return result
    }
}
