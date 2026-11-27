import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public protocol SettingsPreferences: Codable, Equatable {
    init()
    func validate() throws
}

public final class SecureSettingsSidecar<Value: SettingsPreferences> {
    private let root: URL
    private let file: URL
    private let lockFile: URL
    private let mutex = NSRecursiveLock()

    public init(root: URL, filename: String) throws {
        guard filename.range(of: #"^[a-z][a-z0-9-]{0,63}\.json$"#, options: .regularExpression) != nil else {
            throw TerminalError.invalid("Invalid settings filename")
        }
        self.root = root.standardizedFileURL
        file = self.root.appendingPathComponent(filename)
        lockFile = self.root.appendingPathComponent(filename + ".lock")
        try Self.validateRoot(self.root)
    }

    public func load() throws -> Value {
        try locked {
            guard let object = try readObject() else { return Value() }
            return try decode(object)
        }
    }

    @discardableResult public func merge(baseline: Value, edited: Value) throws -> Value {
        try edited.validate()
        let old = try Self.object(baseline), changes = try Self.object(edited)
        return try locked {
            var current = try readObject() ?? Self.object(Value())
            var changed = false
            for key in Set(old.keys).union(changes.keys) where old[key] != changes[key] {
                current[key] = changes[key]
                changed = true
            }
            let value = try decode(current)
            if changed { try writeObject(current) }
            return value
        }
    }

    @discardableResult public func update(_ action: (inout Value) throws -> Void) throws -> Value {
        try locked {
            let current = try readObject() ?? Self.object(Value())
            var value = try decode(current)
            let before = try Self.object(value)
            try action(&value)
            try value.validate()
            let after = try Self.object(value)
            var merged = current
            for key in Set(before.keys).union(after.keys) where before[key] != after[key] { merged[key] = after[key] }
            if merged != current { try writeObject(merged) }
            return value
        }
    }

    private static func object(_ value: Value) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(value))
    }

    private func decode(_ object: [String: JSONValue]) throws -> Value {
        let value = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(object))
        try value.validate()
        return value
    }

    private func readObject() throws -> [String: JSONValue]? {
        guard let data = try Self.readOwnedFile(file) else { return nil }
        let envelope = try JSONDecoder().decode([String: JSONValue].self, from: data)
        guard envelope["schemaVersion"] == .number(1), case .object(let object)? = envelope["values"] else {
            throw TerminalError.invalid("Unsupported settings schema")
        }
        return object
    }

    private func writeObject(_ values: [String: JSONValue]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(["schemaVersion": JSONValue.number(1), "values": .object(values)])
        guard data.count <= 1_048_576 else { throw TerminalError.invalid("Settings exceed 1 MiB") }
        data.append(10)
        try TerminalRuntime.atomicWrite(data, to: file)
    }

    private func locked<T>(_ action: () throws -> T) throws -> T {
        mutex.lock(); defer { mutex.unlock() }
        try Self.validateRoot(root)
        let fd = open(lockFile.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw TerminalError.invalid("Cannot open owned settings lock") }
        defer { close(fd) }
        try Self.validateFile(fd, limit: 1_048_576)
        guard flock(fd, LOCK_EX) == 0 else { throw TerminalError.runtime("Cannot lock settings") }
        defer { _ = flock(fd, LOCK_UN) }
        return try action()
    }

    private static func validateRoot(_ root: URL) throws {
        var info = stat()
        guard lstat(root.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw TerminalError.invalid("Settings require an owned private directory")
        }
    }

    static func readOwnedFile(_ file: URL) throws -> Data? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw TerminalError.invalid("Cannot read owned settings file") }
        defer { close(fd) }
        try validateFile(fd, limit: 1_048_576)
        var data = Data(), bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(fd, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw TerminalError.runtime("Cannot read settings") }
            if count == 0 { return data }
            guard data.count + count <= 1_048_576 else { throw TerminalError.invalid("Settings exceed 1 MiB") }
            data.append(contentsOf: bytes.prefix(count))
        }
    }

    private static func validateFile(_ fd: Int32, limit: Int) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= limit else {
            throw TerminalError.invalid("Settings must be private owned regular files")
        }
    }
}

