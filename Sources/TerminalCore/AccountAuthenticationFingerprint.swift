import Foundation
import CryptoKit
import Darwin
import Security
import LocalAuthentication

public struct AccountAuthenticationFingerprint: Codable, Equatable, Sendable {
    public let ownedFilesDigest: String
    public let keychainDigest: String
    public let executableDigest: String
    public let contextDigest: String?
    public init(ownedFilesDigest: String, keychainDigest: String, executableDigest: String, contextDigest: String? = nil) {
        self.ownedFilesDigest = ownedFilesDigest
        self.keychainDigest = keychainDigest
        self.executableDigest = executableDigest
        self.contextDigest = contextDigest
    }
    public var isValid: Bool {
        ([ownedFilesDigest, keychainDigest, executableDigest] + [contextDigest].compactMap { $0 }).allSatisfy {
            $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
    }
}

struct ClaudeKeychainMetadata { let exists: Bool; let digest: String }

final class ClaudeAuthenticationIdentityReader {
    static let removedEnvironment = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CONFIG_DIR", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_HOME", "CODEX_SQLITE_HOME", "OPENAI_BASE_URL"]
    private let environment: () -> [String: String]
    private let keychain: (String, String) throws -> ClaudeKeychainMetadata
    private let executable: ([String: String], Bool) throws -> String
    private let contextReader: (ClaudeAuthenticationContext, URL) throws -> String
    private static let cacheLock = NSLock()
    private static var executableCache: [String: String] = [:]

    init(environment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
         keychain: @escaping (String, String) throws -> ClaudeKeychainMetadata = nativeKeychain,
         executable: (([String: String], Bool) throws -> String)? = nil,
         contextReader: @escaping (ClaudeAuthenticationContext, URL) throws -> String = ClaudeAuthenticationContextReader.native) {
        self.environment = environment
        self.keychain = keychain
        self.contextReader = contextReader
        self.executable = executable ?? { environment, allow in
            try Self.nativeExecutableIdentity(environment: environment, allowVersion: allow, version: Self.nativeVersion)
        }
    }

    func effectiveEnvironment(accountID: String, root: URL, runtimeRoot: URL) -> [String: String] {
        var result = environment()
        for name in Self.removedEnvironment { result.removeValue(forKey: name) }
        for name in Array(result.keys) where name.hasPrefix("REX") || name == "TRANO_LAUNCH_ID" { result.removeValue(forKey: name) }
        result["CLAUDE_CONFIG_DIR"] = root.path
        result["TRANO_ACCOUNT_ID"] = accountID
        result["PATH"] = ManagedAccountPath.normalized(result["PATH"], runtimeRoot: runtimeRoot)
        return result
    }

    func capture(accountID: String, root: URL, runtimeRoot: URL, context: ClaudeAuthenticationContext? = nil) throws -> AccountAuthenticationFingerprint {
        let environment = effectiveEnvironment(accountID: accountID, root: root, runtimeRoot: runtimeRoot)
        try Self.validateEnvironment(environment)
        let contextDigest = try context.map { try contextReader($0, root) }
        let owned = try Self.ownedFiles(accountID: accountID, root: root, environment: environment)
        let identity = Self.keychainIdentity(root: root, environment: environment)
        var metadata: [[String: Any]] = []
        var modernExists = false
        for (index, service) in identity.services.enumerated() {
            let value = try keychain(service, identity.account)
            guard Self.validDigest(value.digest) else { throw Self.unavailable() }
            if index == 0 { modernExists = value.exists }
            metadata.append(["service": service, "account": identity.account, "exists": value.exists, "digest": value.digest])
        }
        guard owned.hasOAuth || modernExists else { throw Self.unavailable() }
        let binary = try executable(environment, true)
        guard Self.validDigest(binary) else { throw Self.unavailable() }
        return AccountAuthenticationFingerprint(ownedFilesDigest: owned.digest,
            keychainDigest: try Self.hashJSON(metadata), executableDigest: binary, contextDigest: contextDigest)
    }

