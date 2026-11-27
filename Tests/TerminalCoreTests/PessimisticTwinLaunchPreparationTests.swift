import Foundation
import XCTest
@testable import TerminalCore

final class PessimisticTwinLaunchPreparationTests: XCTestCase {
    // Implements: FR-TWIN-2, FR-TWIN-3, FR-TWIN-4, FR-TWIN-8
    func testPreparationFreezesExactConversationAndPrivateCredentialsOutsideWorktree() throws {
        let f = try Fixture()
        let prepared: TwinGitSnapshot
        do { prepared = try f.preparer.prepare(run: f.run, round: f.round) } catch { XCTFail("Expected successful preparation: \(error)"); return }
        XCTAssertEqual(prepared, f.snapshot)
        let ticket = try f.store.load()
        XCTAssertEqual(ticket.source, f.source)
        XCTAssertEqual(ticket.sourceCompletion, f.completion)
        XCTAssertNil(ticket.paneID)
        XCTAssertTrue(ticket.args.contains("fork"))
        XCTAssertTrue(ticket.args.contains(f.source.conversationID))
        XCTAssertEqual(ticket.configurationRoot, f.directory.appendingPathComponent("profile").path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: ticket.configurationRoot).appendingPathComponent(f.seed.relativePath)), f.seed.data)
        let copied = try Data(contentsOf: URL(fileURLWithPath: ticket.configurationRoot).appendingPathComponent("auth.json"))
        XCTAssertNotEqual(copied, f.credentials["auth.json"])
        XCTAssertFalse(copied.contains(Data("source-refresh-never-copy".utf8)))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: copied) as? [String: Any])
        XCTAssertEqual(object["auth_mode"] as? String, "chatgptAuthTokens")
        XCTAssertNotNil(ticket.authenticationSeedProof)
        XCTAssertFalse(try Data(contentsOf: f.directory.appendingPathComponent("launch-ticket.json")).contains(Data("private-fake-token".utf8)))
        XCTAssertEqual(f.events.first, "context")
        XCTAssertTrue(f.events.contains("snapshot"))
    }

    func testSecurityModeNeverReadsOrCopiesSourceConversation() throws {
        let f = try Fixture(mode: .securityReview)
        do { _ = try f.preparer.prepare(run: f.run, round: f.round) } catch { XCTFail("Expected successful preparation: \(error)"); return }
        let ticket = try f.store.load()
        XCTAssertNil(ticket.sourceTranscriptSHA256)
        XCTAssertNil(ticket.sourceTranscriptRelativePath)
        XCTAssertFalse(ticket.args.contains("fork"))
        XCTAssertFalse(ticket.args.joined().contains(f.source.conversationID))
        XCTAssertFalse(f.events.contains("conversation"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ticket.configurationRoot + "/sessions"))
    }

    func testChangedDoneBoundaryAfterSnapshotCannotCreateLaunchTicketOrSeedProfile() throws {
        let f = try Fixture(); f.changeAfterSnapshot = true
        XCTAssertThrowsError(try f.preparer.prepare(run: f.run, round: f.round))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("launch-ticket.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("profile").path))
    }

    func testStoppedPreparationDoesNotReadPrivateInputsOrSnapshot() throws {
        let f = try Fixture(); f.active = false
        XCTAssertThrowsError(try f.preparer.prepare(run: f.run, round: f.round))
        XCTAssertFalse(f.events.contains("credentials")); XCTAssertFalse(f.events.contains("snapshot"))
    }

    func testTicketMutationPreservesImmutableLaunchIdentityAndOwnedLocation() throws {
        let f = try Fixture()
        do { _ = try f.preparer.prepare(run: f.run, round: f.round) } catch { XCTFail("Expected successful preparation: \(error)"); return }
        let first = try f.store.load()
        let paneID = UUID().uuidString.lowercased()
        let reserved = try f.store.update { $0.paneID = paneID }
        XCTAssertEqual(reserved.paneID, paneID); XCTAssertNil(reserved.backendPID); XCTAssertNil(reserved.backendIdentity)
        let updated = try f.store.update { ticket in
            ticket.backendPID = 43
            ticket.backendIdentity = .init(pid: 43, ownerUID: getuid(), startedAtSeconds: 10, startedAtMicroseconds: 0)
            ticket.inputFingerprint = "before-input"; ticket.mutationStages.append("launchReserved")
        }
        XCTAssertEqual(updated.generation, first.generation)
        XCTAssertEqual(updated.source, first.source)
        XCTAssertEqual(try f.store.load(), updated)
        XCTAssertThrowsError(try f.store.update { ticket in
            ticket = TwinLaunchTicket(runID: ticket.runID, round: ticket.round, source: ticket.source,
                sourceCompletion: ticket.sourceCompletion, configurationRoot: ticket.configurationRoot,
                providerExecutable: ticket.providerExecutable, args: [], environment: [:], removeEnvironment: [])
        })
        XCTAssertEqual(try f.store.load(), updated)
        XCTAssertThrowsError(try f.store.update { $0.paneID = UUID().uuidString.lowercased() })
        XCTAssertThrowsError(try f.store.update { $0.backendPID = 44 })
        XCTAssertEqual(try f.store.load(), updated)
        XCTAssertThrowsError(try f.store.create(first))
    }

    final class Fixture {
        let root: URL
        let run: TwinRun
        let source: TwinSourceBinding
        let round: TwinRound
        let completion: TwinCompletion
        let snapshot: TwinGitSnapshot
        let seed: TwinConversationSeed
        let credentialExpiry = Date().addingTimeInterval(3600)
        var credentials: [String: Data] {
            let claims = try! JSONSerialization.data(withJSONObject: ["exp": credentialExpiry.timeIntervalSince1970], options: [.sortedKeys])
            let token = "fixture." + claims.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".signature"
            return ["auth.json": try! JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": ["access_token": token, "id_token": "fixture-id", "refresh_token": "source-refresh-never-copy"]], options: [.sortedKeys])]
        }
        var active = true
        var changeAfterSnapshot = false
        var snapshotted = false
        var events: [String] = []
        var directory: URL { root.appendingPathComponent("twins").appendingPathComponent(run.id).appendingPathComponent("round-1") }
        var store: TwinLaunchTicketStore { try! TwinLaunchTicketStore(root: root, runID: run.id, round: 1) }
        var preparer: TwinLaunchPreparer {
            TwinLaunchPreparer(root: root, operations: .init(context: { _ in
                self.events.append("context")
                return .init(source: self.source, completion: self.changeAfterSnapshot && self.snapshotted ? nil : self.completion, inputClear: true)
            }, snapshot: { _, _ in
                self.events.append("snapshot"); self.snapshotted = true
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                return self.snapshot
            }, executable: { _ in "/opt/provider/codex" }, credentials: { _ in self.events.append("credentials"); return self.credentials },
            conversation: { _, _ in self.events.append("conversation"); return self.seed }, organization: { _, _ in nil },
            revalidateOrganization: { _, _, _ in XCTFail("Unexpected organization proof") }, scopedSocket: { _ in self.root.appendingPathComponent("twin.sock").path },
            helperExecutable: "/Applications/Terminal.app/Contents/MacOS/trano", active: { self.active }))
        }
        init(mode: TwinReviewMode = .codeReview) throws {
            root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("twin-launch-unit-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let node = WorktreeFileIdentity(device: 1, inode: 2)
            source = TwinSourceBinding(paneID: UUID().uuidString.lowercased(), generation: UUID().uuidString.lowercased(), conversationID: UUID().uuidString.lowercased(),
                cwd: "/source", configurationRoot: "/source-profile", provider: .codex, backendPID: 42, providerPID: 44,
                backendIdentity: .init(pid: 42, ownerUID: getuid(), startedAtSeconds: 1, startedAtMicroseconds: 0),
                providerIdentity: .init(pid: 44, ownerUID: getuid(), startedAtSeconds: 2, startedAtMicroseconds: 0))
            run = TwinRun(source: source, mode: mode)
            completion = .init(id: "completion", turnID: "turn", completedAt: Date(), inputRevision: 2)
            round = TwinRound(number: 1, sourceCompletion: completion)
            let path = root.appendingPathComponent("twins").appendingPathComponent(run.id).appendingPathComponent("round-1/worktree").path
            snapshot = TwinGitSnapshot(runID: run.id, round: 1, repositoryRoot: "/source", sourceCWD: source.cwd, sourceGitDirectory: "/source/.git", commonDirectory: "/source/.git",
                sourceBranch: "refs/heads/main", sourceHEAD: String(repeating: "a", count: 40), sourceIndexSHA256: String(repeating: "b", count: 64), sourceTree: String(repeating: "c", count: 40), snapshotCommit: String(repeating: "d", count: 40),
                twinBranch: "refs/heads/trano/twins/" + run.id + "/round-1", worktreePath: path,
                ownership: .init(path: path, commonDirectory: "/source/.git", adminDirectory: "/source/.git/worktrees/twin", pathIdentity: node, gitFileIdentity: node, adminIdentity: node, commonIdentity: node))
            seed = .init(relativePath: "sessions/2026/11/13/rollout-2026-11-13T01-00-00-" + source.conversationID + ".jsonl", data: Data(("{\"type\":\"session_meta\",\"payload\":{\"id\":\"" + source.conversationID + "\",\"cwd\":\"/source\",\"source\":\"cli\"}}\n").utf8))
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }
}

final class PessimisticTwinLaunchFileTests: XCTestCase {
    // Implements: FR-TWIN-2, FR-TWIN-3, FR-TWIN-4, FR-TWIN-8
    func testFullOwnedFileCopyPreservesTrailingRecordsAndRefusesTruncationOrLinks() throws {
        let f = try fixture()
        let bytes = Data(repeating: 0x61, count: 100_000) + Data("tail-record\n".utf8)
        try write(bytes, to: f.appendingPathComponent("conversation.jsonl"))
        XCTAssertEqual(try TwinLaunchPreparationFiles.readOwned(root: f.path, relativePath: "conversation.jsonl", limit: bytes.count), bytes)
        XCTAssertThrowsError(try TwinLaunchPreparationFiles.readOwned(root: f.path, relativePath: "conversation.jsonl", limit: bytes.count - 1))
        try FileManager.default.createSymbolicLink(atPath: f.appendingPathComponent("linked.jsonl").path, withDestinationPath: "conversation.jsonl")
        XCTAssertThrowsError(try TwinLaunchPreparationFiles.readOwned(root: f.path, relativePath: "linked.jsonl", limit: bytes.count))
        XCTAssertThrowsError(try TwinLaunchPreparationFiles.readOwned(root: f.path, relativePath: "../conversation.jsonl", limit: bytes.count))
    }

    func testWritableOrHardLinkedCredentialsCannotBeCopied() throws {
        let f = try fixture(), file = f.appendingPathComponent("auth.json")
        try write(Data("{}\n".utf8), to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try TwinLaunchPreparationFiles.readOwned(root: f.path, relativePath: "auth.json", limit: 1024))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try FileManager.default.linkItem(at: file, to: f.appendingPathComponent("second"))
        XCTAssertThrowsError(try TwinLaunchPreparationFiles.readOwned(root: f.path, relativePath: "auth.json", limit: 1024))
    }

    func testClaudeFileAndKeychainAreComparedAndOnlyMinimalOAuthIdentityIsCopied() throws {
        let f = try fixture(), original = source(root: f, provider: .claude)
        let auth = Data("{\"claudeAiOauth\":{\"accessToken\":\"fake-token\"}}\n".utf8)
        try write(auth, to: f.appendingPathComponent(".credentials.json"))
        try write(Data("{\"oauthAccount\":{\"accountUuid\":\"account\",\"organizationUuid\":\"org\",\"emailAddress\":\"a@example.test\",\"unrelatedField\":\"drop\"},\"hooks\":{\"danger\":true},\"arbitrarySetting\":true}\n".utf8), to: f.appendingPathComponent(".claude.json"))
        var compared = false
        let reader = TwinLaunchCredentialReader(keychain: { _ in compared = true; return auth }, environmentCheck: { _ in })
        let result = try reader.credentials(source: original)
        XCTAssertEqual(result[".credentials.json"], auth)
        XCTAssertTrue(compared)
        let identity = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(result[".claude.json"])) as? [String: Any])
        XCTAssertEqual(Set(identity.keys), ["oauthAccount"])
        let account = try XCTUnwrap(identity["oauthAccount"] as? [String: Any])
        XCTAssertEqual(Set(account.keys), ["accountUuid", "organizationUuid", "emailAddress"])
        XCTAssertEqual(account["organizationUuid"] as? String, "org")
    }

    func testMissingClaudeFileUsesOnlyInjectedExactSourceKeychainAndDoesNotWriteSource() throws {
        let f = try fixture(), original = source(root: f, provider: .claude)
        var roots: [String] = []
        let auth = Data("{\"claudeAiOauth\":{\"accessToken\":\"fake-token\"}}\n".utf8)
        let result = try TwinLaunchCredentialReader(keychain: { root in roots.append(root); return auth }, environmentCheck: { _ in }).credentials(source: original)
        XCTAssertEqual(roots, [original.configurationRoot])
        XCTAssertEqual(result[".credentials.json"], auth)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.path).isEmpty)
    }

    func testMalformedOrLinkedClaudeFileCannotFallBackToAnotherCredential() throws {
        let f = try fixture(), original = source(root: f, provider: .claude)
        try write(Data("not-json\n".utf8), to: f.appendingPathComponent(".credentials.json"))
        var called = false
        let reader = TwinLaunchCredentialReader(keychain: { _ in called = true; return Data("{}".utf8) }, environmentCheck: { _ in })
        XCTAssertThrowsError(try reader.credentials(source: original))
        XCTAssertFalse(called)
        try FileManager.default.removeItem(at: f.appendingPathComponent(".credentials.json"))
        try write(Data("{}\n".utf8), to: f.appendingPathComponent("other"))
        try FileManager.default.createSymbolicLink(atPath: f.appendingPathComponent(".credentials.json").path, withDestinationPath: "other")
        XCTAssertThrowsError(try reader.credentials(source: original)); XCTAssertFalse(called)
    }

    func testCodexNeverFallsBackToClaudeKeychainOrOtherAccount() throws {
        let f = try fixture(), original = source(root: f, provider: .codex)
        let reader = TwinLaunchCredentialReader(keychain: { _ in XCTFail("Codex cannot borrow another account"); return nil }, environmentCheck: { _ in })
        XCTAssertThrowsError(try reader.credentials(source: original))
        let auth = Data("{\"auth_mode\":\"chatgpt\",\"tokens\":{\"access_token\":\"fake\"}}\n".utf8)
        try write(auth, to: f.appendingPathComponent("auth.json"))
        XCTAssertEqual(try reader.credentials(source: original), ["auth.json": auth])
    }

    func testConversationValidationRejectsPartialForeignAndNoninteractiveRecords() throws {
        let f = try fixture(), original = source(root: f, provider: .codex)
        let name = "sessions/2026/11/13/rollout-2026-11-13T00-00-00-" + original.conversationID + ".jsonl"
        func seed(_ id: String, source: String = "cli", newline: Bool = true) -> TwinConversationSeed {
            .init(relativePath: name, data: Data(("{\"type\":\"session_meta\",\"payload\":{\"id\":\"" + id + "\",\"cwd\":\"/project\",\"source\":\"" + source + "\"}}" + (newline ? "\n" : "")).utf8))
        }
        XCTAssertNoThrow(try TwinLaunchPreparationFiles.validateConversation(seed(original.conversationID), source: original))
        XCTAssertThrowsError(try TwinLaunchPreparationFiles.validateConversation(seed(original.conversationID, newline: false), source: original))
        XCTAssertThrowsError(try TwinLaunchPreparationFiles.validateConversation(seed(UUID().uuidString), source: original))
        XCTAssertThrowsError(try TwinLaunchPreparationFiles.validateConversation(seed(original.conversationID, source: "exec"), source: original))
        let mixed = TwinConversationSeed(relativePath: name, data: seed(original.conversationID).data + seed(UUID().uuidString).data)
        XCTAssertThrowsError(try TwinLaunchPreparationFiles.validateConversation(mixed, source: original))
    }

    func testNativeHistoryLookupCopiesWholeExactFileAndSecurityDoesNoHistoryIO() throws {
        let f = try fixture(), original = source(root: f, provider: .codex)
        let relative = "sessions/2026/11/13/rollout-2026-11-13T00-00-00-" + original.conversationID + ".jsonl"
        let file = f.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var bytes = Data(("{\"type\":\"session_meta\",\"payload\":{\"id\":\"" + original.conversationID + "\",\"cwd\":\"/project\",\"source\":\"cli\"}}\n").utf8)
        for _ in 0..<300 { bytes.append(Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"long history payload remains intact\"}}\n".utf8)) }
        bytes.append(Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"final exact record\"}}\n".utf8))
        try write(bytes, to: file)
        let copy = try XCTUnwrap(TwinLaunchNativePreparation.conversation(source: original, mode: .generalReview))
        XCTAssertEqual(copy.data, bytes); XCTAssertEqual(copy.relativePath, relative)
        try FileManager.default.removeItem(at: file)
        XCTAssertNil(try TwinLaunchNativePreparation.conversation(source: original, mode: .securityReview))
        XCTAssertThrowsError(try TwinLaunchNativePreparation.conversation(source: original, mode: .codeReview))
    }

    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("twin-launch-files-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func write(_ data: Data, to file: URL) throws {
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func source(root: URL, provider: AgentKind) -> TwinSourceBinding {
        .init(paneID: UUID().uuidString, generation: UUID().uuidString, conversationID: UUID().uuidString.lowercased(), cwd: "/project",
              configurationRoot: root.path, provider: provider, backendPID: 42, providerPID: 43,
              backendIdentity: .init(pid: 42, ownerUID: getuid(), startedAtSeconds: 1, startedAtMicroseconds: 0),
              providerIdentity: .init(pid: 43, ownerUID: getuid(), startedAtSeconds: 2, startedAtMicroseconds: 0))
    }
}