public struct ServerPreferences: SettingsPreferences {
    public var serveOverTailscale = false
    public var preferredHostname = ""
    public var limitToSameAccount = true
    public var clientLabel = "Trano"
    public var remoteControl = false
    public var allowedOrigins: [String] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case serveOverTailscale, preferredHostname, limitToSameAccount, clientLabel, remoteControl, allowedOrigins }
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        serveOverTailscale = try box.decodeIfPresent(Bool.self, forKey: .serveOverTailscale) ?? false
        preferredHostname = try box.decodeIfPresent(String.self, forKey: .preferredHostname) ?? ""
        limitToSameAccount = try box.decodeIfPresent(Bool.self, forKey: .limitToSameAccount) ?? true
        clientLabel = try box.decodeIfPresent(String.self, forKey: .clientLabel) ?? "Trano"
        remoteControl = try box.decodeIfPresent(Bool.self, forKey: .remoteControl) ?? false
        allowedOrigins = try box.decodeIfPresent([String].self, forKey: .allowedOrigins) ?? []
    }
    public func validate() throws {
        guard Self.validLabel(clientLabel) else { throw TerminalError.invalid("Client label must contain 1…64 characters without control characters") }
        guard preferredHostname.isEmpty || preferredHostname.range(of: #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"#, options: .regularExpression) != nil else {
            throw TerminalError.invalid("Choose a hostname using lowercase letters, numbers and hyphens")
        }
        guard allowedOrigins.count <= 128 else { throw TerminalError.invalid("At most 128 web origins are allowed") }
        let canonical = try allowedOrigins.map { try RemoteOriginPattern($0).canonical }
        guard Set(canonical).count == canonical.count else { throw TerminalError.invalid("An origin is listed more than once") }
    }
    static func validLabel(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.utf8.count <= 256 && value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
        value.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil
    }
}

public struct IntegrationsPreferences: SettingsPreferences {
    public var integrateWithAvailableAgents = true
    public var letAgentsNameSessions = false
    public var automaticallyCleanWorktrees = true
    public init() {}
    private enum CodingKeys: String, CodingKey { case integrateWithAvailableAgents, letAgentsNameSessions, automaticallyCleanWorktrees }
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        integrateWithAvailableAgents = try box.decodeIfPresent(Bool.self, forKey: .integrateWithAvailableAgents) ?? true
        letAgentsNameSessions = try box.decodeIfPresent(Bool.self, forKey: .letAgentsNameSessions) ?? false
        automaticallyCleanWorktrees = try box.decodeIfPresent(Bool.self, forKey: .automaticallyCleanWorktrees) ?? true
    }
    public func validate() throws {}
    public var permitsSessionNaming: Bool { integrateWithAvailableAgents && letAgentsNameSessions }
}

public struct RemoteOriginPattern: Equatable {
    public let canonical: String
    private let scheme: String
    private let host: String
    private let port: Int?
    private let wildcard: Bool