    func validateLocalSources(_ fingerprint: AccountAuthenticationFingerprint, accountID: String, root: URL, runtimeRoot: URL, context: ClaudeAuthenticationContext? = nil) throws {
        guard fingerprint.isValid else { throw Self.unavailable() }
        let environment = effectiveEnvironment(accountID: accountID, root: root, runtimeRoot: runtimeRoot)
        try Self.validateEnvironment(environment)
        guard try context.map({ try contextReader($0, root) }) == fingerprint.contextDigest,
              try Self.ownedFiles(accountID: accountID, root: root, environment: environment).digest == fingerprint.ownedFilesDigest,
              try executable(environment, false) == fingerprint.executableDigest else { throw Self.unavailable() }
    }

    static func keychainIdentity(root: URL, environment: [String: String]) -> (services: [String], account: String) {
        let suffix = String(hash(Data(root.path.precomposedStringWithCanonicalMapping.utf8)).prefix(8))
        let candidate = environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
        let account = !candidate.isEmpty && candidate.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        } ? candidate : "claude-code-user"
        return (["Claude Code-credentials-" + suffix, "Claude Code-" + suffix], account)
    }

    static func nativeKeychain(_ service: String, _ account: String) throws -> ClaudeKeychainMetadata {
        try readKeychainMetadata(service: service, account: account) { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        }
    }

    static func readKeychainMetadata(service: String, account: String,
                                    query: ([String: Any]) -> (OSStatus, Any?)) throws -> ClaudeKeychainMetadata {
        let context = LAContext()
        context.interactionNotAllowed = true
        let request: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true, kSecReturnData as String: false,
            kSecReturnRef as String: false, kSecReturnPersistentRef as String: false,
            kSecMatchLimit as String: kSecMatchLimitAll, kSecUseAuthenticationContext as String: context
        ]
        let (status, result) = query(request)
        if status == errSecItemNotFound {
            return ClaudeKeychainMetadata(exists: false, digest: try hashJSON(["service": service, "account": account, "missing": true]))
        }
        guard status == errSecSuccess, let matches = result as? [[String: Any]], matches.count == 1,
              let attributes = matches.first,
              attributes[kSecAttrService as String] as? String == service,
              attributes[kSecAttrAccount as String] as? String == account,
              attributes[kSecAttrCreationDate as String] is Date,
              attributes[kSecAttrModificationDate as String] is Date else { throw unavailable() }
        let allowed = Set([kSecClass, kSecAttrService, kSecAttrAccount, kSecAttrCreationDate, kSecAttrModificationDate,
                           kSecAttrLabel, kSecAttrDescription, kSecAttrComment, kSecAttrCreator, kSecAttrType,
                           kSecAttrIsInvisible, kSecAttrIsNegative, kSecAttrSynchronizable, kSecAttrAccessible,
                           kSecAttrAccessGroup, kSecAttrGeneric].map { $0 as String })
        var projection: [String: Any] = [:]
        for (key, value) in attributes {
            guard allowed.contains(key) else { throw unavailable() }
            if let date = value as? Date {
                guard date.timeIntervalSince1970.isFinite else { throw unavailable() }
                projection[key] = ["date": date.timeIntervalSince1970]
            } else if let text = value as? String {
                guard text.utf8.count <= 4096 else { throw unavailable() }
                projection[key] = text
            } else if let number = value as? NSNumber {
                guard number.doubleValue.isFinite else { throw unavailable() }
                projection[key] = number
            } else if let data = value as? Data, data.count <= 4096 {
                projection[key] = ["dataDigest": hash(data)]
            } else { throw unavailable() }
        }
        return ClaudeKeychainMetadata(exists: true, digest: try hashJSON(projection))
    }

    static func nativeExecutableIdentity(environment: [String: String], allowVersion: Bool,
                                         version: (String, [String: String]) throws -> String) throws -> String {
        let entries = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":", omittingEmptySubsequences: false)
        guard entries.count <= 256 else { throw unavailable() }
        var path: String?
        for entry in entries {
            guard entry.hasPrefix("/") else { throw unavailable() }
            let candidate = URL(fileURLWithPath: String(entry)).appendingPathComponent("claude").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                path = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().standardizedFileURL.path
                break
            }
        }
        guard let path else { throw unavailable() }
        var before = stat()
        guard lstat(path, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw unavailable() }
        let key = hash(Data((path + ":" + statIdentity(before)).utf8))
        cacheLock.lock()
        let cached = executableCache[key]
        cacheLock.unlock()
        if let cached { return cached }
        guard allowVersion else { throw unavailable() }
        let observed = try version(path, environment).trimmingCharacters(in: .whitespacesAndNewlines)
        guard observed == "2.1.322" || observed == "2.1.322 (Claude Code)" else { throw unavailable() }
        var after = stat()
        guard lstat(path, &after) == 0, statIdentity(before) == statIdentity(after) else { throw unavailable() }
        let identity = hash(Data((key + ":2.1.322").utf8))
        cacheLock.lock()
        if executableCache.count >= 128 { executableCache.removeAll() }
        executableCache[key] = identity
        cacheLock.unlock()
        return identity
    }

    private static func nativeVersion(_ path: String, _ environment: [String: String]) throws -> String {
        let result = try CommandRunner.run(path, ["--version"], environment: environment, timeout: 5, limit: 4096)
        guard result.status == 0, let text = String(data: result.stdout, encoding: .utf8) else { throw unavailable() }
        return text
    }

    private static func ownedFiles(accountID: String, root: URL, environment: [String: String]) throws -> (digest: String, hasOAuth: Bool) {
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard directory >= 0 else { throw unavailable() }
        defer { close(directory) }
        var directoryInfo = stat()
        guard fstat(directory, &directoryInfo) == 0, directoryInfo.st_uid == getuid(), directoryInfo.st_mode & S_IFMT == S_IFDIR else { throw unavailable() }
        var total = 0, hasOAuth = false
        var projections: [[String: Any]] = []
        for name in ["settings.json", "trano-settings.json", ".claude.json", ".config.json", ".credentials.json"] {
            let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            if fd < 0 {
                guard errno == ENOENT else { throw unavailable() }
                projections.append(["file": name, "missing": true])
                continue
            }
            let data: Data
            do {
                defer { close(fd) }
                var before = stat()
                guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                      before.st_uid == getuid(), before.st_nlink == 1, before.st_size >= 0, before.st_size <= 1_048_576 else { throw unavailable() }
                var bytes = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
                while true {
                    let count = Darwin.read(fd, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    guard count >= 0, bytes.count + max(0, count) <= 1_048_576 else { throw unavailable() }
                    if count == 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
                var after = stat(), current = stat()
                guard fstat(fd, &after) == 0, fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      statIdentity(before) == statIdentity(after), statIdentity(before) == statIdentity(current),
                      bytes.count == before.st_size else { throw unavailable() }
                data = bytes
            }
            total += data.count
            guard total <= 4 * 1_048_576 else { throw unavailable() }
            let object: [String: Any]
            do {
                guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw unavailable() }
                object = value
            } catch { throw unavailable() }
            let projection = try authProjection(object, credentials: name == ".credentials.json")
            if name == ".credentials.json", let oauth = object["claudeAiOauth"] as? [String: Any] {
                hasOAuth = ["accessToken", "refreshToken"].contains { (oauth[$0] as? String)?.isEmpty == false }
            }
            projections.append(["file": name, "auth": projection])
        }
        var currentRoot = stat()
        guard lstat(root.path, &currentRoot) == 0, currentRoot.st_dev == directoryInfo.st_dev,
              currentRoot.st_ino == directoryInfo.st_ino, currentRoot.st_mode & S_IFMT == S_IFDIR else { throw unavailable() }
        return (try hashJSON(["accountID": accountID, "root": root.path.precomposedStringWithCanonicalMapping, "keychainAccount": keychainIdentity(root: root, environment: environment).account, "files": projections]), hasOAuth)
    }

    static func authProjection(_ object: [String: Any], credentials: Bool) throws -> [String: Any] {
        if let helper = object["apiKeyHelper"], !(helper is NSNull) {
            guard let text = helper as? String, text.isEmpty else { throw unavailable() }
        }
        if let gateway = object["forceLoginGatewayUrl"], !(gateway is NSNull) {
            guard let text = gateway as? String, text.isEmpty else { throw unavailable() }
        }
        if let value = object["env"] {
            guard let environment = value as? [String: Any] else { throw unavailable() }
            for (key, value) in environment where isAuthEnvironment(key) {
                guard value is NSNull || (value as? String)?.isEmpty == true else { throw unavailable() }
            }
        }
        var result: [String: Any] = [:]
        for key in ["forceLoginOrgUUID", "forceLoginMethod", "primaryApiKey", "apiKey", "customApiKeyResponses"] {
            if let value = object[key] { result[key] = value }
        }
        if let method = object["forceLoginMethod"], !(method is NSNull) {
            guard let method = method as? String, method == "claudeai" else { throw unavailable() }
        }
        if let account = object["oauthAccount"], !(account is NSNull) {
            guard let account = account as? [String: Any] else { throw unavailable() }
            var identity: [String: Any] = [:]
            for key in ["accountUuid", "organizationUuid"] { if let value = account[key] { identity[key] = value } }
            result["oauthAccount"] = identity
        }
        if credentials, let oauth = object["claudeAiOauth"], !(oauth is NSNull) {
            guard oauth is [String: Any] else { throw unavailable() }
            result["claudeAiOauth"] = oauth
        }
        return result
    }

    private static func validateEnvironment(_ environment: [String: String]) throws {
        for (name, value) in environment where !value.isEmpty && name != "CLAUDE_CONFIG_DIR" {
            if isAuthEnvironment(name) { throw unavailable() }
        }
    }

    private static func isAuthEnvironment(_ name: String) -> Bool {
        if removedEnvironment.contains(name) || [
            "ANTHROPIC_CUSTOM_HEADERS", "CLAUDE_CODE_FORCE_WINDOWS_CREDMAN", "CLAUDE_CODE_ENABLE_XAA",
            "ANTHROPIC_PROFILE", "ANTHROPIC_CONFIG_DIR", "CLAUDE_CODE_FEDERATION_CACHE_DIR",
            "ANTHROPIC_IDENTITY_TOKEN_FILE", "ANTHROPIC_SERVICE_ACCOUNT_ID", "ANTHROPIC_WORKSPACE_ID", "ANTHROPIC_SCOPE",
            "CLAUDE_CODE_USE_COWORK_PLUGINS", "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_CONFIG", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS",
            "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST", "CLAUDE_CODE_REMOTE_SETTINGS_PATH", "CLAUDE_CODE_MANAGED_SETTINGS_PATH"
        ].contains(name) { return true }
        return (name.hasPrefix("CLAUDE_") || name.hasPrefix("ANTHROPIC_")) &&
            (name.contains("AUTH") || name.contains("CREDENTIAL") || name.contains("SECURESTORAGE") || name.contains("HOST_") || name.hasSuffix("_TOKEN") || name.hasSuffix("_TOKEN_FILE") || name.contains("API_KEY"))
    }

    private static func statIdentity(_ value: stat) -> String {
        "\(value.st_dev):\(value.st_ino):\(value.st_mode):\(value.st_uid):\(value.st_nlink):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
    }
    private static func hashJSON(_ value: Any) throws -> String { hash(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func validDigest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func unavailable() -> TerminalError { .invalid("Claude authentication identity is unavailable or changed; verify the managed profile again") }
}
