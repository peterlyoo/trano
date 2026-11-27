import Foundation
import XCTest
@testable import TerminalCore

final class AccountAuthenticationContextTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)
    private func directory() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("trano-context-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func write(_ object: [String: Any], at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: .atomic)
    }
    private func reader() -> ClaudeAuthenticationIdentityReader {
        ClaudeAuthenticationIdentityReader(environment: { ["USER": "fixture"] }, keychain: { _, _ in
            ClaudeKeychainMetadata(exists: true, digest: self.digest)
        }, executable: { _, _ in self.digest }, contextReader: { context, root in
            try ClaudeAuthenticationContextReader(managedCandidates: [], ancestorBoundary: root.deletingLastPathComponent()).capture(context, accountRoot: root)
        })
    }
    // Implements: FR-ORG-3
    func testProjectAuthHelperCannotReuseOwnedRootProof() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let account = root.appendingPathComponent("account"), cwd = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: false)
        let reader = reader()
        let context = try ClaudeAuthenticationContext(cwd: cwd.path)
        let proof = try reader.capture(accountID: "profile", root: account, runtimeRoot: root, context: context)
        try write(["apiKeyHelper": "synthetic-helper"], at: cwd.appendingPathComponent(".claude/settings.json"))
        XCTAssertThrowsError(try reader.validateLocalSources(proof, accountID: "profile", root: account, runtimeRoot: root, context: context))
    }
    // Implements: FR-ORG-3
    func testLocalAuthEnvironmentCannotReuseOwnedRootProof() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let account = root.appendingPathComponent("account"), cwd = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: false)
        let reader = reader()
        let context = try ClaudeAuthenticationContext(cwd: cwd.path)
        let proof = try reader.capture(accountID: "profile", root: account, runtimeRoot: root, context: context)
        try write(["env": ["ANTHROPIC_AUTH_TOKEN": "synthetic-token"]], at: cwd.appendingPathComponent(".claude/settings.local.json"))
        XCTAssertThrowsError(try reader.validateLocalSources(proof, accountID: "profile", root: account, runtimeRoot: root, context: context))
    }

    // Implements: FR-ORG-3
    func testAncestorLocalAuthAndMissingFileWitnessInvalidateWhileOrdinarySettingsRemainUsable() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let account = root.appendingPathComponent("account"), cwd = root.appendingPathComponent("repo/nested")
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let settings = root.appendingPathComponent("repo/.claude/settings.local.json")
        try write(["hooks": ["fixture": []], "env": ["EDITOR": "fixture"]], at: settings)
        let reader = reader(), context = try ClaudeAuthenticationContext(cwd: cwd.path)
        let proof = try reader.capture(accountID: "profile", root: account, runtimeRoot: root, context: context)
        try write(["hooks": ["other": []], "env": ["EDITOR": "changed"], "model": "fixture"], at: settings)
        XCTAssertNoThrow(try reader.validateLocalSources(proof, accountID: "profile", root: account, runtimeRoot: root, context: context))
        try write(["forceLoginOrgUUID": "changed"], at: settings)
        XCTAssertThrowsError(try reader.validateLocalSources(proof, accountID: "profile", root: account, runtimeRoot: root, context: context))
        try write(["hooks": ["fixture": []]], at: settings)
        let missingProof = try reader.capture(accountID: "profile", root: account, runtimeRoot: root, context: context)
        try write(["forceLoginMethod": "claudeai"], at: cwd.appendingPathComponent(".claude/settings.json"))
        XCTAssertThrowsError(try reader.validateLocalSources(missingProof, accountID: "profile", root: account, runtimeRoot: root, context: context))
    }
    // Implements: FR-ORG-3
    func testContextsRemainIndependentAcrossProjectsAndRejectCrossContextProof() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let account = root.appendingPathComponent("account"), first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        for path in [account, first, second] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
        let reader = reader(), a = try ClaudeAuthenticationContext(cwd: first.path), b = try ClaudeAuthenticationContext(cwd: second.path)
        let one = try reader.capture(accountID: "profile", root: account, runtimeRoot: root, context: a)
        let two = try reader.capture(accountID: "profile", root: account, runtimeRoot: root, context: b)
        XCTAssertNotEqual(one.contextDigest, two.contextDigest)
        XCTAssertNoThrow(try reader.validateLocalSources(one, accountID: "profile", root: account, runtimeRoot: root, context: a))
        XCTAssertNoThrow(try reader.validateLocalSources(two, accountID: "profile", root: account, runtimeRoot: root, context: b))
        XCTAssertThrowsError(try reader.validateLocalSources(one, accountID: "profile", root: account, runtimeRoot: root, context: b))
        XCTAssertThrowsError(try reader.validateLocalSources(one, accountID: "profile", root: account, runtimeRoot: root))
    }
    // Implements: FR-ORG-3
    func testCwdReplacementAndSymlinkSubstitutionInvalidateProof() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let account = root.appendingPathComponent("account"), cwd = root.appendingPathComponent("project"), archived = root.appendingPathComponent("archived")
        for path in [account, cwd] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
        let reader = reader(), context = try ClaudeAuthenticationContext(cwd: cwd.path)
        let proof = try reader.capture(accountID: "profile", root: account, runtimeRoot: root, context: context)
        try FileManager.default.moveItem(at: cwd, to: archived)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: false)
        XCTAssertThrowsError(try reader.validateLocalSources(proof, accountID: "profile", root: account, runtimeRoot: root, context: context))
        try FileManager.default.removeItem(at: cwd)
        try FileManager.default.createSymbolicLink(at: cwd, withDestinationURL: archived)
        XCTAssertThrowsError(try reader.validateLocalSources(proof, accountID: "profile", root: account, runtimeRoot: root, context: context))
    }
    // Implements: FR-ORG-3
    func testUnknownManagedPolicyAndRemoteSourcesRefuseWithoutReadingPayload() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let account = root.appendingPathComponent("account"), cwd = root.appendingPathComponent("project"), policy = root.appendingPathComponent("policy.json"), drops = root.appendingPathComponent("managed-settings.d")
        for path in [account, cwd] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
        let reader = ClaudeAuthenticationContextReader(managedCandidates: [policy], managedDropInDirectories: [drops], ancestorBoundary: root)
        let context = try ClaudeAuthenticationContext(cwd: cwd.path)
        XCTAssertEqual(try reader.capture(context, accountRoot: account).count, 64)
        try Data("not parsed".utf8).write(to: policy)
        XCTAssertThrowsError(try reader.capture(context, accountRoot: account))
        try FileManager.default.removeItem(at: policy)
        try FileManager.default.createDirectory(at: drops, withIntermediateDirectories: false)
        XCTAssertThrowsError(try reader.capture(context, accountRoot: account))
        try FileManager.default.removeItem(at: drops)
        try Data("not parsed".utf8).write(to: account.appendingPathComponent("remote-settings.json"))
        XCTAssertThrowsError(try reader.capture(context, accountRoot: account))
    }
    // Implements: FR-ORG-3
    func testUnsafeSettingsDirectoriesHardlinksAndOversizedPayloadRefuse() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let account = root.appendingPathComponent("account"), cwd = root.appendingPathComponent("project"), external = root.appendingPathComponent("elsewhere")
        for path in [account, cwd, external] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
        let context = try ClaudeAuthenticationContext(cwd: cwd.path), reader = ClaudeAuthenticationContextReader(managedCandidates: [], ancestorBoundary: root)
        let folder = cwd.appendingPathComponent(".claude"), settings = folder.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: external)
        XCTAssertThrowsError(try reader.capture(context, accountRoot: account))
        try FileManager.default.removeItem(at: folder)
        try write(["hooks": [:]], at: settings)
        try FileManager.default.linkItem(at: settings, to: external.appendingPathComponent("linked"))
        XCTAssertThrowsError(try reader.capture(context, accountRoot: account))
        try FileManager.default.removeItem(at: settings)
        try Data(repeating: 32, count: 1_048_577).write(to: settings)
        XCTAssertThrowsError(try reader.capture(context, accountRoot: account))
    }
    // Implements: FR-ORG-3
    func testWorktreeMarkersAndNonNormalizedContextRefuse() throws {
        for path in ["relative", "/a/../b", "/a/./b", "/a//b", "/a\n"] {
            XCTAssertThrowsError(try ClaudeAuthenticationContext(cwd: path))
        }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let account = root.appendingPathComponent("account"), cwd = root.appendingPathComponent("project")
        for path in [account, cwd] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
        let context = try ClaudeAuthenticationContext(cwd: cwd.path), reader = ClaudeAuthenticationContextReader(managedCandidates: [], ancestorBoundary: root)
        try Data("gitdir: /unmodeled/synthetic".utf8).write(to: cwd.appendingPathComponent(".git"))
        XCTAssertThrowsError(try reader.capture(context, accountRoot: account))
    }
    // Implements: FR-ORG-3
    func testContextValidationUsesNoKeychainAndRejectsLegacyContextlessProof() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let account = root.appendingPathComponent("account"), cwd = root.appendingPathComponent("project")
        for path in [account, cwd] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
        var queries = 0
        let reader = ClaudeAuthenticationIdentityReader(environment: { ["USER": "fixture"] }, keychain: { _, _ in
            queries += 1; return ClaudeKeychainMetadata(exists: true, digest: self.digest)
        }, executable: { _, _ in self.digest }, contextReader: { context, root in
            try ClaudeAuthenticationContextReader(managedCandidates: [], ancestorBoundary: root.deletingLastPathComponent()).capture(context, accountRoot: root)
        })
        let context = try ClaudeAuthenticationContext(cwd: cwd.path)
        let legacy = try reader.capture(accountID: "profile", root: account, runtimeRoot: root)
        let proof = try reader.capture(accountID: "profile", root: account, runtimeRoot: root, context: context)
        queries = 0
        XCTAssertNoThrow(try reader.validateLocalSources(proof, accountID: "profile", root: account, runtimeRoot: root, context: context))
        XCTAssertThrowsError(try reader.validateLocalSources(legacy, accountID: "profile", root: account, runtimeRoot: root, context: context))
        XCTAssertEqual(queries, 0)
        XCTAssertEqual(try JSONDecoder().decode(AccountAuthenticationFingerprint.self, from: JSONEncoder().encode(proof)), proof)
    }
}
