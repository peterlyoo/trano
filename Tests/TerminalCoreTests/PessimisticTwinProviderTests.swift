import Foundation
import Darwin
import XCTest
@testable import TerminalCore

final class PessimisticTwinProviderTests: XCTestCase {
    // Implements: FR-TWIN-3, FR-TWIN-4, FR-TWIN-10
    private let sourceID = "11111111-1111-4111-8111-111111111111"
    private let runID = "22222222-2222-4222-8222-222222222222"
    private func request(_ provider: AgentKind = .claude, _ mode: TwinReviewMode = .codeReview, worktree: String = "/fixture/worktree", profile: String = "/fixture/private/profile", prompt: String = "Snapshot diff only") -> TwinProviderRequest {
        TwinProviderRequest(provider: provider, mode: mode, sourceConversationID: sourceID, worktree: worktree,
            configurationRoot: "/fixture/source-profile", privateProfileRoot: profile, providerExecutable: "/fixture/bin/" + provider.rawValue,
            helperExecutable: "/fixture/Trano app/trano", apiSocketPath: "/fixture/runtime/api.sock", runID: runID, round: 1, prompt: prompt)
    }
    func testClaudeForkUsesExactIDAndPrivateAccountProfileWithoutBypass() throws {
        let plan = try TwinProviderPlanner.plan(request())
        XCTAssertEqual(plan.executable, "/fixture/bin/claude")
        XCTAssertEqual(plan.arguments, plan.providerArguments)
        XCTAssertNil(plan.files["sandbox.sb"])
        let resume = try XCTUnwrap(plan.providerArguments.firstIndex(of: "--resume"))
        XCTAssertEqual(plan.providerArguments[resume + 1], sourceID)
        XCTAssertTrue(plan.providerArguments.contains("--fork-session"))
        XCTAssertEqual(plan.environment["CLAUDE_CONFIG_DIR"], "/fixture/private/profile")
        XCTAssertEqual(plan.configurationRoot, "/fixture/private/profile")
        XCTAssertFalse(plan.providerArguments.contains(where: { $0.contains("bypass") || $0.contains("skip-permissions") || $0 == "--last" }))
        XCTAssertTrue(plan.removeEnvironment.contains("CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS"))
        XCTAssertTrue(plan.removeEnvironment.contains("ANTHROPIC_AUTH_TOKEN"))
    }
    func testCodexForkCarriesExplicitCWDNamedWorkspaceSandboxAndRefusesEscalation() throws {
        let plan = try TwinProviderPlanner.plan(request(.codex, .generalReview))
        XCTAssertTrue(plan.providerArguments.contains("fork"))
        XCTAssertTrue(plan.providerArguments.contains(sourceID))
        func after(_ option: String) throws -> String { let i = try XCTUnwrap(plan.providerArguments.firstIndex(of: option)); return plan.providerArguments[i + 1] }
        XCTAssertFalse(plan.providerArguments.contains("-s"))
        XCTAssertFalse(plan.providerArguments.contains("-P"))
        XCTAssertTrue(plan.providerArguments.contains("default_permissions=\"trano_twin\""))
        XCTAssertTrue(plan.providerArguments.contains("--strict-config"))
        XCTAssertEqual(try after("-C"), "/fixture/worktree")
        XCTAssertEqual(try after("-a"), "never")
        let config = String(decoding: try XCTUnwrap(plan.files["config.toml"]), as: UTF8.self)
        for required in ["network_proxy = true", "js_repl = false", "plugins = false", "apps = false", "[permissions.trano_twin.filesystem]", "\"/\" = \"read\"", "\"/fixture/worktree/.git\" = \"read\"", "[permissions.trano_twin.network.unix_sockets]", "\"/fixture/runtime/api.sock\" = \"allow\""] { XCTAssertTrue(config.contains(required), required) }
        XCTAssertFalse(config.contains("extends"))
        XCTAssertFalse(config.contains(":slash_tmp"))
        XCTAssertTrue(plan.providerArguments.contains("--no-daemon"))
        XCTAssertTrue(plan.providerArguments.contains("skills.include_instructions=false"))
        XCTAssertTrue(config.contains("skills = { include_instructions = false }"))
        XCTAssertEqual(plan.environment["CODEX_HOME"], "/fixture/private/profile")
        XCTAssertEqual(plan.environment["CODEX_SQLITE_HOME"], "/fixture/private/profile")
        XCTAssertFalse(plan.providerArguments.contains(where: { $0.contains("bypass") || $0 == "--approve-for-me" }))
    }
    func testCodexPinsUntrustedProjectAndOnlyAppOwnedNormalizedHookTrust() throws {
        let plan = try TwinProviderPlanner.plan(request(.codex))
        XCTAssertEqual(plan.environment["SHELL"], "/bin/bash")
        XCTAssertFalse(plan.providerArguments.contains(where: { $0.hasPrefix("hooks=") }))
        XCTAssertTrue(plan.providerArguments.contains("projects.\"/fixture/worktree\".trust_level=\"untrusted\""))
        let config = String(decoding: try XCTUnwrap(plan.files["config.toml"]), as: UTF8.self)
        for key in ["/fixture/private/profile/config.toml:session_start:0:0", "/fixture/private/profile/config.toml:stop:0:0", "/fixture/private/profile/config.toml:user_prompt_submit:0:0"] { XCTAssertTrue(config.contains(key), key) }
        for hash in ["sha256:e7056da9c0ae9a072daa10fb519f8117e2dfa255b6ea1d3fc86671a8d1104614", "sha256:20567f53bc0c4e16f2df219665e9446611c2fa745ff40081ee09a42d9aeaacca"] { XCTAssertTrue(config.contains(hash), hash) }
        XCTAssertFalse(config.contains("<session-flags>"))
        XCTAssertFalse(config.contains("bypass_hook_trust"))
    }
    func testVersionGateAcceptsOnlyPinnedVerifiedProviderVersions() throws {
        try TwinProviderPlanner.validateVersion(provider: .claude, output: "2.1.323 (Claude Code)\n")
        try TwinProviderPlanner.validateVersion(provider: .codex, output: "codex-cli 0.167.0\n")
        for (provider, output) in [(AgentKind.claude, "2.1.322 (Claude Code)"), (.claude, "2.1.324 (Claude Code)"), (.codex, "codex-cli 0.168.0"), (.codex, "codex-cli 0.167.0\nwarning"), (.shell, "codex-cli 0.167.0")] {
            XCTAssertThrowsError(try TwinProviderPlanner.validateVersion(provider: provider, output: output))
        }
    }
    func testSecurityStartsFreshWithoutOriginalConversationContextOrSeedReferences() throws {
        for provider in [AgentKind.claude, .codex] {
            let plan = try TwinProviderPlanner.plan(request(provider, .securityReview))
            XCTAssertFalse(plan.providerArguments.contains("fork"))
            XCTAssertFalse(plan.providerArguments.contains("--resume"))
            XCTAssertFalse(plan.providerArguments.contains("--fork-session"))
            XCTAssertFalse(plan.providerArguments.joined().contains(sourceID))
            XCTAssertFalse(plan.environment.values.joined().contains(sourceID))
            XCTAssertFalse(plan.files.values.map { String(decoding: $0, as: UTF8.self) }.joined().contains(sourceID))
            XCTAssertTrue(plan.providerArguments.joined().contains("Security review"))
            XCTAssertTrue(plan.providerArguments.joined().contains("Snapshot diff only"))
        }
    }
    func testClaudeSettingsApplyFileToolAndStrictShellBoundariesWithNativeHooks() throws {
        let plan = try TwinProviderPlanner.plan(request())
        let data = try XCTUnwrap(plan.files["settings.json"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let permissions = try XCTUnwrap(object["permissions"] as? [String: Any])
        XCTAssertEqual(permissions["blockWritesOutsideWorkingDirectories"] as? Bool, true)
        XCTAssertEqual(permissions["defaultMode"] as? String, "acceptEdits")
        XCTAssertEqual((permissions["additionalDirectories"] as? [String]) ?? [], [])
        XCTAssertEqual(permissions["deny"] as? [String], ["mcp__*"])
        let sandbox = try XCTUnwrap(object["sandbox"] as? [String: Any])
        XCTAssertEqual(sandbox["enabled"] as? Bool, true)
        XCTAssertEqual(sandbox["failIfUnavailable"] as? Bool, true)
        XCTAssertEqual(sandbox["allowUnsandboxedCommands"] as? Bool, false)
        let network = try XCTUnwrap(sandbox["network"] as? [String: Any])
        XCTAssertEqual(network["allowedDomains"] as? [String], [])
        XCTAssertEqual(network["allowUnixSockets"] as? [String], ["/fixture/runtime/api.sock"])
        XCTAssertTrue(plan.providerArguments.contains("--restricted"))
        XCTAssertTrue(plan.providerArguments.contains("--disable-slash-commands"))
        XCTAssertTrue(plan.providerArguments.contains("Bash,Read,Glob,Grep,Edit,Write"))
        let fs = try XCTUnwrap(sandbox["filesystem"] as? [String: Any])
        XCTAssertEqual(fs["allowWrite"] as? [String], ["/fixture/private/profile/tmp"])
        XCTAssertTrue((fs["denyWrite"] as? [String])?.contains("/fixture/worktree/.git") == true)
        XCTAssertTrue(plan.providerArguments.contains("--strict-mcp-config"))
        let i = try XCTUnwrap(plan.providerArguments.firstIndex(of: "--setting-sources"))
        XCTAssertEqual(plan.providerArguments[i + 1], "")
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        for event in ["SessionStart", "UserPromptSubmit", "Stop", "PermissionRequest", "PreToolUse"] {
            XCTAssertNotNil(hooks[event])
        }
        let serialized = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(serialized.contains("twin hook"))
        XCTAssertFalse(serialized.contains("|| true"))
        XCTAssertFalse(serialized.contains("bypassPermissions"))
    }
    func testRolesRequireEvidenceNativeCommitAndUntrustedApprovalContext() throws {
        for mode in [TwinReviewMode.codeReview, .securityReview, .generalReview] {
            let plan = try TwinProviderPlanner.plan(request(.claude, mode))
            let text = plan.providerArguments.joined(separator: " ")
            for value in ["Role: pessimistic", "Task:", "Objective:", "evidence", "twin commit", "twin report", "no_further_improvement", "changed_files", "not user approval"] { XCTAssertTrue(text.contains(value), value) }
            XCTAssertFalse(text.contains("git commit"))
        }
    }
    func testUnsafeOverlapTraversalAndInvalidIdentityFailBeforeProviderExecution() throws {
        for (worktree, profile) in [("/", "/fixture/profile"), ("/fixture/tree", "/fixture/tree/profile"), ("/fixture/profile/worktree", "/fixture/profile"), ("/fixture/../tree", "/fixture/profile"), ("/fixture/tree\nname", "/fixture/profile")] {
            XCTAssertThrowsError(try TwinProviderPlanner.plan(request(worktree: worktree, profile: profile)))
        }
        XCTAssertThrowsError(try TwinProviderPlanner.plan(request(.shell)))
        XCTAssertThrowsError(try TwinProviderPlanner.plan(request(prompt: String(repeating: "x", count: 32769))))
    }
}

final class PessimisticTwinProfileTests: XCTestCase {
    // Implements: FR-TWIN-3, FR-TWIN-4, FR-TWIN-10
    private struct Fixture { let base: URL; let worktree: URL; let source: URL; let profile: URL; let sourceID: String; let runID: String }
    private func fixture() throws -> Fixture {
        let base = canonicalTemporaryDirectory().appendingPathComponent("twin-provider-unit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let worktree = base.appendingPathComponent("worktree"), source = base.appendingPathComponent("source")
        for p in [worktree, source] { try FileManager.default.createDirectory(at: p, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        return Fixture(base: base, worktree: worktree, source: source, profile: base.appendingPathComponent("profile"), sourceID: "11111111-1111-4111-8111-111111111111", runID: "22222222-2222-4222-8222-222222222222")
    }
    private func plan(_ f: Fixture, _ provider: AgentKind = .claude, _ mode: TwinReviewMode = .codeReview) throws -> TwinProviderPlan {
        try TwinProviderPlanner.plan(TwinProviderRequest(provider: provider, mode: mode, sourceConversationID: f.sourceID, worktree: f.worktree.path, configurationRoot: f.source.path, privateProfileRoot: f.profile.path, providerExecutable: "/bin/" + provider.rawValue, helperExecutable: "/bin/trano", apiSocketPath: f.base.appendingPathComponent("api.sock").path, runID: f.runID, round: 1))
    }
    func testPrivateProfileContainsOnlySuppliedAuthAndExactTranscriptWithPrivatePermissions() throws {
        let f = try fixture(), p = try plan(f)
        let credential = try XCTUnwrap(fixturePrivateCredentials(.claude)[".credentials.json"])
        let path = "projects/project/" + f.sourceID + ".jsonl", transcript = Data("{\"sessionId\":\"\(f.sourceID)\",\"type\":\"user\"}\n".utf8)
        try TwinProviderProfile.prepare(plan: p, credentialFiles: [".credentials.json": credential], conversation: TwinConversationSeed(relativePath: path, data: transcript))
        XCTAssertEqual(try Data(contentsOf: f.profile.appendingPathComponent(path)), transcript)
        XCTAssertEqual(try Data(contentsOf: f.profile.appendingPathComponent(".credentials.json")), credential)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.worktree.appendingPathComponent(".credentials.json").path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.source.path).isEmpty)
        let permissions = try FileManager.default.attributesOfItem(atPath: f.profile.appendingPathComponent(path).path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: f.profile.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryPermissions?.intValue, 0o700)
        try TwinProviderProfile.prepare(plan: p, credentialFiles: [".credentials.json": credential], conversation: TwinConversationSeed(relativePath: path, data: transcript))
    }
    func testClaudeIdentitySeedAllowsOnlyMinimalOAuthAccountMetadata() throws {
        let f = try fixture(), p = try plan(f, .claude, .securityReview)
        let credentials = try XCTUnwrap(fixturePrivateCredentials(.claude)[".credentials.json"]), identity = Data("{\"hasCompletedOnboarding\":true,\"theme\":\"dark\",\"oauthAccount\":{\"accountUuid\":\"fixture-account\",\"organizationUuid\":\"fixture-org\",\"emailAddress\":\"fixture@example.invalid\"}}".utf8)
        XCTAssertThrowsError(try TwinProviderProfile.prepare(plan: p, credentialFiles: [".credentials.json": credentials, ".claude.json": Data("{\"permissions\":{\"defaultMode\":\"bypassPermissions\"}}".utf8)], conversation: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.profile.path))
        try TwinProviderProfile.prepare(plan: p, credentialFiles: [".credentials.json": credentials, ".claude.json": identity], conversation: nil)
        XCTAssertEqual(try Data(contentsOf: f.profile.appendingPathComponent(".claude.json")), identity)
    }
    func testSecurityProfileCannotCopySourceConversationAndContainsNoHistory() throws {
        let f = try fixture(), p = try plan(f, .codex, .securityReview)
        let credentials = try fixturePrivateCredentials(.codex)
        XCTAssertThrowsError(try TwinProviderProfile.prepare(plan: p, credentialFiles: credentials, conversation: TwinConversationSeed(relativePath: "sessions/source.jsonl", data: Data("history".utf8))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.profile.path))
        try TwinProviderProfile.prepare(plan: p, credentialFiles: credentials, conversation: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.profile.appendingPathComponent("sessions").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.profile.appendingPathComponent("projects").path))
    }
    func testMissingOrWrongConversationAndSettingsInjectionAreRejectedBeforeWrites() throws {
        let f = try fixture(), p = try plan(f)
        let credentials = [".credentials.json": Data("{\"accessToken\":\"fixture-only\"}".utf8)]
        XCTAssertThrowsError(try TwinProviderProfile.prepare(plan: p, credentialFiles: credentials, conversation: nil))
        for path in ["../escape.jsonl", "/escape.jsonl", "projects/a/33333333-3333-4333-8333-333333333333.jsonl"] {
            XCTAssertThrowsError(try TwinProviderProfile.prepare(plan: p, credentialFiles: credentials, conversation: TwinConversationSeed(relativePath: path, data: Data("record".utf8))))
        }
        XCTAssertThrowsError(try TwinProviderProfile.prepare(plan: p, credentialFiles: ["settings.json": Data("{}".utf8)], conversation: TwinConversationSeed(relativePath: "projects/a/" + f.sourceID + ".jsonl", data: Data("record".utf8))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.profile.path))
    }
    func testUnmanagedOrSymlinkedTargetsAreNeverReplaced() throws {
        let f = try fixture(), p = try plan(f, .claude, .securityReview)
        try FileManager.default.createDirectory(at: f.profile, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let sentinel = f.profile.appendingPathComponent("existing"); try Data("user-owned\n".utf8).write(to: sentinel)
        XCTAssertThrowsError(try TwinProviderProfile.prepare(plan: p, credentialFiles: [".credentials.json": Data("{}".utf8)], conversation: nil))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "user-owned\n")
        let other = try fixture(), otherPlan = try plan(other, .claude, .securityReview)
        try FileManager.default.createSymbolicLink(at: other.profile, withDestinationURL: other.source)
        XCTAssertThrowsError(try TwinProviderProfile.prepare(plan: otherPlan, credentialFiles: [".credentials.json": Data("{}".utf8)], conversation: nil))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: other.source.path).isEmpty)
    }
}

