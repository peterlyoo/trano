import Foundation
import XCTest
@testable import TerminalCore

final class PessimisticTwinAuthenticationTests: XCTestCase {
    // Implements: FR-TWIN-3, FR-TWIN-4, FR-TWIN-10
    func testDivergentValidFileAndKeychainCannotSelectAnotherAccount() throws {
        let directory = try fixture(), original = source(directory)
        let first = Data("{\"claudeAiOauth\":{\"accessToken\":\"account-A\"}}\n".utf8)
        let second = Data("{\"claudeAiOauth\":{\"accessToken\":\"account-B\"}}\n".utf8)
        try write(first, to: directory.appendingPathComponent(".credentials.json"))
        XCTAssertThrowsError(try TwinLaunchCredentialReader(keychain: { _ in second }, environmentCheck: { _ in }).credentials(source: original))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".credentials.json")), first)
    }
    func testAllCredentialBackendsAreObservedEvenWhenFileExists() throws {
        let directory = try fixture(), original = source(directory)
        let bytes = Data("{\"claudeAiOauth\":{\"accessToken\":\"same-account\"}}\n".utf8)
        try write(bytes, to: directory.appendingPathComponent(".credentials.json"))
        var calls = 0
        _ = try TwinLaunchCredentialReader(keychain: { root in calls += 1; XCTAssertEqual(root, directory.path); return bytes }, environmentCheck: { _ in }).credentials(source: original)
        XCTAssertEqual(calls, 1)
    }
    func testDefaultSourceTokenChangeDuringSnapshotCannotIssueTicket() throws {
        let f = try PessimisticTwinLaunchPreparationTests.Fixture()
        var token = "A"
        let credentials: () -> [String: Data] = { ["auth.json": Data(("{\"tokens\":{\"access_token\":\"" + token + "\"}}\n").utf8)] }
        var operations = f.preparer.operations
        operations.credentials = { _ in credentials() }
        let snapshot = operations.snapshot
        operations.snapshot = { run, round in let value = try snapshot(run, round); token = "B"; return value }
        XCTAssertThrowsError(try TwinLaunchPreparer(root: f.root, operations: operations).prepare(run: f.run, round: f.round))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("launch-ticket.json").path))
    }
    func testClaudeAccessOnlyNativeFileNeverCopiesRefreshOrInjectsHostEnvironment() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let original = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": "fixture-access", "refreshToken": "fixture-source-refresh", "expiresAt": now.addingTimeInterval(3600).timeIntervalSince1970 * 1000, "scopes": ["user:inference"], "unrelated": "drop"]])
        let access = try TwinAccessOnlyCredentials.prepare(provider: .claude, seed: .freezing([".credentials.json": original]), now: now)
        XCTAssertEqual(Set(access.files.keys), [".credentials.json", ".claude.json"])
        let data = try XCTUnwrap(access.files[".credentials.json"])
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let oauth = try XCTUnwrap(object["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(oauth["accessToken"] as? String, "fixture-access")
        XCTAssertTrue(oauth["refreshToken"] is NSNull)
        XCTAssertNil(oauth["unrelated"])
        XCTAssertFalse(data.contains(Data("fixture-source-refresh".utf8)))
        XCTAssertEqual(access.expiresAt, now.addingTimeInterval(3300))
    }
    func testCodexExternalAuthNeverReceivesSourceRefreshAndHasFiniteCutoff() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let claims = try JSONSerialization.data(withJSONObject: ["exp": now.addingTimeInterval(3600).timeIntervalSince1970])
        let jwt = "fixture." + claims.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".signature"
        let original = try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": ["access_token": jwt, "refresh_token": "fixture-source-refresh", "id_token": "fixture-id", "account_id": "fixture-account"]])
        let access = try TwinAccessOnlyCredentials.prepare(provider: .codex, seed: .freezing(["auth.json": original]), now: now)
        let data = try XCTUnwrap(access.files["auth.json"])
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tokens = try XCTUnwrap(object["tokens"] as? [String: Any])
        XCTAssertEqual(object["auth_mode"] as? String, "chatgptAuthTokens")
        XCTAssertEqual(tokens["refresh_token"] as? String, "")
        XCTAssertEqual(tokens["account_id"] as? String, "fixture-account")
        XCTAssertFalse(data.contains(Data("fixture-source-refresh".utf8)))
        XCTAssertEqual(access.expiresAt, now.addingTimeInterval(3300))
    }
    func testExpiredOrUnboundedOrNearlyExpiredTokensFailClosed() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        for expiry in [now.addingTimeInterval(-1), now.addingTimeInterval(300)] {
            let bytes = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": "fixture-access", "expiresAt": expiry.timeIntervalSince1970 * 1000]])
            XCTAssertThrowsError(try TwinAccessOnlyCredentials.prepare(provider: .claude, seed: .freezing([".credentials.json": bytes]), now: now))
        }
        let noExpiry = Data("{\"claudeAiOauth\":{\"accessToken\":\"fixture-access\"}}".utf8)
        XCTAssertThrowsError(try TwinAccessOnlyCredentials.prepare(provider: .claude, seed: .freezing([".credentials.json": noExpiry]), now: now))
    }
    func testProofDetectsSourceChangePrivateFileMutationAndUnexpectedLinks() throws {
        let root = try fixture(), files = ["auth.json": Data("fixture-private-access\n".utf8)]
        let seed = try TwinAuthenticationSeed.freezing(["auth.json": Data("fixture-source\n".utf8)])
        let proof = try TwinAuthenticationSeedProof(seed: seed, files: files, selectedOrganizationUUID: nil, expiresAt: Date().addingTimeInterval(3600))
        try write(try XCTUnwrap(files["auth.json"]), to: root.appendingPathComponent("auth.json"))
        XCTAssertNoThrow(try proof.verify(seed: seed, profileRoot: root.path))
        XCTAssertThrowsError(try proof.verify(seed: .freezing(["auth.json": Data("changed-source".utf8)]), profileRoot: root.path))
        try write(Data("changed-private".utf8), to: root.appendingPathComponent("auth.json"))
        XCTAssertThrowsError(try proof.verify(seed: seed, profileRoot: root.path))
        try write(try XCTUnwrap(files["auth.json"]), to: root.appendingPathComponent("auth.json"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("extra").path, withDestinationPath: "auth.json")
        XCTAssertThrowsError(try proof.verify(seed: seed, profileRoot: root.path))
        let encoded = try JSONEncoder().encode(proof)
        XCTAssertFalse(encoded.contains(Data("fixture-private-access".utf8)))
        XCTAssertFalse(encoded.contains(Data("fixture-source".utf8)))
    }
    func testSourceCredentialChangeInsideOrganizationPreflightCannotIssueTicket() throws {
        let f = try PessimisticTwinLaunchPreparationTests.Fixture()
        var changed = false, operations = f.preparer.operations
        operations.credentials = { _ in changed ? ["auth.json": Data("changed-auth".utf8)] : f.credentials }
        operations.organization = { _, _ in changed = true; return nil }
        XCTAssertThrowsError(try TwinLaunchPreparer(root: f.root, operations: operations).prepare(run: f.run, round: f.round))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("launch-ticket.json").path))
    }
    func testProfileTamperAfterInitialProofCannotIssueTicket() throws {
        let f = try PessimisticTwinLaunchPreparationTests.Fixture()
        var operations = f.preparer.operations, mutated = false
        let context = operations.context
        operations.context = { run in
            let result = try context(run)
            let auth = f.directory.appendingPathComponent("profile/auth.json")
            if !mutated, FileManager.default.fileExists(atPath: auth.path) {
                try Data("changed-private-auth".utf8).write(to: auth); mutated = true
            }
            return result
        }
        XCTAssertThrowsError(try TwinLaunchPreparer(root: f.root, operations: operations).prepare(run: f.run, round: f.round))
        XCTAssertTrue(mutated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("launch-ticket.json").path))
    }
    func testSelectedOrganizationPinsOnlyNativeIdentityAndRuntimeReadBoundary() throws {
        let org = UUID().uuidString.lowercased(), run = UUID().uuidString.lowercased()
        let request = TwinProviderRequest(provider: .claude, mode: .securityReview, sourceConversationID: UUID().uuidString.lowercased(), worktree: "/runtime/twins/own/worktree", configurationRoot: "/source/profile", privateProfileRoot: "/runtime/twins/own/profile", providerExecutable: "/opt/provider/claude", helperExecutable: "/signed/helper", apiSocketPath: "/runtime/twin-" + run + ".sock", runID: run, round: 1, selectedOrganizationUUID: org)
        let plan = try TwinProviderPlanner.plan(request)
        let settings = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(plan.files["settings.json"])) as? [String: Any])
        XCTAssertEqual(settings["forceLoginOrgUUID"] as? String, org)
        XCTAssertEqual(settings["forceLoginMethod"] as? String, "claudeai")
        let sandbox = try XCTUnwrap(settings["sandbox"] as? [String: Any]), filesystem = try XCTUnwrap(sandbox["filesystem"] as? [String: Any])
        XCTAssertTrue(try XCTUnwrap(filesystem["denyRead"] as? [String]).contains("/runtime"))
        XCTAssertEqual(Set(try XCTUnwrap(filesystem["allowRead"] as? [String])), [request.worktree, request.privateProfileRoot + "/tmp", request.apiSocketPath])
        XCTAssertNil(plan.environment["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertFalse(plan.arguments.joined().contains(request.sourceConversationID))
    }
    func testExpiredProofCanBeDecodedForExitReceiptButCannotAdmitLaunch() throws {
        let root = try fixture(), seed = try TwinAuthenticationSeed.freezing(["auth.json": Data("fixture".utf8)])
        let proof = try TwinAuthenticationSeedProof(seed: seed, files: seed.credentialFiles, selectedOrganizationUUID: nil, expiresAt: Date().addingTimeInterval(3600))
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoder.encode(proof)) as? [String: Any])
        object["expiresAt"] = Date().addingTimeInterval(-60).timeIntervalSinceReferenceDate
        let expired = try decoder.decode(TwinAuthenticationSeedProof.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNoThrow(try expired.validate())
        XCTAssertThrowsError(try expired.verify(seed: seed, profileRoot: root.path))
    }
    func testProcessArgumentParserReturnsOnlyNonemptyOverrideKeysNeverValues() throws {
        func bytes(_ environment: [String]) -> [UInt8] {
            var argc: Int32 = 2
            var result = withUnsafeBytes(of: &argc) { Array($0) }
            result += Array("/fixture/provider\0\0provider\0--flag\0".utf8)
            result += Array((environment.joined(separator: "\0") + "\0\0").utf8)
            return result
        }
        let fixture = bytes(["PATH=/usr/bin", "CLAUDE_CONFIG_DIR=/own/root", "CLAUDE_CODE_OAUTH_TOKEN=TRANO_DUMMY_SECRET", "ANTHROPIC_AUTH_TOKEN=", "OPENAI_API_KEY=OTHER_PROVIDER"])
        let keys = try TwinSourceEnvironment.overrideKeys(in: fixture, provider: .claude)
        XCTAssertEqual(keys, ["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertFalse(keys.joined().contains("TRANO_DUMMY_SECRET"))
        XCTAssertEqual(try TwinSourceEnvironment.overrideKeys(in: fixture, provider: .codex), ["OPENAI_API_KEY"])
        XCTAssertTrue(try TwinSourceEnvironment.overrideKeys(in: bytes(["CLAUDE_CONFIG_DIR=/own/root", "CLAUDE_CODE_OAUTH_TOKEN=", "TERM=xterm-256color"]), provider: .claude).isEmpty)
        XCTAssertThrowsError(try TwinSourceEnvironment.overrideKeys(in: bytes([]), provider: .claude))
        var truncated = bytes(["PATH=/usr/bin"]); truncated.removeLast(2)
        XCTAssertThrowsError(try TwinSourceEnvironment.overrideKeys(in: truncated, provider: .claude))
        for malformed in [[], [1, 2, 3], Array(repeating: UInt8(0xff), count: 8), Array(repeating: UInt8(0), count: 1_048_577)] {
            XCTAssertThrowsError(try TwinSourceEnvironment.overrideKeys(in: malformed, provider: .claude))
        }
    }
    func testSourceEnvironmentNativeReadIsBirthBoundAndOverrideRefusesWithoutSecretInError() throws {
        let original = source(try fixture())
        var argc: Int32 = 1
        var bytes = withUnsafeBytes(of: &argc) { Array($0) }
        bytes += Array("/provider\0provider\0CLAUDE_CODE_OAUTH_TOKEN=TRANO_DUMMY_SECRET\0\0".utf8)
        XCTAssertThrowsError(try TwinSourceEnvironment.validate(source: original, read: { _ in bytes }, identity: { _ in original.providerIdentity })) { error in
            XCTAssertFalse(error.localizedDescription.contains("TRANO_DUMMY_SECRET"))
        }
        var reads = 0
        XCTAssertThrowsError(try TwinSourceEnvironment.validate(source: original, read: { _ in reads += 1; return bytes }, identity: { _ in nil }))
        XCTAssertEqual(reads, 0)
    }
    func testClaudePrivateUIOnboardingPreferencesNeverImportSourceTrust() throws {
        let data = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": "fixture-access", "refreshToken": "source-refresh", "expiresAt": Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000, "scopes": ["user:inference"]]])
        let sourceUI = Data("{\"oauthAccount\":{\"accountUuid\":\"account\"},\"projects\":{\"/source\":{\"hasTrustDialogAccepted\":true}},\"bypassPermissionsModeAccepted\":true}".utf8)
        let access = try TwinAccessOnlyCredentials.prepare(provider: .claude, seed: .freezing([".credentials.json": data, ".claude.json": sourceUI]))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(access.files[".claude.json"])) as? [String: Any])
        XCTAssertEqual(object["hasCompletedOnboarding"] as? Bool, true)
        XCTAssertEqual(object["theme"] as? String, "dark")
        XCTAssertNil(object["projects"])
        XCTAssertNil(object["bypassPermissionsModeAccepted"])
    }
    func testNativeOwnedFixtureEnvironmentProvenanceMatchesPureParserWithoutProvider() throws {
        for override in [false, true] {
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-I", "-S", "-B", "-u", "-c", "import sys;sys.stdout.write(\"TRANO_READY\\n\");sys.stdout.flush();sys.stdin.buffer.read()"]
            process.standardInput = input; process.standardOutput = output; process.standardError = Pipe()
            process.environment = ["PATH": "/usr/bin:/bin"]
            if override { process.environment?["CLAUDE_CODE_OAUTH_TOKEN"] = "TRANO_DUMMY_ONLY" }
            try process.run()
            defer { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            let handshake = Data("TRANO_READY\n".utf8)
            XCTAssertEqual(try output.fileHandleForReading.read(upToCount: handshake.count), handshake)
            let birth = try XCTUnwrap(SupervisorProcessIdentity.read(process.processIdentifier))
            let source = TwinSourceBinding(paneID: UUID().uuidString, generation: UUID().uuidString, conversationID: UUID().uuidString, cwd: "/fixture", configurationRoot: "/fixture/config", provider: .claude, backendPID: getpid(), providerPID: process.processIdentifier, backendIdentity: try XCTUnwrap(SupervisorProcessIdentity.read(getpid())), providerIdentity: birth)
            let raw = try TwinSourceEnvironment.nativeArguments(process.processIdentifier)
            if override { XCTAssertTrue(String(decoding: raw, as: UTF8.self).contains("TRANO_DUMMY_ONLY")) }
            if override { XCTAssertThrowsError(try TwinSourceEnvironment.validate(source: source)) }
            else { XCTAssertNoThrow(try TwinSourceEnvironment.validate(source: source)) }
        }
    }
    private func fixture() throws -> URL {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("twin-auth-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func source(_ directory: URL) -> TwinSourceBinding {
        .init(paneID: UUID().uuidString, generation: UUID().uuidString, conversationID: UUID().uuidString, cwd: "/project", configurationRoot: directory.path,
            provider: .claude, backendPID: 42, providerPID: 43, backendIdentity: .init(pid: 42, ownerUID: getuid(), startedAtSeconds: 1, startedAtMicroseconds: 0), providerIdentity: .init(pid: 43, ownerUID: getuid(), startedAtSeconds: 2, startedAtMicroseconds: 0))
    }
    private func write(_ data: Data, to path: URL) throws {
        try data.write(to: path); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}
