import Foundation
import CryptoKit
import Darwin

public struct TwinAuthenticationSeed: Equatable {
    public let credentialFiles: [String: Data]
    public let sourceFingerprint: String
    public init(credentialFiles: [String: Data], sourceFingerprint: String) { self.credentialFiles = credentialFiles; self.sourceFingerprint = sourceFingerprint }
    public static func freezing(_ files: [String: Data]) throws -> Self {
        guard !files.isEmpty else { throw TerminalError.invalid("The source authentication seed is unavailable") }
        return Self(credentialFiles: files, sourceFingerprint: try fingerprint(files.mapValues { digest($0) }))
    }
    static func fingerprint(_ values: [String: String]) throws -> String {
        digest(try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .withoutEscapingSlashes]))
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

public struct TwinAccessOnlyCredentials: Equatable {
    public static let claudeFilename = ".credentials.json"
    public let files: [String: Data]
    public let expiresAt: Date
    public static func prepare(provider: AgentKind, seed: TwinAuthenticationSeed, now: Date = Date()) throws -> Self {
        let data: Data
        if provider == .claude { data = try required(seed.credentialFiles[".credentials.json"]) }
        else if provider == .codex { data = try required(seed.credentialFiles["auth.json"]) }
        else { throw TerminalError.invalid("This provider has no access-only twin authentication") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TerminalError.invalid("The original authentication is invalid") }
        var files: [String: Data] = [:]
        let expiry: Date
        if provider == .claude {
            guard let oauth = object["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String,
                  validToken(token), let milliseconds = oauth["expiresAt"] as? Double, milliseconds.isFinite else {
                throw TerminalError.invalid("Claude twins require a finite-lived OAuth access token from the original account")
            }
            expiry = Date(timeIntervalSince1970: milliseconds / 1000)
            guard let scopes = oauth["scopes"] as? [String], !scopes.isEmpty, scopes.count <= 32,
                  scopes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }), scopes.contains("user:inference") else {
                throw TerminalError.invalid("The original Claude access token has no usable inference scope")
            }
            var selected: [String: Any] = ["accessToken": token, "expiresAt": milliseconds, "refreshToken": NSNull(), "scopes": scopes]
            for key in ["subscriptionType", "rateLimitTier", "clientId"] {
                if let value = oauth[key] as? String {
                    guard value.utf8.count <= 512, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw TerminalError.invalid("The original Claude authentication metadata is invalid") }
                    selected[key] = value
                }
            }
            files[claudeFilename] = try json(["claudeAiOauth": selected])
            var ui: [String: Any] = ["hasCompletedOnboarding": true, "theme": "dark"]
            if let identity = seed.credentialFiles[".claude.json"] {
                guard let object = try JSONSerialization.jsonObject(with: identity) as? [String: Any] else { throw TerminalError.invalid("The original Claude account metadata is invalid") }
                if let account = object["oauthAccount"] as? [String: Any] {
                    let allowed: Set<String> = ["accountUuid", "emailAddress", "organizationUuid", "displayName", "billingType", "hasExtraUsageEnabled"]
                    let selected = account.filter { allowed.contains($0.key) }
                    guard !selected.isEmpty, selected.values.allSatisfy({ value in value is Bool || (value as? String).map { $0.utf8.count <= 4096 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) } == true }) else { throw TerminalError.invalid("The original Claude account metadata is invalid") }
                    ui["oauthAccount"] = selected
                }
            }
            files[".claude.json"] = try json(ui)
        } else {
            guard object["auth_mode"] == nil || ["chatgpt", "chatgptAuthTokens"].contains(object["auth_mode"] as? String ?? ""),
                  let tokens = object["tokens"] as? [String: Any], let access = tokens["access_token"] as? String,
                  validToken(access), let id = tokens["id_token"] as? String, validToken(id) else {
                throw TerminalError.invalid("Codex twins require original ChatGPT OAuth access tokens; alternate authentication is unavailable")
            }
            let claims = try jwtClaims(access)
            guard let seconds = claims["exp"] as? Double, seconds.isFinite else { throw TerminalError.invalid("The original Codex access token has no finite expiry") }
            expiry = Date(timeIntervalSince1970: seconds)
            var selected: [String: Any] = ["id_token": id, "access_token": access, "refresh_token": ""]
            if let account = tokens["account_id"] as? String {
                guard !account.isEmpty, account.utf8.count <= 512, !account.utf8.contains(0) else { throw TerminalError.invalid("The original Codex account is invalid") }
                selected["account_id"] = account
            }
            files["auth.json"] = try json(["auth_mode": "chatgptAuthTokens", "tokens": selected, "last_refresh": ISO8601DateFormatter().string(from: now)])
        }
        let cutoff = expiry.addingTimeInterval(-300)
        guard expiry.timeIntervalSince1970.isFinite, cutoff.timeIntervalSince(now) > 30 else { throw TerminalError.invalid("The original access token is expired or too close to expiry; renew the original session first") }
        return Self(files: files, expiresAt: cutoff)
    }
    static func validatePrivateClaude(_ files: [String: Data], now: Date = Date()) throws {
        guard let data = files[claudeFilename], let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == ["claudeAiOauth"],
              let oauth = object["claudeAiOauth"] as? [String: Any], oauth["refreshToken"] is NSNull,
              Set(oauth.keys).isSubset(of: ["accessToken", "expiresAt", "refreshToken", "scopes", "subscriptionType", "rateLimitTier", "clientId"]) else {
            throw TerminalError.invalid("A twin cannot receive source refresh credentials")
        }
        _ = try prepare(provider: .claude, seed: .freezing([claudeFilename: data]), now: now)
    }
    private static func required(_ data: Data?) throws -> Data {
        guard let data, !data.isEmpty, data.count <= 1_048_576 else { throw TerminalError.invalid("The original OAuth credential is unavailable") }; return data
    }
    private static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 65_536 && !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    private static func json(_ value: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]); data.append(10); return data
    }
    private static func jwtClaims(_ token: String) throws -> [String: Any] {
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[1].utf8.count <= 32_768 else { throw TerminalError.invalid("The original Codex access token is not a bounded JWT") }
        var encoded = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TerminalError.invalid("The original Codex access-token claims are invalid") }
        return object
    }
}