final class PessimisticTwinSandboxTests: XCTestCase {
    // Implements: FR-TWIN-4, FR-TWIN-10
    func testNativePermissionProfileKeepsSharedGitAndPrivateIdentityReadOnly() throws {
        let profile = try TwinProviderSandbox.profile(worktree: "/fixture/worktree", privateProfileRoot: "/fixture/profile", apiSocketPath: "/fixture/scoped.sock")
        for required in ["[permissions.trano_twin.filesystem]", "\"/\" = \"read\"", "\"/fixture/worktree/.git\" = \"read\"", "\"/fixture/profile/tmp\" = \"write\"", "\"/fixture/scoped.sock\" = \"allow\""] { XCTAssertTrue(profile.contains(required), required) }
        XCTAssertFalse(profile.contains("extends"))
        XCTAssertFalse(profile.contains("(allow default)"))
        XCTAssertFalse(profile.contains(":slash_tmp"))
    }

    func testNativeCodexEffectivePolicyBlocksSourceGitIdentityAndUnscopedIPC() throws {
        let executable = "/opt/homebrew/bin/codex"
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw XCTSkip("Installed Codex native sandbox primitive is unavailable") }
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("twin-native-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let worktree = base.appendingPathComponent("work"), profile = base.appendingPathComponent("profile"), source = base.appendingPathComponent("source"), git = base.appendingPathComponent("git")
        for path in [worktree, source, git] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        let secret = source.appendingPathComponent("history"); try Data("original-context".utf8).write(to: secret)
        let pointer = worktree.appendingPathComponent(".git"); try Data(("gitdir: " + git.path + "\n").utf8).write(to: pointer)
        try FileManager.default.createSymbolicLink(at: worktree.appendingPathComponent("escape"), withDestinationURL: source)
        let scoped = base.appendingPathComponent("scoped.sock"), global = base.appendingPathComponent("global.sock")
        let a = try unitSocket(scoped.path), b = try unitSocket(global.path)
        let tcp = socket(AF_INET, SOCK_STREAM, 0)
        guard tcp >= 0 else { throw TerminalError.runtime("Cannot create unit TCP listener") }
        _ = fcntl(tcp, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(tcp, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let inspected = withUnsafeMutablePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(tcp, $0, &length) } }
        guard bound == 0, inspected == 0, listen(tcp, 2) == 0 else { close(a); close(b); close(tcp); throw TerminalError.runtime("Cannot bind unit TCP listener") }
        defer { close(a); close(b); close(tcp) }
        let request = TwinProviderRequest(provider: .codex, mode: .securityReview, sourceConversationID: "11111111-1111-4111-8111-111111111111", worktree: worktree.path, configurationRoot: source.path, privateProfileRoot: profile.path, providerExecutable: executable, helperExecutable: "/usr/bin/true", apiSocketPath: scoped.path, runID: "22222222-2222-4222-8222-222222222222", round: 1)
        let plan = try TwinProviderPlanner.plan(request)
        let localConfig = worktree.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: localConfig, withIntermediateDirectories: false)
        try Data("[permissions.trano_twin.filesystem]\n\"/\"=\"write\"\n".utf8).write(to: localConfig.appendingPathComponent("config.toml"))
        let projectTrust = try XCTUnwrap(plan.providerArguments.first(where: { $0.hasPrefix("projects.") }))
        try TwinProviderProfile.prepare(plan: plan, credentialFiles: try fixturePrivateCredentials(.codex), conversation: nil)
        let socketClient = "import socket,sys;s=socket.socket(socket.AF_UNIX);s.connect(sys.argv[1])"
        let cases: [([String], Bool)] = [
            (["/usr/bin/touch", worktree.appendingPathComponent("new").path], true),
            (["/usr/bin/touch", profile.appendingPathComponent("tmp/new").path], true),
            (["/usr/bin/touch", pointer.path], false),
            (["/usr/bin/touch", git.appendingPathComponent("new").path], false),
            (["/usr/bin/touch", source.appendingPathComponent("new").path], false),
            (["/usr/bin/touch", worktree.appendingPathComponent("escape/new").path], false),
            (["/bin/cat", secret.path], false),
            (["/bin/cat", profile.appendingPathComponent("auth.json").path], false),
            (["/usr/bin/touch", profile.appendingPathComponent("config.toml").path], false),
            (["/usr/bin/python3", "-I", "-S", "-B", "-c", socketClient, scoped.path], true),
            (["/usr/bin/python3", "-I", "-S", "-B", "-c", socketClient, global.path], false),
            (["/usr/bin/nc", "-G", "1", "-z", "127.0.0.1", String(UInt16(bigEndian: address.sin_port))], false)
        ]
        for (arguments, allowed) in cases {
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-c", projectTrust, "sandbox", "-P", "trano_twin", "-C", worktree.path, "--"] + arguments
            process.environment = ProcessInfo.processInfo.environment.merging(plan.environment) { _, new in new }
            process.standardOutput = Pipe(); process.standardError = Pipe()
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus == 0, allowed, arguments.joined(separator: " "))
        }
    }

}

private func canonicalTemporaryDirectory() -> URL {
    let original = FileManager.default.temporaryDirectory.path
    guard let resolved = realpath(original, nil) else { fatalError("Cannot resolve private temporary root") }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved))
}

private func unitSocket(_ path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw TerminalError.runtime("Cannot create unit socket") }
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(fd); throw TerminalError.runtime("Unit socket path exceeds limit") }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in bytes.withUnsafeBytes { destination.copyMemory(from: $0) } }
    let result = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard result == 0, listen(fd, 4) == 0 else { close(fd); throw TerminalError.runtime("Cannot bind unit socket") }
    return fd
}

private func fixturePrivateCredentials(_ provider: AgentKind) throws -> [String: Data] {
    let expiry = Date().addingTimeInterval(3600).timeIntervalSince1970
    if provider == .claude {
        return [".credentials.json": try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": "fixture-only", "refreshToken": NSNull(), "expiresAt": expiry * 1000, "scopes": ["user:inference"]]])]
    }
    let claims = try JSONSerialization.data(withJSONObject: ["exp": expiry])
    let access = "fixture." + claims.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".signature"
    return ["auth.json": try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgptAuthTokens", "tokens": ["access_token": access, "id_token": "fixture-id", "refresh_token": ""]])]
}