    public init(_ value: String) throws { try self.init(value, allowWildcard: true) }
    private init(_ value: String, allowWildcard: Bool) throws {
        guard value.utf8.count <= 512, !value.isEmpty,
              value.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }),
              let parts = URLComponents(string: value), let rawScheme = parts.scheme,
              ["https", "http"].contains(rawScheme.lowercased()), let rawHost = parts.host,
              !rawHost.isEmpty, parts.user == nil, parts.password == nil, parts.path.isEmpty,
              parts.query == nil, parts.fragment == nil else { throw TerminalError.invalid("Enter an http or https origin without a path or credentials") }
        scheme = rawScheme.lowercased()
        let lowered = rawHost.lowercased()
        wildcard = lowered.hasPrefix("*.")
        host = wildcard ? String(lowered.dropFirst(2)) : lowered
        guard !lowered.contains("%"), !host.contains("*"), !host.hasSuffix("."),
              (!wildcard || allowWildcard), host.utf8.count <= 253 else { throw TerminalError.invalid("Invalid origin hostname") }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            guard !wildcard, host.contains(":") else { throw TerminalError.invalid("Invalid origin address") }
        } else {
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard !labels.isEmpty, labels.allSatisfy({ $0.range(of: #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"#, options: .regularExpression) != nil }),
                  !wildcard || labels.count >= 2 && labels.last?.allSatisfy(\.isNumber) == false else { throw TerminalError.invalid("Use a hostname or a wildcard subdomain") }
        }
        if let number = parts.port, !(1...65535).contains(number) { throw TerminalError.invalid("Invalid origin port") }
        let defaultPort = scheme == "https" ? 443 : 80
        port = parts.port == defaultPort ? nil : parts.port
        canonical = scheme + "://" + (wildcard ? "*." : "") + host + (port.map { ":\($0)" } ?? "")
    }

    public func matches(_ origin: String) -> Bool {
        guard let candidate = try? RemoteOriginPattern(origin, allowWildcard: false), candidate.scheme == scheme, candidate.port == port else { return false }
        return wildcard ? candidate.host.hasSuffix("." + host) && candidate.host != host : candidate.host == host
    }
}

public enum TailscaleCommand: Equatable {
    case status, serve(target: String), stopServing, signIn, signOut, setHostname(String)
    public var arguments: [String] {
        switch self {
        case .status: return ["status", "--json"]
        case .serve(let target): return ["serve", "--bg", "--https=443", "--set-path=/trano", target]
        case .stopServing: return ["serve", "--https=443", "--set-path=/trano", "off"]
        case .signIn: return ["login"]
        case .signOut: return ["logout"]
        case .setHostname(let hostname): return ["set", "--hostname=" + hostname]
        }
    }
}

public struct TailscaleSnapshot: Equatable {
    public var backendState: String
    public var dnsName: String?
    public var loginName: String?
    public var tags: [String]
    public var controlURL: String?
    public var authenticationURL: URL?

    public init(data: Data) throws {
        guard data.count <= 1_048_576 else { throw TerminalError.invalid("Tailscale status exceeds 1 MiB") }
        struct User: Decodable {
            let loginName: String?
            enum CodingKeys: String, CodingKey { case loginName = "LoginName" }
        }
        struct Node: Decodable {
            let dnsName: String?; let userID: UInt64?; let tags: [String]?
            enum CodingKeys: String, CodingKey { case dnsName = "DNSName", userID = "UserID", tags = "Tags" }
        }
        struct Status: Decodable {
            let backendState: String?; let node: Node?; let users: [String: User]?; let controlURL: String?; let authURL: String?
            enum CodingKeys: String, CodingKey { case backendState = "BackendState", node = "Self", users = "User", controlURL = "ControlURL", authURL = "AuthURL" }
        }
        let value = try JSONDecoder().decode(Status.self, from: data)
        guard let state = value.backendState, !state.isEmpty, state.utf8.count < 128 else { throw TerminalError.invalid("Tailscale returned no backend state") }
        backendState = state
        dnsName = value.node?.dnsName?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        loginName = value.node?.userID.flatMap { value.users?[String($0)]?.loginName }
        tags = Array((value.node?.tags ?? []).prefix(128))
        controlURL = value.controlURL.flatMap { Self.safeHTTPS($0)?.absoluteString }
        authenticationURL = value.authURL.flatMap(Self.safeHTTPS)
    }
    public var remoteAddress: URL? {
        guard backendState == "Running", let dnsName, let url = Self.safeHTTPS("https://" + dnsName + "/trano"), url.path == "/trano" else { return nil }
        return url
    }
    private static func safeHTTPS(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil, !string.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return url
    }
}

public struct AuthorizedRemoteClient: Codable, Equatable, Identifiable {
    public let id: String
    public var label: String
    public let createdAt: Date
    public var remoteControl: Bool
    public init(id: String, label: String, createdAt: Date, remoteControl: Bool) {
        self.id = id; self.label = label; self.createdAt = createdAt; self.remoteControl = remoteControl
    }
}

public struct PairingInvitation: Equatable {
    public let code: String
    public let expiresAt: Date
}

public struct PairedCredential {
    public let client: AuthorizedRemoteClient
    public let token: String
}

private struct RemoteCredentialRecord: Codable, Equatable {
    var client: AuthorizedRemoteClient
    let tokenHash: String
    let login: String?
}

private struct RemoteCredentialFile: SettingsPreferences {
    var records: [RemoteCredentialRecord] = []
    init() {}
    func validate() throws {
        guard records.count <= 100, Set(records.map { $0.client.id }).count == records.count,
              records.allSatisfy({ UUID(uuidString: $0.client.id) != nil && ServerPreferences.validLabel($0.client.label) && $0.tokenHash.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil }) else {
            throw TerminalError.invalid("Invalid paired client data")
        }
    }
}

public final class RemotePairingStore {
    private let sidecar: SecureSettingsSidecar<RemoteCredentialFile>
    private let lock = NSLock()
    private var invitations: [String: Date] = [:]
    public init(root: URL) throws { sidecar = try SecureSettingsSidecar(root: root, filename: "remote-clients.json") }

    public func invite(now: Date = Date()) throws -> PairingInvitation {
        lock.lock(); defer { lock.unlock() }
        invitations = invitations.filter { $0.value > now }
        guard invitations.count < 8 else { throw TerminalError.invalid("Too many pending pairing invitations") }
        let code = Self.secret(), expiresAt = now.addingTimeInterval(120)
        invitations[Self.hash(code)] = expiresAt
        return PairingInvitation(code: code, expiresAt: expiresAt)
    }

    public func pair(code: String, label: String, login: String?, ownLogin: String?, preferences: ServerPreferences, now: Date = Date()) throws -> PairedCredential {
        try preferences.validate()
        guard preferences.serveOverTailscale, ServerPreferences.validLabel(label), code.utf8.count <= 128 else { throw TerminalError.invalid("Pairing is unavailable") }
        try Self.validateAccount(login: login, ownLogin: ownLogin, preferences: preferences)
        lock.lock(); defer { lock.unlock() }
        let hash = Self.hash(code)
        guard let expiry = invitations[hash], expiry > now else { invitations.removeValue(forKey: hash); throw TerminalError.invalid("Pairing invitation expired or was already used") }
        let token = Self.secret()
        let client = AuthorizedRemoteClient(id: UUID().uuidString.lowercased(), label: label, createdAt: now, remoteControl: false)
        _ = try sidecar.update { file in
            guard file.records.count < 100 else { throw TerminalError.invalid("At most 100 clients can be paired") }
            file.records.append(RemoteCredentialRecord(client: client, tokenHash: Self.hash(token), login: login))
        }
        invitations.removeValue(forKey: hash)
        return PairedCredential(client: client, token: token)
    }

    public func clients() throws -> [AuthorizedRemoteClient] { try sidecar.load().records.map(\.client) }
    public func revoke(id: String) throws {
        _ = try sidecar.update { file in file.records.removeAll { $0.client.id == id } }
    }
    public func setRemoteControl(id: String, allowed: Bool) throws {
        _ = try sidecar.update { file in
            guard let index = file.records.firstIndex(where: { $0.client.id == id }) else { throw TerminalError.invalid("Unknown paired client") }
            file.records[index].client.remoteControl = allowed
        }
    }

    public func authorize(token: String, origin: String?, login: String?, ownLogin: String?, method: String, preferences: ServerPreferences) throws -> AuthorizedRemoteClient {
        try preferences.validate()
        guard preferences.serveOverTailscale, (32...128).contains(token.utf8.count) else { throw TerminalError.invalid("Remote access is unavailable") }
        try Self.validateAccount(login: login, ownLogin: ownLogin, preferences: preferences)
        if let origin {
            guard try preferences.allowedOrigins.contains(where: { try RemoteOriginPattern($0).matches(origin) }) else { throw TerminalError.invalid("Web origin is not allowed") }
        }
        let digest = Self.hash(token)
        guard let record = try sidecar.load().records.first(where: { Self.constantTimeEqual($0.tokenHash, digest) }), record.login == login else { throw TerminalError.invalid("Invalid remote credentials") }
        let readonly: Set<String> = ["server.info", "sessions.list", "panes.capture", "workspaces.list", "actions.list", "activity.list", "events.list", "followups.list", "recovery.list", "scrollback.list", "remote.hosts.list", "accounts.list", "accounts.usage", "extensions.list", "decisions.list", "state.get"]
        let mutations: Set<String> = ["sessions.create", "sessions.attach", "sessions.terminate", "sessions.rename", "panes.focus", "panes.send", "panes.detach", "panes.move", "actions.perform", "followups.add", "followups.update", "followups.remove", "decisions.resolve", "decisions.delete", "decisions.abandon", "recovery.run", "recovery.retry"]
        guard readonly.contains(method) || mutations.contains(method) && preferences.remoteControl && record.client.remoteControl else { throw TerminalError.invalid("Remote Control is not permitted for this action") }
        return record.client
    }

    private static func validateAccount(login: String?, ownLogin: String?, preferences: ServerPreferences) throws {
        guard !preferences.limitToSameAccount || login != nil && !login!.isEmpty && login == ownLogin else { throw TerminalError.invalid("Only this Tailscale account is allowed") }
    }
    private static func secret() -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func constantTimeEqual(_ first: String, _ second: String) -> Bool {
        let a = Array(first.utf8), b = Array(second.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

public struct RemoteHTTPRequest: Equatable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
    public static func parse(_ data: Data) throws -> RemoteHTTPRequest? {
        guard data.count <= 1_064_960 else { throw TerminalError.invalid("Remote request exceeds its limit") }
        guard let separator = data.range(of: Data([13, 10, 13, 10])) else {
            guard data.count <= 16_384 else { throw TerminalError.invalid("Remote headers exceed 16 KiB") }
            return nil
        }
        guard separator.lowerBound <= 16_384, let header = String(data: data[..<separator.lowerBound], encoding: .utf8) else { throw TerminalError.invalid("Invalid remote headers") }
        let lines = header.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, ["POST", "OPTIONS"].contains(String(request[0])), request[2] == "HTTP/1.1" else { throw TerminalError.invalid("Unsupported remote HTTP request") }
        var path = String(request[1])
        if path.hasPrefix("/trano/") { path = String(path.dropFirst(6)) }
        guard ["/api", "/pair"].contains(path) else { throw TerminalError.invalid("Unknown remote endpoint") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw TerminalError.invalid("Invalid remote header") }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  value.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }), headers[name] == nil else { throw TerminalError.invalid("Invalid or duplicate remote header") }
            headers[name] = value
        }
        guard headers["transfer-encoding"] == nil else { throw TerminalError.invalid("Chunked requests are not supported") }
        let length: Int
        if let text = headers["content-length"] {
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(text), value <= 1_048_576 else { throw TerminalError.invalid("Invalid remote body length") }
            length = value
        } else {
            guard request[0] == "OPTIONS" else { throw TerminalError.invalid("Content-Length is required") }
            length = 0
        }
        let received = data.count - separator.upperBound
        guard received <= length else { throw TerminalError.invalid("Pipelined remote requests are not supported") }
        guard received == length else { return nil }
        return RemoteHTTPRequest(method: String(request[0]), path: path, headers: headers, body: Data(data[separator.upperBound...]))
    }
}

