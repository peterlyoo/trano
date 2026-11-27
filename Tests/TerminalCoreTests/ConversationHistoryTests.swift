import Foundation
import Darwin
import XCTest
@testable import TerminalCore

final class ConversationHistoryTests: XCTestCase {
    // Implements: FR-RESUME-1
    func testOversizedUnrelatedToolRecordDoesNotHideVerifiedMetadata() throws {
        let f = try Fixture(); defer { f.remove() }
        let id = UUID().uuidString.lowercased()
        try f.claude(id, extra: [["type":"assistant", "sessionId":id, "cwd":"/tmp/한글 project", "message":["role":"assistant", "content":String(repeating:"x", count:70_000)]]])
        let result = ConversationHistoryIndex.discover(sources: [f.source(.claude)])
        XCTAssertEqual(result.conversations.first?.providerSessionID, id)
        XCTAssertEqual(result.conversations.first?.title, "First Claude user text")
        XCTAssertTrue(result.truncated)
    }

    // Implements: FR-RESUME-1
    func testClaudeMetadataPrecedenceAndExactSourceBinding() throws {
        let f = try Fixture(); defer { f.remove() }
        let id = UUID().uuidString.lowercased()
        try f.claude(id, extra: [["type":"summary", "summary":"Summary"], ["type":"custom-title", "customTitle":"한글 custom title", "sessionId":id]])
        let result = ConversationHistoryIndex.discover(sources: [f.source(.claude)])
        let entry = try XCTUnwrap(result.conversations.first)
        XCTAssertEqual(entry.title, "한글 custom title")
        XCTAssertEqual(entry.cwd, "/tmp/한글 project")
        XCTAssertEqual(entry.source, f.source(.claude))
        XCTAssertEqual(entry.relativePath, "projects/project/\(id).jsonl")
        XCTAssertEqual(try ConversationHistoryIndex.validate(conversation: entry).providerSessionID, id)
    }

    // Implements: FR-RESUME-1
    func testCodexHeaderTitlesIndexHintsAndNoninteractiveExclusion() throws {
        let f = try Fixture(); defer { f.remove() }
        let good = UUID().uuidString.lowercased(), ide = UUID().uuidString.lowercased()
        try f.codex(good)
        try f.codex(ide, source: "vscode")
        try f.codex(UUID().uuidString.lowercased(), source: ["subagent":["thread_spawn":[:]]])
        try f.codex(UUID().uuidString.lowercased(), source: "exec")
        try f.write("session_index.jsonl", [["id":good, "thread_name":"Custom Codex title"], ["id":UUID().uuidString, "thread_name":"Index only"]])
        let result = ConversationHistoryIndex.discover(sources: [f.source(.codex)])
        XCTAssertEqual(Set(result.conversations.map(\.providerSessionID)), [good, ide])
        XCTAssertEqual(result.conversations.first { $0.providerSessionID == good }?.title, "Custom Codex title")
        XCTAssertEqual(result.conversations.first { $0.providerSessionID == ide }?.title, "First Codex user message")
    }