public struct TwinAuthenticationSeedProof: Codable, Equatable {
    public let sourceFingerprint: String
    public let profileFilesSHA256: [String: String]
    public let selectedOrganizationUUID: String?
    public let expiresAt: Date
    public init(seed: TwinAuthenticationSeed, files: [String: Data], selectedOrganizationUUID: String?, expiresAt: Date) throws {
        self.expiresAt = expiresAt
        sourceFingerprint = seed.sourceFingerprint
        profileFilesSHA256 = files.mapValues { TwinAuthenticationSeed.digest($0) }
        self.selectedOrganizationUUID = selectedOrganizationUUID
        try validate(now: Date())
    }
    public func validate(now: Date? = nil) throws {
        func digest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        guard expiresAt.timeIntervalSince1970.isFinite, now.map({ expiresAt > $0 }) ?? true, digest(sourceFingerprint), !profileFilesSHA256.isEmpty, profileFilesSHA256.count <= 16,
              profileFilesSHA256.allSatisfy({ path, hash in
                  !path.isEmpty && !path.hasPrefix("/") && path.utf8.count <= 4096 && digest(hash)
                    && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
                    && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
              }), selectedOrganizationUUID.map({ UUID(uuidString: $0) != nil }) ?? true else { throw TerminalError.invalid("Invalid twin authentication proof") }
    }
    public func verify(seed: TwinAuthenticationSeed, profileRoot: String) throws {
        try validate(now: Date())
        guard seed.sourceFingerprint == sourceFingerprint else { throw TerminalError.invalid("The original authentication changed after the twin was prepared") }
        let expected = Set(profileFilesSHA256.keys)
        guard try profileFiles(profileRoot) == expected else { throw TerminalError.invalid("The private twin profile contains unexpected files") }
        var total = 0
        for path in expected.sorted() {
            let limit = path.hasPrefix("projects/") || path.hasPrefix("sessions/") ? 134_217_728 : 1_048_576
            let data = try TwinLaunchPreparationFiles.readOwned(root: profileRoot, relativePath: path, limit: limit)
            total += data.count
            guard total <= 140 * 1024 * 1024, TwinAuthenticationSeed.digest(data) == profileFilesSHA256[path] else {
                throw TerminalError.invalid("The private twin authentication or configuration changed before launch")
            }
        }
    }
    private func profileFiles(_ root: String) throws -> Set<String> {
        try TwinLaunchPreparationFiles.validateDirectory(root, privateLeaf: true)
        let directory = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw TerminalError.invalid("The private twin profile is unavailable") }
        defer { close(directory) }
        var files = Set<String>(), visited = 0
        func walk(_ fd: Int32, prefix: String, depth: Int) throws {
            visited += 1
            guard depth <= 12, visited <= 64 else { throw TerminalError.invalid("The private twin profile exceeded its directory bound") }
            let duplicate = dup(fd)
            guard duplicate >= 0 else { throw TerminalError.invalid("The private twin profile directory is unavailable") }
            guard let stream = fdopendir(duplicate) else { close(duplicate); throw TerminalError.invalid("The private twin profile directory is unavailable") }
            defer { closedir(stream) }
            while let pointer = readdir(stream) {
                let name = withUnsafePointer(to: pointer.pointee.d_name) { value in value.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: pointer.pointee.d_name)) { String(cString: $0) } }
                if name == "." || name == ".." { continue }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw TerminalError.invalid("The private twin profile ownership changed") }
                if info.st_mode & S_IFMT == S_IFDIR {
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw TerminalError.invalid("The private twin profile directory changed") }
                    defer { close(child) }
                    try walk(child, prefix: path, depth: depth + 1)
                } else {
                    guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, profileFilesSHA256[path] != nil else { throw TerminalError.invalid("The private twin profile has an unexpected file or link") }
                    files.insert(path)
                }
            }
        }
        try walk(directory, prefix: "", depth: 0)
        return files
    }
}
