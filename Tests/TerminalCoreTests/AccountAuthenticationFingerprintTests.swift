import Foundation
import XCTest
import Security
import LocalAuthentication
@testable import TerminalCore

final class AccountAuthenticationFingerprintTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    // Implements: FR-ORG-3
    func testFingerprintRequiresThreeLowercaseSHA256Digests() throws {
        let valid = AccountAuthenticationFingerprint(ownedFilesDigest: digest, keychainDigest: digest, executableDigest: digest)
        XCTAssertTrue(valid.isValid)
        XCTAssertFalse(AccountAuthenticationFingerprint(ownedFilesDigest: digest.uppercased(), keychainDigest: digest, executableDigest: digest).isValid)
        XCTAssertFalse(AccountAuthenticationFingerprint(ownedFilesDigest: "abc", keychainDigest: digest, executableDigest: digest).isValid)
        XCTAssertEqual(try JSONDecoder().decode(AccountAuthenticationFingerprint.self, from: JSONEncoder().encode(valid)), valid)
    }

    // Implements: FR-ORG-3
    func testOwnedAuthChangesInvalidateButProjectHookEmailAndMCPOAuthWritesStayStable() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try write(["claudeAiOauth": ["accessToken": "fake-A", "refreshToken": "fake-R"], "mcpOAuth": ["noise": "one"]], ".credentials.json", root)
        try write(["oauthAccount": ["accountUuid": "account-A", "organizationUuid": "org-A", "emailAddress": "ignored"], "projects": ["one": 1]], ".claude.json", root)
        try write(["forceLoginOrgUUID": "org-A", "forceLoginMethod": "claudeai", "hooks": ["one": 1]], "settings.json", root)
        let reader = fakeReader()
        let before = try reader.capture(accountID: "profile-A", root: root, runtimeRoot: root)
        try write(["mcpOAuth": ["noise": "two"], "claudeAiOauth": ["refreshToken": "fake-R", "accessToken": "fake-A"]], ".credentials.json", root)
        try write(["oauthAccount": ["accountUuid": "account-A", "organizationUuid": "org-A", "emailAddress": "changed", "orgName": "ignored"], "projects": ["two": 2], "numStartups": 40], ".claude.json", root)
        try write(["hooks": ["two": 2], "forceLoginMethod": "claudeai", "forceLoginOrgUUID": "org-A"], "settings.json", root)
        XCTAssertEqual(try reader.capture(accountID: "profile-A", root: root, runtimeRoot: root), before)
        try reader.validateLocalSources(before, accountID: "profile-A", root: root, runtimeRoot: root)
        for file in ["settings.json", "trano-settings.json", ".claude.json", ".config.json", ".credentials.json"] {
            let saved = try? Data(contentsOf: root.appendingPathComponent(file))
            if file == ".credentials.json" { try write(["claudeAiOauth": ["accessToken": "changed"]], file, root) }
            else if file.hasSuffix("settings.json") { try write(["forceLoginOrgUUID": "changed"], file, root) }
            else { try write(["oauthAccount": ["organizationUuid": "changed"]], file, root) }
            XCTAssertThrowsError(try reader.validateLocalSources(before, accountID: "profile-A", root: root, runtimeRoot: root), file)
            if let saved { try saved.write(to: root.appendingPathComponent(file), options: .atomic) }
            else { try FileManager.default.removeItem(at: root.appendingPathComponent(file)) }
        }
    }

    // Implements: FR-ORG-3
    func testPureValidationNeverReadsKeychainAndRejectsChangedExecutableIdentity() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try write(["claudeAiOauth": ["accessToken": "fake"]], ".credentials.json", root)
        var keychainQueries = 0, versions: [Bool] = [], executable = digest, user = "test-user"
        let reader = ClaudeAuthenticationIdentityReader(environment: { ["USER": user] },
            keychain: { _, _ in keychainQueries += 1; return ClaudeKeychainMetadata(exists: false, digest: self.digest) },
            executable: { _, allowVersion in versions.append(allowVersion); return executable })
        let proof = try reader.capture(accountID: "profile-A", root: root, runtimeRoot: root)
        XCTAssertEqual(keychainQueries, 2)
        XCTAssertEqual(versions, [true])
        keychainQueries = 0; versions = []
        try reader.validateLocalSources(proof, accountID: "profile-A", root: root, runtimeRoot: root)
        XCTAssertEqual(keychainQueries, 0)
        XCTAssertEqual(versions, [false])
        executable = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try reader.validateLocalSources(proof, accountID: "profile-A", root: root, runtimeRoot: root))
        XCTAssertEqual(keychainQueries, 0)
        executable = digest
        user = "another-user"
        XCTAssertThrowsError(try reader.validateLocalSources(proof, accountID: "profile-A", root: root, runtimeRoot: root))
        XCTAssertEqual(keychainQueries, 0)
    }

    // Implements: FR-ORG-3
    func testMissingCredentialsUnsafeFilesAndUnknownAuthModesAreUnavailable() throws {
        for mode in ["missing", "symlink", "oversize", "malformed", "helper", "env", "custom-oauth"] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            try write(["claudeAiOauth": ["accessToken": "fake"]], ".credentials.json", root)
            switch mode {
            case "missing": try FileManager.default.removeItem(at: root.appendingPathComponent(".credentials.json"))
            case "symlink": try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("settings.json").path, withDestinationPath: root.appendingPathComponent(".credentials.json").path)
            case "oversize": try Data(repeating: 32, count: 1_048_577).write(to: root.appendingPathComponent("settings.json"))
            case "malformed": try Data("{".utf8).write(to: root.appendingPathComponent("settings.json"))
            case "helper": try write(["apiKeyHelper": "never execute"], "settings.json", root)
            case "env": try write(["env": ["ANTHROPIC_AUTH_TOKEN": "fake"]], "trano-settings.json", root)
            default: break
            }
            let reader = fakeReader(environment: mode == "custom-oauth" ? ["CLAUDE_CODE_CUSTOM_OAUTH_URL": "https://invalid.example"] : [:])
            XCTAssertThrowsError(try reader.capture(accountID: "profile-A", root: root, runtimeRoot: root), mode)
        }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNoThrow(try fakeReader(keychainExists: true).capture(accountID: "profile-A", root: root, runtimeRoot: root))
    }

    // Implements: FR-ORG-3
    func testManagedEnvironmentAndRootSpecificKeychainServiceDerivation() throws {
        let root = URL(fileURLWithPath: "/tmp/trano-managed-profile"), runtime = URL(fileURLWithPath: "/tmp/runtime")
        var environment = ["USER": "test-user", "PATH": "/tmp/runtime/bin:/usr/bin:/bin", "REX_BLOCK": "ignored", "REX_ANY": "ignored", "TRANO_LAUNCH_ID": "ignored"]
        let removed = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CONFIG_DIR", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_HOME", "CODEX_SQLITE_HOME", "OPENAI_BASE_URL"]
        for key in removed { environment[key] = "ignored" }
        let reader = fakeReader(environment: environment)
        let effective = reader.effectiveEnvironment(accountID: "profile-A", root: root, runtimeRoot: runtime)
        XCTAssertEqual(ClaudeAuthenticationIdentityReader.removedEnvironment, removed)
        for key in removed where key != "CLAUDE_CONFIG_DIR" { XCTAssertNil(effective[key], key) }
        XCTAssertEqual(effective["CLAUDE_CONFIG_DIR"], root.path)
        XCTAssertEqual(effective["TRANO_ACCOUNT_ID"], "profile-A")
        XCTAssertEqual(effective["PATH"], "/usr/bin:/bin:" + FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path + ":/opt/homebrew/bin:/usr/local/bin")
        XCTAssertNil(effective["REX_ANY"])
        XCTAssertNil(effective["TRANO_LAUNCH_ID"])
        let identity = ClaudeAuthenticationIdentityReader.keychainIdentity(root: root, environment: effective)
        XCTAssertEqual(identity.services, ["Claude Code-credentials-c296212f", "Claude Code-c296212f"])
        XCTAssertEqual(identity.account, "test-user")
        XCTAssertEqual(ClaudeAuthenticationIdentityReader.keychainIdentity(root: root, environment: ["USER": "bad user"]).account, "claude-code-user")
    }

    // Implements: FR-ORG-3
    func testProtectedHostCredentialSourcesAndLoginGatewayAreUnavailable() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try write(["claudeAiOauth": ["accessToken": "fake"]], ".credentials.json", root)
        let keys = ["ANTHROPIC_PROFILE", "ANTHROPIC_CONFIG_DIR", "CLAUDE_CODE_FEDERATION_CACHE_DIR",
                    "ANTHROPIC_IDENTITY_TOKEN_FILE", "ANTHROPIC_SERVICE_ACCOUNT_ID", "ANTHROPIC_WORKSPACE_ID", "ANTHROPIC_SCOPE",
                    "CLAUDE_CODE_SESSION_TOKEN_FILE",
                    "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST", "CLAUDE_CODE_REMOTE_SETTINGS_PATH", "CLAUDE_CODE_MANAGED_SETTINGS_PATH"]
        for key in keys {
            XCTAssertThrowsError(try fakeReader(environment: [key: "synthetic-source"]).capture(accountID: "profile-A", root: root, runtimeRoot: root), key)
        }
        try write(["forceLoginMethod": "claudeai", "forceLoginGatewayUrl": "https://gateway.invalid"], "settings.json", root)
        XCTAssertThrowsError(try fakeReader().capture(accountID: "profile-A", root: root, runtimeRoot: root))
        try write(["forceLoginGatewayUrl": NSNull()], "settings.json", root)
        XCTAssertNoThrow(try fakeReader().capture(accountID: "profile-A", root: root, runtimeRoot: root))
        try write(["forceLoginGatewayUrl": ""], "settings.json", root)
        XCTAssertNoThrow(try fakeReader(environment: ["CLAUDE_CODE_MAX_OUTPUT_TOKENS": "32000"]).capture(accountID: "profile-A", root: root, runtimeRoot: root))
    }

    // Implements: FR-ORG-3
    func testKeychainQueryIsAttributesOnlyNoninteractiveAndRejectsAmbiguityDeniedAndUnknownAttributes() throws {
        let service = "test-service", account = "test-user"
        let attributes: [String: Any] = [kSecAttrService as String: service, kSecAttrAccount as String: account,
                                        kSecAttrCreationDate as String: Date(timeIntervalSince1970: 1), kSecAttrModificationDate as String: Date(timeIntervalSince1970: 2)]
        var calls = 0
        let metadata = try ClaudeAuthenticationIdentityReader.readKeychainMetadata(service: service, account: account) { query in
            calls += 1
            XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
            for key in [kSecReturnData, kSecReturnRef, kSecReturnPersistentRef] { XCTAssertEqual(query[key as String] as? Bool, false) }
            XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitAll as String)
            XCTAssertTrue((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
            XCTAssertNil(query["u_AuthUI"])
            return (errSecSuccess, [attributes])
        }
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(metadata.exists)
        XCTAssertEqual(metadata.digest.count, 64)
        for (status, result) in [(errSecSuccess, [attributes, attributes] as Any), (errSecInteractionNotAllowed, [] as Any), (errSecSuccess, [["unknown": "value"]] as Any)] {
            XCTAssertThrowsError(try ClaudeAuthenticationIdentityReader.readKeychainMetadata(service: service, account: account) { _ in (status, result) })
        }
        XCTAssertFalse(try ClaudeAuthenticationIdentityReader.readKeychainMetadata(service: service, account: account) { _ in (errSecItemNotFound, nil) }.exists)
    }

    // Implements: FR-ORG-3
    func testPublicExecutableCacheRequiresKnownVersionAndPureReadsNeverRunVersion() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("claude")
        try Data("synthetic executable never run".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let environment = ["PATH": root.path]
        var versions = 0
        let version: (String, [String: String]) throws -> String = { _, _ in versions += 1; return "2.1.322 (Claude Code)" }
        XCTAssertThrowsError(try ClaudeAuthenticationIdentityReader.nativeExecutableIdentity(environment: environment, allowVersion: false, version: version))
        XCTAssertEqual(versions, 0)
        let first = try ClaudeAuthenticationIdentityReader.nativeExecutableIdentity(environment: environment, allowVersion: true, version: version)
        XCTAssertEqual(versions, 1)
        XCTAssertEqual(try ClaudeAuthenticationIdentityReader.nativeExecutableIdentity(environment: environment, allowVersion: false, version: version), first)
        XCTAssertEqual(versions, 1)
        try Data("changed synthetic executable".utf8).write(to: binary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        XCTAssertThrowsError(try ClaudeAuthenticationIdentityReader.nativeExecutableIdentity(environment: environment, allowVersion: false, version: version))
        XCTAssertEqual(versions, 1)
        XCTAssertThrowsError(try ClaudeAuthenticationIdentityReader.nativeExecutableIdentity(environment: environment, allowVersion: true, version: { _, _ in "9.9.9" }))
    }

    private func fakeReader(environment: [String: String] = [:], keychainExists: Bool = false) -> ClaudeAuthenticationIdentityReader {
        ClaudeAuthenticationIdentityReader(environment: { environment.merging(["USER": environment["USER"] ?? "test-user"]) { first, _ in first } },
            keychain: { _, _ in ClaudeKeychainMetadata(exists: keychainExists, digest: self.digest) }, executable: { _, _ in self.digest })
    }
    private func directory() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/trano-identity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func write(_ value: [String: Any], _ name: String, _ root: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: root.appendingPathComponent(name), options: .atomic)
    }
}