    // Implements: FR-RESUME-1
    func testWrongHeaderSDKSubagentsAndMalformedRecordsNeverBecomeResumable() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.claude(UUID().uuidString.lowercased(), fields: ["entrypoint":"sdk-cli"])
        try f.claude(UUID().uuidString.lowercased(), fields: ["isSidechain":true])
        let wrong = UUID().uuidString.lowercased()
        try f.claude(wrong, fields: ["sessionId":UUID().uuidString.lowercased()])
        try f.write("projects/project/\(UUID().uuidString.lowercased()).jsonl", [["type":"summary", "summary":"Unknown identity"]])
        try f.codex(UUID().uuidString.lowercased(), fields: ["id":UUID().uuidString.lowercased()])
        XCTAssertTrue(ConversationHistoryIndex.discover(sources: [f.source(.claude), f.source(.codex)]).conversations.isEmpty)
    }

    // Implements: FR-RESUME-1
    func testNoFollowSymlinksFIFOsHardlinksAndTraversal() throws {
        let f = try Fixture(); defer { f.remove() }
        let id = UUID().uuidString.lowercased()
        try f.claude(id)
        let source = f.source(.claude)
        let original = try XCTUnwrap(ConversationHistoryIndex.discover(sources: [source]).conversations.first)
        let path = f.root.appendingPathComponent("projects/project/\(id).jsonl")
        let copy = f.root.appendingPathComponent("held.jsonl")
        try FileManager.default.moveItem(at: path, to: copy)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: copy)
        XCTAssertTrue(ConversationHistoryIndex.discover(sources: [source]).conversations.isEmpty)
        XCTAssertThrowsError(try ConversationHistoryIndex.validate(conversation: original))
        try FileManager.default.removeItem(at: path)
        XCTAssertEqual(link(copy.path, path.path), 0)
        XCTAssertTrue(ConversationHistoryIndex.discover(sources: [source]).conversations.isEmpty)
        XCTAssertThrowsError(try ConversationHistoryIndex.validate(conversation: original))
        try FileManager.default.removeItem(at: path)
        XCTAssertEqual(mkfifo(path.path, 0o600), 0)
        XCTAssertTrue(ConversationHistoryIndex.discover(sources: [source]).conversations.isEmpty)
        XCTAssertThrowsError(try ConversationHistoryIndex.validate(conversation: original))
        let forged = AgentConversation(source: source, providerSessionID: id, title: "", cwd: "/tmp/한글 project", updatedAt: Date(), relativePath: "projects/project/../../held.jsonl")
        XCTAssertThrowsError(try ConversationHistoryIndex.validate(conversation: forged))
    }

    // Implements: FR-RESUME-1, FR-RESUME-4
    func testFreshValidationRejectsChangedCWDButLeavesDisabledAccountPolicyToCaller() throws {
        let f = try Fixture(); defer { f.remove() }
        let id = UUID().uuidString.lowercased()
        try f.claude(id)
        let entry = try XCTUnwrap(ConversationHistoryIndex.discover(sources: [f.source(.claude)]).conversations.first)
        try f.claude(id, cwd: "/tmp/other")
        XCTAssertThrowsError(try ConversationHistoryIndex.validate(conversation: entry))
        let disabled = ConversationHistorySource(id: entry.source.id, provider: .claude, configurationRoot: entry.source.configurationRoot, accountID: entry.source.accountID, label: "Disabled", enabled: false)
        let row = try XCTUnwrap(ConversationHistoryIndex.discover(sources: [disabled]).conversations.first)
        XCTAssertFalse(row.source.enabled)
        XCTAssertEqual(try ConversationHistoryIndex.validate(conversation: row).source, disabled)
    }

    // Implements: FR-RESUME-1
    func testDuplicateSourcesDeduplicateAndConflictingConversationCWDIsRejected() throws {
        let f = try Fixture(); defer { f.remove() }
        let id = UUID().uuidString.lowercased()
        try f.claude(id)
        let source = f.source(.claude)
        XCTAssertEqual(ConversationHistoryIndex.discover(sources: [source, source]).conversations.count, 1)
        try f.write("projects/second/\(id).jsonl", [["type":"user", "sessionId":id, "cwd":"/tmp/conflict", "message":["role":"user", "content":"Conflicting copy"]]])
        let result = ConversationHistoryIndex.discover(sources: [source])
        XCTAssertTrue(result.conversations.isEmpty)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    // Implements: FR-RESUME-1
    func testBoundedNewestFirstReadsAndCrossAccountIdentity() throws {
        let a = try Fixture(), b = try Fixture(); defer { a.remove(); b.remove() }
        let id = UUID().uuidString.lowercased()
        try a.claude(id); try b.claude(id)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970: 1)], ofItemAtPath: a.root.appendingPathComponent("projects/project/\(id).jsonl").path)
        let all = ConversationHistoryIndex.discover(sources: [a.source(.claude), b.source(.claude)])
        XCTAssertEqual(all.conversations.count, 2)
        XCTAssertEqual(Set(all.conversations.map(\.id)).count, 2)
        let bounded = ConversationHistoryIndex.discover(sources: [a.source(.claude), b.source(.claude)], limits: .init(maxFiles: 1))
        XCTAssertEqual(bounded.conversations.count, 1)
        XCTAssertEqual(bounded.conversations.first?.source.id, b.source(.claude).id)
        XCTAssertTrue(bounded.truncated)
    }

    // Implements: FR-RESUME-1
    func testHeadTailLimitsCancellationAndClampedBudgets() throws {
        let f = try Fixture(); defer { f.remove() }
        let id = UUID().uuidString.lowercased()
        try f.claude(id, extra: [["type":"assistant", "sessionId":id, "cwd":"/tmp/한글 project", "message":["role":"assistant", "content":String(repeating:"x",count:1_000_000)]], ["type":"custom-title", "sessionId":id, "customTitle":"Tail title"]])
        let result = ConversationHistoryIndex.discover(sources: [f.source(.claude)], limits: .init(maxTotalBytes: 2048, headBytes: 512, tailBytes: 512, maxLineBytes: 512))
        XCTAssertEqual(result.conversations.first?.title, "Tail title")
        XCTAssertTrue(result.truncated)
        XCTAssertTrue(ConversationHistoryIndex.discover(sources: [f.source(.claude)], cancelled: { true }).truncated)
        let zero = ConversationHistoryIndex.discover(sources: [f.source(.claude)], limits: .init(maxVisitedEntries: 0))
        XCTAssertTrue(zero.conversations.isEmpty)
        XCTAssertTrue(zero.truncated)
        let caps = ConversationHistoryLimits(maxSources: .max, maxVisitedEntries: .max, maxFiles: .max, maxTotalBytes: .max)
        XCTAssertLessThanOrEqual(caps.maxSources, 64)
        XCTAssertLessThanOrEqual(caps.maxVisitedEntries, 50_000)
        XCTAssertLessThanOrEqual(caps.maxFiles, 1024)
        XCTAssertLessThanOrEqual(caps.maxTotalBytes, 67_108_864)
    }

    private final class Fixture {
        let root: URL
        let sourceID = UUID().uuidString.lowercased()
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("history-fixture-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func source(_ provider: AgentKind) -> ConversationHistorySource {
            ConversationHistorySource(id: sourceID + provider.rawValue, provider: provider, configurationRoot: root.path, accountID: sourceID, label: "Synthetic", enabled: true)
        }
        func write(_ path: String, _ rows: [[String:Any]]) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = Data()
            for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
            try data.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions:0o644], ofItemAtPath: url.path)
        }
        func claude(_ id: String, cwd: String = "/tmp/한글 project", fields: [String:Any] = [:], extra: [[String:Any]] = []) throws {
            var row: [String:Any] = ["type":"user", "sessionId":id, "cwd":cwd, "message":["role":"user", "content":"First Claude user text"], "entrypoint":"cli"]
            for (key,value) in fields { row[key] = value }
            try write("projects/project/\(id).jsonl", [row] + extra)
        }
        func codex(_ id: String, source: Any = "cli", fields: [String:Any] = [:]) throws {
            var payload: [String:Any] = ["id":id, "cwd":"/tmp/한글 project", "source":source]
            for (key,value) in fields { payload[key] = value }
            try write("sessions/2026/11/12/rollout-2026-11-12T10-00-00-\(id).jsonl", [["type":"session_meta", "payload":payload], ["type":"event_msg", "payload":["type":"user_message", "message":"First Codex user message"]]])
        }
    }
}