public struct ManagedAgentIntegrationPlan: Equatable {
    public let files: [String: Data]
    let provider: AgentKind
}

private struct AgentIntegrationReceipt: SettingsPreferences {
    var files: [String: String] = [:]
    init() {}
    func validate() throws {
        guard files.count <= 100, files.allSatisfy({ key, value in
            !key.hasPrefix("/") && !key.split(separator: "/").contains("..") && value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
        }) else { throw TerminalError.invalid("Invalid integration receipt") }
    }
}

public final class ManagedAgentIntegration {
    private let root: URL
    private let directory: URL
    private let receipt: SecureSettingsSidecar<AgentIntegrationReceipt>
    public init(root: URL) throws {
        self.root = root
        let integration = try ManagedDirectory.ensure(root, component: "integration")
        directory = try ManagedDirectory.ensure(integration, component: "agents")
        receipt = try SecureSettingsSidecar(root: root, filename: "integration-agents-receipt.json")
    }

    public func plan(provider: AgentKind, preferences: IntegrationsPreferences) throws -> ManagedAgentIntegrationPlan {
        guard [.claude, .codex].contains(provider) else { throw TerminalError.invalid("This provider has no supported Trano integration") }
        try preferences.validate()
        guard preferences.integrateWithAvailableAgents else { return ManagedAgentIntegrationPlan(files: [:], provider: provider) }
        var skill = """
        ---
        name: trano
        description: Work with the current Trano terminal session using its local API.
        ---
        # Trano

        Use the bundled `trano api` command for current session activity, decisions and queued inputs.
        Preserve running jobs. Never send text to an unrelated or busy pane without explicit authority.
        Bind every agent-owned request to TRANO_SESSION and TRANO_LAUNCH_ID. Do not inspect credentials or global transcripts.
        """
        if preferences.permitsSessionNaming {
            skill += "\nThe user enabled automatic session naming. You may propose a concise workspace title through `trano api agent.name-session` with paneID, generation, expectedTitle and title. Use the current TRANO_SESSION/TRANO_LAUNCH_ID. Never bypass a declined or stale request with a manual rename.\n"
        } else {
            skill += "\nDo not rename the workspace unless the user explicitly requests it.\n"
        }
        let prefix = provider.rawValue + "/"
        var files = [prefix + "skills/trano/SKILL.md": Data((skill + "\n").utf8)]
        if provider == .claude {
            files[prefix + ".claude-plugin/plugin.json"] = Data("{\"name\":\"trano-session\",\"version\":\"0.1.0\"}\n".utf8)
            files[prefix + "hooks/hooks.json"] = try JSONEncoder().encode(["hooks": JSONValue.object(TerminalRuntime.activityHooks(.claude))]) + Data([10])
        }
        return ManagedAgentIntegrationPlan(files: files, provider: provider)
    }

