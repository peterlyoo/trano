import XCTest
import Darwin
@testable import TerminalCore

final class TerminalInputLedgerStoreTests: XCTestCase {
    // Implements: FR-QUEUE-5
    func testSidecarRoundTripAndRepeatedSaveKeepPrivateOwnedMetadataOnly() throws {
        try withStore { store, file in
            let binding = TerminalInputBinding(paneID: "pane", backendPID: 101, generation: "generation")
            var ledger = TerminalInputLedger()
            let receipt = try ledger.beginManualWrite(binding: binding, submissionCandidate: true)
            _ = ledger.finishWrite(receipt, succeeded: true)
            _ = ledger.observeTrustedSubmit(binding: binding)
            try store.save(ledger)
            var before = stat(); XCTAssertEqual(lstat(file.path, &before), 0)
            XCTAssertEqual(before.st_mode & 0o777, 0o600)
            XCTAssertEqual(try store.load(), ledger)
            try store.save(ledger)
            var after = stat(); XCTAssertEqual(lstat(file.path, &after), 0)
            XCTAssertEqual(before.st_ino, after.st_ino)
            XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("text"))
        }
    }

    // Implements: FR-QUEUE-5
    func testMissingSidecarStaysUnknown() throws {
        try withStore { store, _ in
            let ledger = try store.load()
            XCTAssertEqual(ledger.readiness(binding: TerminalInputBinding(paneID: "pane", backendPID: 101, generation: "generation")), .inputReviewRequired)
        }
    }

    // Implements: FR-QUEUE-5
    func testCorruptSidecarCannotBeSilentlyOverwrittenToLoseOutstandingWrites() throws {
        try withStore { store, file in
            try Data("{truncated".utf8).write(to: file)
            XCTAssertEqual(chmod(file.path, 0o600), 0)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(TerminalInputLedger()))
            XCTAssertEqual(try Data(contentsOf: file), Data("{truncated".utf8))
        }
    }

    // Implements: FR-QUEUE-5
    func testSidecarRejectsSymlinkAndDoesNotModifyTarget() throws {
        try withStore { store, file in
            let target = file.deletingLastPathComponent().appendingPathComponent("target")
            try Data("target".utf8).write(to: target)
            XCTAssertEqual(symlink(target.path, file.path), 0)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(TerminalInputLedger()))
            XCTAssertEqual(try Data(contentsOf: target), Data("target".utf8))
        }
    }

    // Implements: FR-QUEUE-5
    func testSidecarRejectsPublicPermissionsAndHardLinks() throws {
        try withStore { store, file in
            try store.save(TerminalInputLedger())
            XCTAssertEqual(chmod(file.path, 0o644), 0)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(TerminalInputLedger()))
            XCTAssertEqual(chmod(file.path, 0o600), 0)
            let second = file.deletingLastPathComponent().appendingPathComponent("second")
            XCTAssertEqual(link(file.path, second.path), 0)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(TerminalInputLedger()))
        }
    }

    // Implements: FR-QUEUE-5
    func testSidecarRejectsNonRegularOrOversizedFiles() throws {
        try withStore { store, file in
            XCTAssertEqual(mkfifo(file.path, 0o600), 0)
            XCTAssertThrowsError(try store.load())
            try FileManager.default.removeItem(at: file)
            let fd = open(file.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            XCTAssertGreaterThanOrEqual(fd, 0)
            defer { close(fd) }
            XCTAssertEqual(ftruncate(fd, 8 * 1_048_576 + 1), 0)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(TerminalInputLedger()))
        }
    }

    // Implements: FR-QUEUE-5
    func testSidecarWritesOnlyBelowDedicatedPrivateDirectory() throws {
        try withRawStore { store, root in
            try store.save(TerminalInputLedger())
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("input-state/terminal-input.json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("terminal-input.json").path))
            var info = stat()
            XCTAssertEqual(lstat(root.appendingPathComponent("input-state").path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o777, 0o700)
        }
    }

    // Implements: FR-QUEUE-5
    func testMissingPrivateDirectoryLoadStaysUnknownWithoutCreatingRuntimeEntries() throws {
        try withRawStore { store, root in
            let ledger = try store.load()
            XCTAssertEqual(ledger.readiness(binding: TerminalInputBinding(paneID: "pane", backendPID: 101, generation: "generation")), .inputReviewRequired)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    // Implements: FR-QUEUE-5
    func testPrivateDirectorySymlinkIsRejectedForReadAndSave() throws {
        try withRawStore { store, root in
            let outside = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            XCTAssertEqual(symlink(outside.path, root.appendingPathComponent("input-state").path), 0)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(TerminalInputLedger()))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        }
    }

    // Implements: FR-QUEUE-5
    func testPrivateDirectoryRejectsPublicPermissionsAndRegularFiles() throws {
        try withRawStore { store, root in
            let directory = root.appendingPathComponent("input-state")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
            XCTAssertEqual(chmod(directory.path, 0o755), 0)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(TerminalInputLedger()))
            try FileManager.default.removeItem(at: directory)
            try Data("existing".utf8).write(to: directory)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(TerminalInputLedger()))
            XCTAssertEqual(try Data(contentsOf: directory), Data("existing".utf8))
        }
    }

    // Implements: FR-QUEUE-5
    func testSubsequentInputWritesDoNotSignalRuntimeRootFileWatcher() throws {
        try withRawStore { store, root in
            try store.save(TerminalInputLedger())
            let fd = open(root.path, O_EVTONLY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(fd, 0)
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: DispatchQueue(label: "ledger-root-watch-test"))
            let rootChanged = expectation(description: "No root directory event for input metadata update")
            rootChanged.isInverted = true
            source.setEventHandler { rootChanged.fulfill() }
            source.setCancelHandler { close(fd) }
            source.resume()
            defer { source.cancel() }
            var ledger = try store.load()
            _ = try ledger.beginManualWrite(binding: TerminalInputBinding(paneID: "pane", backendPID: 101, generation: "generation"))
            try store.save(ledger)
            wait(for: [rootChanged], timeout: 0.15)
        }
    }

    private func withRawStore(_ body: (TerminalInputLedgerStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-input-ledger-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try body(TerminalInputLedgerStore(root: root), root)
    }

    private func withStore(_ body: (TerminalInputLedgerStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-input-ledger-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("input-state", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try body(TerminalInputLedgerStore(root: root), directory.appendingPathComponent("terminal-input.json"))
    }
}
