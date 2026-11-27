import Foundation
import XCTest
@testable import TerminalCore

final class ShellHistoryTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let home: URL
        let pane = UUID().uuidString.lowercased()
        init() throws {
            root = URL(fileURLWithPath: "/tmp/th-" + String(UUID().uuidString.prefix(8)))
            home = root.appendingPathComponent("home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        var store: ShellHistoryStore { ShellHistoryStore(runtimeRoot: root, home: home, environment: [:]) }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    // Implements: FR-CLOSE-1, FR-CLOSE-3, FR-CLOSE-7
    func testLegacyZshHistoryRemainsDataAndReportsPersistedProvenance() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let payload = Data(": 1700000000:0;printf '한글'\n: 1700000001:0;touch should-not-exist\n".utf8)
        let source = fixture.home.appendingPathComponent(".zsh_history")
        try payload.write(to: source)
        let command = TerminalStartupCommand(executable: "/bin/zsh", arguments: ["-l"])
        let archive = try fixture.store.capture(paneID: fixture.pane, command: command)
        XCTAssertEqual(archive.format, .zsh)
        XCTAssertEqual(archive.provenance, .persistedFallback)
        XCTAssertEqual(archive.content, payload)
        try fixture.store.restore(archive, paneID: fixture.pane)
        XCTAssertEqual(try Data(contentsOf: source), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("should-not-exist").path))
        XCTAssertEqual(try JSONDecoder().decode(ShellHistoryArchive.self, from: JSONEncoder().encode(archive)), archive)
    }

    // Implements: FR-CLOSE-1, FR-CLOSE-7
    func testMissingLegacyHistoryIsExplicitlyUnavailable() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        for executable in ["/bin/zsh", "/bin/bash", "/bin/fish", "/usr/bin/custom"] {
            let archive = try fixture.store.capture(paneID: fixture.pane,
                                                    command: TerminalStartupCommand(executable: executable))
            XCTAssertEqual(archive.provenance, .unavailable)
            XCTAssertTrue(archive.content.isEmpty)
        }
    }

    // Implements: FR-CLOSE-1, FR-CLOSE-7
    func testCurrentJournalWinsButNewPreparationDoesNotReuseOldShellJournal() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let command = TerminalStartupCommand(executable: "/bin/zsh", arguments: ["-l"])
        try Data("persisted\n".utf8).write(to: fixture.home.appendingPathComponent(".zsh_history"))
        let first = try fixture.store.prepareJournal(paneID: fixture.pane, command: command, restoring: false)
        try Data("current pane command\n".utf8).write(to: first.journal)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: first.journal.path)
        let archive = try fixture.store.capture(paneID: fixture.pane, command: command)
        XCTAssertEqual(archive.provenance, .journal)
        XCTAssertEqual(String(decoding: archive.content, as: UTF8.self), "current pane command\n")
        let second = try fixture.store.prepareJournal(paneID: fixture.pane, command: command, restoring: false)
        XCTAssertNotEqual(first.journal, second.journal)
        XCTAssertEqual(try fixture.store.capture(paneID: fixture.pane, command: command).provenance, .persistedFallback)
    }

    // Implements: FR-CLOSE-1, FR-CLOSE-7
    func testBoundedCaptureKeepsCompleteMultilineUnicodeEntries() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let latest = ": 1700000001:0;printf '한글\\\n두 줄'\n"
        let payload = ": 1700000000:0;" + String(repeating: "x", count: ShellHistoryStore.maximumBytes + 100) + "\n" + latest
        try Data(payload.utf8).write(to: fixture.home.appendingPathComponent(".zsh_history"))
        let archive = try fixture.store.capture(paneID: fixture.pane,
                                                command: TerminalStartupCommand(executable: "/bin/zsh"))
        XCTAssertEqual(String(decoding: archive.content, as: UTF8.self), latest)
        XCTAssertLessThanOrEqual(archive.content.count, ShellHistoryStore.maximumBytes)
    }

    // Implements: FR-CLOSE-1, FR-CLOSE-7
    func testRejectsTraversalSymlinksAndMalformedRestorePayload() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let command = TerminalStartupCommand(executable: "/bin/bash")
        XCTAssertThrowsError(try fixture.store.capture(paneID: "../outside", command: command))
        let source = fixture.home.appendingPathComponent(".bash_history")
        let outside = fixture.root.appendingPathComponent("outside")
        try Data("untouched\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
        XCTAssertThrowsError(try fixture.store.capture(paneID: fixture.pane, command: command))
        XCTAssertThrowsError(try fixture.store.restore(ShellHistoryArchive(format: .bash,
            content: Data([0xff, 0]), provenance: .journal), paneID: fixture.pane))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "untouched\n")
    }

    // Implements: FR-CLOSE-3, FR-CLOSE-7
    func testRestoreUsesPrivateFilesAndPreservesShellAndArguments() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let archive = ShellHistoryArchive(format: .bash, content: Data("printf 'history'\n".utf8), provenance: .journal)
        try fixture.store.restore(archive, paneID: fixture.pane)
        let command = TerminalStartupCommand(executable: "/opt/custom/bash", arguments: ["-l"])
        let files = try fixture.store.prepareJournal(paneID: fixture.pane, command: command, restoring: true)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.restore)), archive.content)
        let directory = files.journal.deletingLastPathComponent()
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let restoredAttributes = try FileManager.default.attributesOfItem(atPath: XCTUnwrap(files.restore).path)
        XCTAssertEqual((restoredAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try TerminalLaunchSelection.resolve(preferences: TerminalPreferences(),
            shell: command.executable, arguments: command.arguments, restoringID: fixture.pane), command)
    }

    // Implements: FR-CLOSE-3
    func testGeneratedHooksImportOnlyHistoryAndPreserveExistingUserHooks() throws {
        let zsh = ShellHistoryIntegration.zsh
        XCTAssertTrue(zsh.contains("add-zsh-hook preexec"))
        XCTAssertTrue(zsh.contains("add-zsh-hook precmd"))
        XCTAssertTrue(zsh.contains("builtin fc -RI"))
        XCTAssertFalse(zsh.contains("HISTFILE="))
        let bash = ShellHistoryIntegration.bash
        XCTAssertTrue(bash.contains("builtin history -r"))
        XCTAssertTrue(bash.contains("trap -p DEBUG"))
        XCTAssertTrue(bash.contains("PROMPT_COMMAND"))
        let fish = ShellHistoryIntegration.fish
        let privateGuard = try XCTUnwrap(fish.range(of: "if set -q fish_private_mode"))
        let ownerGuard = try XCTUnwrap(fish.range(of: "if set -q TRANO_HISTORY_OWNER_PID"))
        let importPosition = try XCTUnwrap(fish.range(of: "builtin history append"))
        XCTAssertLessThan(privateGuard.lowerBound, ownerGuard.lowerBound)
        XCTAssertLessThan(privateGuard.lowerBound, importPosition.lowerBound)
        XCTAssertTrue(fish[..<privateGuard.lowerBound].contains("status is-interactive"))
        for script in [zsh, bash] {
            XCTAssertFalse(script.contains("eval "))
            XCTAssertFalse(script.contains("source \"$TRANO_HISTORY"))
            XCTAssertFalse(script.contains("send-keys"))
        }
    }

    // Implements: FR-CLOSE-1, FR-CLOSE-7
    func testPendingLiveSnapshotRefusesCloseAndDeadOwnerRetainsCompletedHistory() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let command = TerminalStartupCommand(executable: "/bin/zsh", arguments: ["-l"])
        let files = try fixture.store.prepareJournal(paneID: fixture.pane, command: command, restoring: false)
        try TerminalRuntime.atomicWrite(Data("completed\n".utf8), to: files.journal)
        try TerminalRuntime.atomicWrite(Data("preexec\n".utf8), to: files.capability)
        let pending = files.journal.appendingPathExtension("pending")
        try TerminalRuntime.atomicWrite(Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8), to: pending)
        XCTAssertThrowsError(try fixture.store.capture(paneID: fixture.pane, command: command))
        try TerminalRuntime.atomicWrite(Data("\(Int32.max)\n".utf8), to: pending)
        let archive = try fixture.store.capture(paneID: fixture.pane, command: command)
        XCTAssertEqual(archive.content, Data("completed\n".utf8))
        XCTAssertEqual(archive.provenance, .journal)
        XCTAssertFalse(archive.capturesRunningCommand)
    }

    // Implements: FR-CLOSE-1, FR-CLOSE-3
    func testBashTimestampedMultilineHistoryAndFishEscapesRemainData() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let bash = Data("#1700000000\nprintf 'first\nsecond'\n#1700000001\nprintf final\n".utf8)
        try bash.write(to: fixture.home.appendingPathComponent(".bash_history"))
        XCTAssertEqual(try fixture.store.capture(paneID: fixture.pane,
            command: TerminalStartupCommand(executable: "/bin/bash")).content, bash)
        let fishDirectory = fixture.home.appendingPathComponent(".local/share/fish")
        try FileManager.default.createDirectory(at: fishDirectory, withIntermediateDirectories: true)
        try Data("- cmd: printf '한글\\nsecond'\n  when: 1700000000\n- cmd: touch never-run\n  when: 1700000001\n".utf8)
            .write(to: fishDirectory.appendingPathComponent("fish_history"))
        let fish = try fixture.store.capture(paneID: fixture.pane,
            command: TerminalStartupCommand(executable: "/bin/fish"))
        XCTAssertEqual(fish.format, .fish)
        XCTAssertEqual(fish.content, Data("printf '한글\nsecond'\0touch never-run\0".utf8))
        try fixture.store.restore(fish, paneID: fixture.pane)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("never-run").path))
    }

    // Implements: FR-CLOSE-1, FR-CLOSE-7
    func testHelperlessPreparationSeedsEmptyOwnedHistoryWithoutHomeFallback() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let runtimeRoot = fixture.root.appendingPathComponent("runtime")
        let runtime = try TerminalRuntime(root: runtimeRoot)
        let command = TerminalStartupCommand(executable: "/bin/zsh", arguments: ["-l"])
        try Data("must not be imported\n".utf8).write(to: fixture.home.appendingPathComponent(".zsh_history"))
        let prepared = try runtime.prepareTerminalShell(command, paneID: fixture.pane, restoring: false)
        XCTAssertEqual(prepared.command, command)
        let archive = try ShellHistoryStore(runtimeRoot: runtimeRoot, home: fixture.home, environment: [:])
            .capture(paneID: fixture.pane, command: command)
        XCTAssertEqual(archive.provenance, .journal)
        XCTAssertTrue(archive.content.isEmpty)
        XCTAssertFalse(archive.capturesRunningCommand)
    }
}
