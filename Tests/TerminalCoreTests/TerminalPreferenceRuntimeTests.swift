import Foundation
import Darwin
import XCTest
@testable import TerminalCore

final class TerminalPreferenceRuntimeTests: XCTestCase {
    private final class Fixture {
        let root = URL(fileURLWithPath: "/tmp/trp-" + UUID().uuidString.prefix(12))
        let runtime: TerminalRuntime
        let backend = FakePaneBackend()
        init() throws {
            runtime = try TerminalRuntime(root: root)
            runtime.host = backend
        }
        deinit {
            XCTAssertFalse(backend.calls.contains { $0.hasPrefix("create") || $0.hasPrefix("respawn") })
            try? FileManager.default.removeItem(at: root)
        }
    }

    // Implements: FR-SET-71, FR-SET-95, FR-SET-97
    func testPreferenceDraftsMergeAndSurviveAnOldPrimaryWriter() throws {
        let fixture = try Fixture()
        let runtime = fixture.runtime
        let baseline = try runtime.terminalPreferences()
        var fontDraft = baseline; fontDraft.fontName = "Menlo-Regular"
        var independentDraft = baseline; independentDraft.showRecentPaths = false
        _ = try runtime.saveTerminalPreferences(fontDraft, from: baseline)
        _ = try runtime.saveTerminalPreferences(independentDraft, from: baseline)
        try TerminalRuntime.atomicWrite(JSONEncoder().encode(RuntimeState()),
                                        to: fixture.root.appendingPathComponent("state.json"))
        let saved = try runtime.terminalPreferences()
        XCTAssertEqual(saved.fontName, "Menlo-Regular")
        XCTAssertFalse(saved.showRecentPaths)
        let path = fixture.root.appendingPathComponent("terminal-preferences.json").path
        guard FileManager.default.fileExists(atPath: path) else { return XCTFail("Preferences sidecar must be persisted") }
        let metadata = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((metadata[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // Implements: FR-SET-95
    func testHistoryIsPrivatePerHostBoundedAndPreservesExactUtf8() throws {
        let fixture = try Fixture()
        let runtime = fixture.runtime
        for index in 0..<25 {
            try runtime.recordTerminalPath("/tmp/local-\(index)", at: Date(timeIntervalSince1970: Double(index)))
            try runtime.recordTerminalPath("/remote/\(index)", hostID: "host-a",
                                           at: Date(timeIntervalSince1970: Double(index)))
        }
        XCTAssertEqual(try runtime.recentTerminalPaths().count, 20)
        XCTAssertEqual(try runtime.recentTerminalPaths(hostID: "host-a").count, 20)
        let exact = ["/tmp/한글 space 'quote';", "/tmp/e\u{301}", "/tmp/é"]
        for (index, path) in exact.enumerated() {
            try runtime.recordTerminalPath(path, hostID: "host-b",
                                           at: Date(timeIntervalSince1970: Double(100 + index)))
        }
        XCTAssertEqual(try runtime.recentTerminalPaths(hostID: "host-b").map { Array($0.path.utf8) },
                       exact.reversed().map { Array($0.utf8) })
        let url = TerminalPathHistoryStore(root: fixture.root).url
        guard FileManager.default.fileExists(atPath: url.path) else { return XCTFail("History sidecar must be persisted") }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try runtime.clearTerminalPaths(hostID: "host-a")
        XCTAssertTrue(try runtime.recentTerminalPaths(hostID: "host-a").isEmpty)
        XCTAssertEqual(try runtime.recentTerminalPaths().count, 20)
        try runtime.clearAllTerminalPaths()
        XCTAssertTrue(try runtime.recentTerminalPaths().isEmpty)
        XCTAssertTrue(try runtime.recentTerminalPaths(hostID: "host-b").isEmpty)
    }

    // Implements: FR-SET-95
    func testDisabledHistoryHidesExistingAndPreventsNewRetentionUntilEnabled() throws {
        let fixture = try Fixture()
        let runtime = fixture.runtime
        try runtime.recordTerminalPath("/tmp/retained")
        let baseline = try runtime.terminalPreferences()
        var disabled = baseline; disabled.showRecentPaths = false
        _ = try runtime.saveTerminalPreferences(disabled, from: baseline)
        try runtime.recordTerminalPath("/tmp/must-not-retain")
        XCTAssertTrue(try runtime.recentTerminalPaths().isEmpty)
        XCTAssertEqual(try TerminalPathHistoryStore(root: fixture.root).load().recent().map(\.path),
                       ["/tmp/retained"])
        _ = try runtime.saveTerminalPreferences(baseline, from: disabled)
        XCTAssertEqual(try runtime.recentTerminalPaths().map(\.path), ["/tmp/retained"])
        _ = try runtime.saveTerminalPreferences(disabled, from: baseline)
        try runtime.clearAllTerminalPaths()
        XCTAssertTrue(try TerminalPathHistoryStore(root: fixture.root).load().entries.isEmpty)
    }

    // Implements: FR-SET-95
    func testHistoryStoreRejectsSymlinkHardlinkPublicFileAndFifo() throws {
        let fixture = try Fixture()
        let store = TerminalPathHistoryStore(root: fixture.root)
        let victim = fixture.root.appendingPathComponent("victim")
        let bytes = Data("private sentinel".utf8)
        try bytes.write(to: victim)
        XCTAssertEqual(symlink(victim.path, store.url.path), 0)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(TerminalPathHistory()))
        XCTAssertEqual(try Data(contentsOf: victim), bytes)
        try FileManager.default.removeItem(at: store.url)
        XCTAssertEqual(link(victim.path, store.url.path), 0)
        XCTAssertThrowsError(try store.load())
        try FileManager.default.removeItem(at: store.url)
        try Data("{}".utf8).write(to: store.url)
        XCTAssertEqual(chmod(store.url.path, 0o644), 0)
        XCTAssertThrowsError(try store.load())
        try FileManager.default.removeItem(at: store.url)
        XCTAssertEqual(mkfifo(store.url.path, 0o600), 0)
        XCTAssertThrowsError(try store.load())
    }

    // Implements: FR-SET-95
    func testHistoryStoreRejectsOversizeAndUnsupportedSchema() throws {
        let fixture = try Fixture()
        let store = TerminalPathHistoryStore(root: fixture.root)
        try Data(repeating: 0x20, count: 1_048_577).write(to: store.url)
        XCTAssertEqual(chmod(store.url.path, 0o600), 0)
        XCTAssertThrowsError(try store.load())
        try Data("{\"schemaVersion\":2,\"history\":{\"entries\":[]}}".utf8).write(to: store.url)
        XCTAssertEqual(chmod(store.url.path, 0o600), 0)
        XCTAssertThrowsError(try store.load())
    }

    // Implements: FR-SET-95
    func testConcurrentRecordsUseTheSharedTransactionWithoutLostPaths() throws {
        final class Failures: @unchecked Sendable {
            let lock = NSLock()
            private var messages: [String] = []
            func append(_ message: String) { lock.lock(); defer { lock.unlock() }; messages.append(message) }
            func values() -> [String] { lock.lock(); defer { lock.unlock() }; return messages }
        }
        let fixture = try Fixture()
        let failures = Failures()
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            do { try fixture.runtime.recordTerminalPath("/tmp/concurrent-\(index)") }
            catch { failures.append(String(describing: error)) }
        }
        XCTAssertTrue(failures.values().isEmpty)
        XCTAssertEqual(Set(try fixture.runtime.recentTerminalPaths().map(\.path)),
                       Set((0..<12).map { "/tmp/concurrent-\($0)" }))
    }

    // Implements: FR-SET-95
    func testDecodedHistoryEntriesAreValidatedBeforeUse() throws {
        let fixture = try Fixture()
        let store = TerminalPathHistoryStore(root: fixture.root)
        let bytes = Data("{\"schemaVersion\":1,\"history\":{\"entries\":[{\"path\":\"relative\",\"usedAt\":0}]}}".utf8)
        try bytes.write(to: store.url)
        XCTAssertEqual(chmod(store.url.path, 0o600), 0)
        XCTAssertThrowsError(try store.load())
    }
}