    public func apply(_ plan: ManagedAgentIntegrationPlan) throws {
        let prefix = plan.provider.rawValue + "/"
        guard [.claude, .codex].contains(plan.provider), plan.files.keys.allSatisfy({ $0.hasPrefix(prefix) && !$0.split(separator: "/").contains("..") }) else { throw TerminalError.invalid("Invalid managed integration plan") }
        _ = try receipt.update { state in
            let previous = state.files.filter { $0.key.hasPrefix(prefix) }
            let paths = Set(previous.keys).union(plan.files.keys)
            for path in paths {
                let file = directory.appendingPathComponent(path)
                try validateParents(of: file, create: false)
                if let data = try SecureSettingsSidecar<AgentIntegrationReceipt>.readOwnedFile(file) {
                    guard previous[path] == Self.hash(data) else { throw TerminalError.invalid("Refusing to replace a modified or unmanaged integration file: " + path) }
                } else if previous[path] != nil, plan.files[path] == nil { continue }
            }
            var written: [URL: Data?] = [:]
            do {
                for path in paths.sorted() {
                    let file = directory.appendingPathComponent(path)
                    written[file] = .some(try SecureSettingsSidecar<AgentIntegrationReceipt>.readOwnedFile(file))
                    if let data = plan.files[path] {
                        try validateParents(of: file, create: true)
                        try TerminalRuntime.atomicWrite(data, to: file)
                        state.files[path] = Self.hash(data)
                    } else {
                        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                        state.files.removeValue(forKey: path)
                    }
                }
            } catch {
                for (file, data) in written {
                    if let data { try? TerminalRuntime.atomicWrite(data, to: file) }
                    else { try? FileManager.default.removeItem(at: file) }
                }
                throw error
            }
        }
    }

    private func validateParents(of file: URL, create: Bool) throws {
        let base = directory.standardizedFileURL.pathComponents
        let parts = file.standardizedFileURL.deletingLastPathComponent().pathComponents
        guard parts.starts(with: base) else { throw TerminalError.invalid("Integration path escaped managed storage") }
        var parent = directory
        for part in parts.dropFirst(base.count) {
            parent = parent.appendingPathComponent(part, isDirectory: true)
            var info = stat()
            if lstat(parent.path, &info) != 0 {
                guard errno == ENOENT else { throw TerminalError.invalid("Cannot inspect integration directory") }
                if create { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
                continue
            }
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR), info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw TerminalError.invalid("Integration paths must be private owned directories") }
        }
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
