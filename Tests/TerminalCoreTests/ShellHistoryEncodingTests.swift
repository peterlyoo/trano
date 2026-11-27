import Foundation
import XCTest
@testable import TerminalCore

// Implements: FR-CLOSE-1, FR-CLOSE-3, FR-CLOSE-7
final class ShellHistoryEncodingTests: XCTestCase {
    func testNativeZshAndBashPersistedBytesSurviveArchiveAndRestore() throws {
        for format in [ShellHistoryFormat.zsh, .bash] {
            let f = try Fixture(); defer { f.cleanup() }
            let payload = nativeHistory(format)
            XCTAssertNil(String(data: payload, encoding: .utf8))
            let source = f.home.appendingPathComponent(".\(format.rawValue)_history")
            try TerminalRuntime.atomicWrite(payload, to: source)
            let command = TerminalStartupCommand(executable: "/bin/" + format.rawValue, arguments: ["-l"])
            let archive = try f.store.capture(paneID: f.pane, command: command)
            XCTAssertEqual(archive.content, payload)
            XCTAssertEqual(archive.provenance, .persistedFallback)
            let decoded = try JSONDecoder().decode(ShellHistoryArchive.self, from: JSONEncoder().encode(archive))
            XCTAssertEqual(decoded, archive)
            try f.store.restore(decoded, paneID: f.pane)
            let files = try f.store.prepareJournal(paneID: f.pane, command: command, restoring: true)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.restore)), payload)
            XCTAssertEqual(try Data(contentsOf: source), payload)
        }
    }

    func testNativeZshJournalBytesRemainByteExactThroughRestorePreparation() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let command = TerminalStartupCommand(executable: "/bin/zsh", arguments: ["-l"])
        let files = try f.store.prepareJournal(paneID: f.pane, command: command, restoring: false)
        let payload = nativeHistory(.zsh)
        try TerminalRuntime.atomicWrite(payload, to: files.journal)
        let archive = try f.store.capture(paneID: f.pane, command: command)
        XCTAssertEqual(archive.provenance, .journal)
        XCTAssertEqual(archive.content, payload)
        try f.store.restore(archive, paneID: f.pane)
        let restored = try f.store.prepareJournal(paneID: f.pane, command: command, restoring: true)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restored.restore)), payload)
    }

    func testCloseAndReopenKeepNativeHistoryBytesWithoutExecutingThem() throws {
        let f = try ClosedMuxFixture(); defer { f.cleanup() }
        let pane = try f.addPane()
        let command = TerminalStartupCommand(executable: "/bin/zsh", arguments: ["-l"])
        let history = ShellHistoryStore(runtimeRoot: f.root, home: f.root, environment: [:])
        let journal = try history.prepareJournal(paneID: pane.id, command: command, restoring: false)
        let payload = nativeHistory(.zsh)
        try TerminalRuntime.atomicWrite(payload, to: journal.journal)
        try f.runtime.performAction(.closePane)
        let snapshot = try XCTUnwrap(f.runtime.closedTerminalPaneSnapshot(pane.id))
        XCTAssertEqual(try f.runtime.closedTerminalStore.contents(id: snapshot.archiveID).history.content, payload)
        XCTAssertFalse(try XCTUnwrap(f.runtime.list().first).alive)
        try f.runtime.performAction(.restoreTab)
        XCTAssertTrue(try XCTUnwrap(f.runtime.list().first).alive)
        let restored = try FileManager.default.contentsOfDirectory(at: f.root.appendingPathComponent("shell-history"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "restore" }
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restored.first)), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("never-execute").path))
    }

    func testClippingDropsPartialRecordAndRetainsCompleteNativeBytes() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let latest = nativeHistory(.zsh)
        var payload = Data(repeating: 0x78, count: ShellHistoryStore.maximumBytes + 100)
        payload.append(0x0a); payload.append(latest)
        try TerminalRuntime.atomicWrite(payload, to: f.home.appendingPathComponent(".zsh_history"))
        let archive = try f.store.capture(paneID: f.pane, command: TerminalStartupCommand(executable: "/bin/zsh"))
        XCTAssertEqual(archive.content, latest)
        XCTAssertLessThanOrEqual(archive.content.count, ShellHistoryStore.maximumBytes)
    }

    func testNativeByteRecordsStillRespectEntryLimit() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let record = Data([0x83, 0xa3, 0x0a])
        var payload = Data()
        for _ in 0..<(ShellHistoryStore.maximumEntries + 5) { payload.append(record) }
        try TerminalRuntime.atomicWrite(payload, to: f.home.appendingPathComponent(".zsh_history"))
        let archive = try f.store.capture(paneID: f.pane, command: TerminalStartupCommand(executable: "/bin/zsh"))
        XCTAssertEqual(archive.content.count, record.count * ShellHistoryStore.maximumEntries)
        XCTAssertEqual(archive.content.filter { $0 == 0x0a }.count, ShellHistoryStore.maximumEntries)
        try f.store.restore(archive, paneID: f.pane)
    }

    func testNativeFormatsStillRejectNULAndOversizeArchives() throws {
        let f = try Fixture(); defer { f.cleanup() }
        for format in [ShellHistoryFormat.zsh, .bash] {
            XCTAssertThrowsError(try f.store.restore(ShellHistoryArchive(format: format, content: Data([0x83, 0xa3, 0]), provenance: .journal), paneID: f.pane))
            XCTAssertThrowsError(try f.store.restore(ShellHistoryArchive(format: format, content: Data(repeating: 0x78, count: ShellHistoryStore.maximumBytes + 1), provenance: .journal), paneID: f.pane))
        }
        XCTAssertThrowsError(try f.store.restore(ShellHistoryArchive(format: .none, content: Data([0x83, 0xa3]), provenance: .unavailable), paneID: f.pane))
    }

    func testFishRetainsUTF8AndNULTerminatorValidation() throws {
        let f = try Fixture(); defer { f.cleanup() }
        XCTAssertThrowsError(try f.store.restore(ShellHistoryArchive(format: .fish, content: Data([0xff, 0]), provenance: .journal), paneID: f.pane))
        XCTAssertThrowsError(try f.store.restore(ShellHistoryArchive(format: .fish, content: Data("unterminated".utf8), provenance: .journal), paneID: f.pane))
        let valid = ShellHistoryArchive(format: .fish, content: Data("한글\0".utf8), provenance: .journal)
        XCTAssertNoThrow(try f.store.restore(valid, paneID: f.pane))
    }

    private func nativeHistory(_ format: ShellHistoryFormat) -> Data {
        var value = Data((format == .zsh ? ": 1700000000:0;printf '" : "printf '").utf8)
        value.append(contentsOf: format == .zsh ? [0x83, 0xa3] : [0xe9])
        value.append(contentsOf: Data("'\n".utf8))
        return value
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let pane = UUID().uuidString.lowercased()
        init() throws {
            root = URL(fileURLWithPath: "/tmp/trano-history-encoding-" + UUID().uuidString.prefix(8))
            home = root.appendingPathComponent("home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var store: ShellHistoryStore { ShellHistoryStore(runtimeRoot: root, home: home, environment: [:]) }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
