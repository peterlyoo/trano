import Foundation
import XCTest
import Darwin
@testable import TerminalCore

final class UnisessionTests: XCTestCase {
    // Implements: FR-UNI-1, FR-UNI-3, FR-UNI-6
    func testPassiveBindingReadNeverCreatesShellOrStateFile() throws {
        let f = try fixture(); defer { f.remove() }
        XCTAssertNil(try f.coordinator.binding())
        XCTAssertEqual(f.backend.creates, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("unisession.json").path))
    }

    func testExplicitOpenReservesBeforeCreatingPlainDetachedShellAndReusesDurably() throws {
        let f = try fixture(); defer { f.remove() }
        f.backend.beforeCreate = { id in
            let record = try XCTUnwrap(f.store.load())
            XCTAssertEqual(record.pendingPaneID, id)
            XCTAssertTrue(record.reservedPaneIDs.contains(id))
            XCTAssertFalse(f.store.reservation().permitsDetachedStartupReuse(id))
        }
        let first = try f.coordinator.ensure(cwd: f.root.path)
        XCTAssertEqual(f.backend.creates, 1)
        XCTAssertEqual(f.backend.createdDirectories, [f.root.path])
        let second = try UnisessionCoordinator(store: UnisessionStateStore(root: f.root), backend: f.backend).ensure(cwd: "/other")
        XCTAssertEqual(first, second)
        XCTAssertEqual(f.backend.creates, 1)
        XCTAssertTrue(f.backend.attached.isEmpty)
        XCTAssertEqual(try f.coordinator.binding(), first)
        XCTAssertNoThrow(try f.coordinator.validate(first))
        let attrs = try FileManager.default.attributesOfItem(atPath: f.root.appendingPathComponent("unisession.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testConcurrentOpensShareOneBindingAcrossCoordinatorInstances() throws {
        let f = try fixture(); defer { f.remove() }
        let lock = NSLock(); var values: [UnisessionBinding] = []; var errors: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do {
                let value = try UnisessionCoordinator(store: UnisessionStateStore(root: f.root), backend: f.backend).ensure(cwd: f.root.path)
                lock.lock(); values.append(value); lock.unlock()
            } catch { lock.lock(); errors.append(error); lock.unlock() }
        }
        XCTAssertTrue(errors.isEmpty, errors.map { $0.localizedDescription }.joined(separator: ";"))
        XCTAssertEqual(values.count, 8)
        XCTAssertEqual(Set(values.map(\.paneID)).count, 1)
        XCTAssertEqual(f.backend.creates, 1)
    }

    func testLiveReplacementAndSamePIDNewBirthFailClosedWithoutSecondShell() throws {
        for replacePID in [true, false] {
            let f = try fixture(); defer { f.remove() }
            let binding = try f.coordinator.ensure(cwd: f.root.path)
            if replacePID { f.backend.sessions[0].pid += 1 }
            else { f.backend.identities[binding.paneID] = identity(binding.backendPID, seconds: 2) }
            XCTAssertThrowsError(try f.coordinator.ensure(cwd: f.root.path))
            XCTAssertThrowsError(try f.coordinator.validate(binding))
            XCTAssertEqual(f.backend.creates, 1)
        }
    }

    func testConfirmedDeadShellRecreatesOnlyOnOpenAndRetiresOriginalFromRecovery() throws {
        let f = try fixture(); defer { f.remove() }
        let old = try f.coordinator.ensure(cwd: f.root.path)
        f.backend.sessions[0].alive = false
        XCTAssertEqual(try f.coordinator.binding(), old)
        XCTAssertEqual(f.backend.creates, 1)
        let replacement = try f.coordinator.ensure(cwd: f.root.path)
        XCTAssertNotEqual(old.paneID, replacement.paneID)
        XCTAssertEqual(f.backend.creates, 2)
        let reservation = f.store.reservation()
        for id in [old.paneID, replacement.paneID] {
            XCTAssertFalse(reservation.permitsDetachedStartupReuse(id))
            XCTAssertFalse(reservation.permitsGenericRecovery(id, attachedPaneIDs: []))
            XCTAssertThrowsError(try reservation.requireOrdinaryPane(id, attachedPaneIDs: []))
        }
        XCTAssertThrowsError(try f.coordinator.validate(old))
    }

    func testExactDetachedLegacySupervisorIsAdoptedWithoutStartingOrSendingAgent() throws {
        let f = try fixture(); defer { f.remove() }
        let pane = TerminalSession(id: UUID().uuidString.lowercased(), title: "Supervisor", cwd: f.root.path, pid: 123)
        f.backend.sessions = [pane]; f.backend.identities[pane.id] = identity(pane.pid)
        let legacy = SupervisorBinding(paneID: pane.id, backendPID: pane.pid,
            configuration: SupervisorConfiguration(provider: .codex, cwd: f.root.path), processIdentity: identity(pane.pid))
        try SupervisorStateStore(root: f.root).save(legacy)
        let adopted = try f.coordinator.ensure(cwd: f.root.path)
        XCTAssertEqual(adopted.paneID, pane.id)
        XCTAssertEqual(adopted.processIdentity, legacy.processIdentity)
        XCTAssertEqual(f.backend.creates, 0)
        XCTAssertEqual(try SupervisorStateStore(root: f.root).load(), legacy)
    }

    func testAttachedLegacySupervisorIsNeverStolenFromOpenOrClosedWorkspace() throws {
        let f = try fixture(); defer { f.remove() }
        let pane = TerminalSession(id: UUID().uuidString.lowercased(), title: "Supervisor", cwd: f.root.path, pid: 123)
        f.backend.sessions = [pane]; f.backend.attached = [pane.id]; f.backend.identities[pane.id] = identity(pane.pid)
        try SupervisorStateStore(root: f.root).save(SupervisorBinding(paneID: pane.id, backendPID: pane.pid,
            configuration: SupervisorConfiguration(provider: .claude, cwd: f.root.path), processIdentity: identity(pane.pid)))
        let binding = try f.coordinator.ensure(cwd: f.root.path)
        XCTAssertNotEqual(binding.paneID, pane.id)
        XCTAssertEqual(f.backend.attached, [pane.id])
        XCTAssertEqual(f.backend.sessions.first?.pid, pane.pid)
    }

    func testDetachedLegacyWithForeignBirthDoesNotGetAdoptedOrAbandoned() throws {
        let f = try fixture(); defer { f.remove() }
        let pane = TerminalSession(id: UUID().uuidString.lowercased(), title: "Supervisor", cwd: f.root.path, pid: 123)
        f.backend.sessions = [pane]; f.backend.identities[pane.id] = identity(pane.pid, seconds: 2)
        try SupervisorStateStore(root: f.root).save(SupervisorBinding(paneID: pane.id, backendPID: pane.pid,
            configuration: SupervisorConfiguration(provider: .claude, cwd: f.root.path), processIdentity: identity(pane.pid)))
        XCTAssertThrowsError(try f.coordinator.ensure(cwd: f.root.path))
        XCTAssertEqual(f.backend.creates, 0)
        XCTAssertNil(try f.store.load())
    }

    func testPendingCreationCanPublishAlreadyCreatedOwnedDetachedShellAfterInterruption() throws {
        let f = try fixture(); defer { f.remove() }
        let pane = TerminalSession(id: UUID().uuidString.lowercased(), title: "Unisession", cwd: f.root.path, pid: 123)
        try f.store.save(UnisessionRecord(pendingPaneID: pane.id, reservedPaneIDs: [pane.id]))
        f.backend.sessions = [pane]; f.backend.identities[pane.id] = identity(pane.pid)
        let binding = try f.coordinator.ensure(cwd: f.root.path)
        XCTAssertEqual(binding.paneID, pane.id)
        XCTAssertNil(try f.store.load()?.pendingPaneID)
        XCTAssertEqual(f.backend.creates, 0)
    }

    func testCreationFailureRetainsReservationAndRetriesSameIDWithoutCreatingSecondIdentity() throws {
        let f = try fixture(); defer { f.remove() }
        f.backend.failCreate = true
        XCTAssertThrowsError(try f.coordinator.ensure(cwd: f.root.path))
        let pending = try XCTUnwrap(f.store.load()?.pendingPaneID)
        XCTAssertFalse(f.store.reservation().permitsDetachedStartupReuse(pending))
        f.backend.failCreate = false
        let result = try f.coordinator.ensure(cwd: f.root.path)
        XCTAssertEqual(result.paneID, pending)
        XCTAssertEqual(f.backend.attemptedIDs, [pending, pending])
        XCTAssertEqual(f.backend.sessions.count, 1)
    }

    func testValidationRejectsAttachmentAndNonPublishedBinding() throws {
        let f = try fixture(); defer { f.remove() }
        let binding = try f.coordinator.ensure(cwd: f.root.path)
        let wrong = UnisessionBinding(paneID: UUID().uuidString.lowercased(), backendPID: binding.backendPID, processIdentity: binding.processIdentity)
        XCTAssertThrowsError(try f.coordinator.validate(wrong))
        f.backend.attached = [binding.paneID]
        XCTAssertThrowsError(try f.coordinator.ensure(cwd: f.root.path))
        XCTAssertThrowsError(try f.coordinator.validate(binding))
        XCTAssertEqual(f.backend.creates, 1)
    }

    func testCorruptSymlinkFIFOAndHardlinkRecordsFailClosedWithoutHanging() throws {
        for kind in ["corrupt", "symlink", "fifo", "hardlink", "oversized", "public"] {
            let f = try fixture(); defer { f.remove() }
            let path = f.root.appendingPathComponent("unisession.json").path
            switch kind {
            case "corrupt": try Data("invalid\n".utf8).write(to: URL(fileURLWithPath: path)); _ = chmod(path, 0o600)
            case "symlink": XCTAssertEqual(symlink("missing", path), 0)
            case "fifo": XCTAssertEqual(mkfifo(path, 0o600), 0)
            case "hardlink":
                let other = f.root.appendingPathComponent("other").path
                XCTAssertEqual(close(open(other, O_CREAT | O_WRONLY, 0o600)), 0); XCTAssertEqual(link(other, path), 0)
            case "oversized": try Data(repeating: 65, count: 65_537).write(to: URL(fileURLWithPath: path)); _ = chmod(path, 0o600)
            default: try Data("null\n".utf8).write(to: URL(fileURLWithPath: path)); _ = chmod(path, 0o644)
            }
            XCTAssertThrowsError(try f.store.load(), kind)
            XCTAssertEqual(f.store.reservation(), .unavailable, kind)
            XCTAssertThrowsError(try f.coordinator.ensure(cwd: f.root.path), kind)
            XCTAssertEqual(f.backend.creates, 0, kind)
        }
    }

    func testUnavailableReservationPreservesAttachedPanesAndBlocksUnknownDetachedPanes() throws {
        let reservation = DetachedPaneReservation.unavailable
        XCTAssertFalse(reservation.permitsDetachedStartupReuse("detached"))
        XCTAssertFalse(reservation.permitsGenericRecovery("detached", attachedPaneIDs: ["ordinary"]))
        XCTAssertTrue(reservation.permitsGenericRecovery("ordinary", attachedPaneIDs: ["ordinary"]))
        XCTAssertThrowsError(try reservation.requireOrdinaryPane("detached", attachedPaneIDs: ["ordinary"]))
        XCTAssertNoThrow(try reservation.requireOrdinaryPane("ordinary", attachedPaneIDs: ["ordinary"]))
    }

    private func identity(_ pid: Int32, seconds: UInt64 = 1) -> SupervisorProcessIdentity {
        SupervisorProcessIdentity(pid: pid, ownerUID: getuid(), startedAtSeconds: seconds, startedAtMicroseconds: 1)
    }
    private struct Fixture {
        let root: URL; let store: UnisessionStateStore; let backend: FakeBackend
        var coordinator: UnisessionCoordinator<FakeBackend> { UnisessionCoordinator(store: store, backend: backend) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: "/tmp/trano-uni-unit-" + UUID().uuidString.prefix(8))
        guard mkdir(root.path, 0o700) == 0 else { throw TerminalError.runtime("Fixture mkdir failed") }
        return Fixture(root: root, store: UnisessionStateStore(root: root), backend: FakeBackend())
    }
    private final class FakeBackend: UnisessionBackend {
        let lock = NSRecursiveLock()
        var sessions: [TerminalSession] = []
        var attached: Set<String> = []
        var identities: [String: SupervisorProcessIdentity] = [:]
        var creates = 0
        var createdDirectories: [String] = []
        var attemptedIDs: [String] = []
        var beforeCreate: ((String) throws -> Void)?
        var failCreate = false
        func transaction<T>(_ body: () throws -> T) throws -> T { lock.lock(); defer { lock.unlock() }; return try body() }
        func observe() throws -> UnisessionObservation { UnisessionObservation(sessions: sessions, attachedPaneIDs: attached) }
        func createDetached(paneID: String, cwd: String) throws -> TerminalSession {
            attemptedIDs.append(paneID)
            try beforeCreate?(paneID)
            if failCreate { throw TerminalError.runtime("Synthetic creation failure") }
            guard !sessions.contains(where: { $0.id == paneID }) else { throw TerminalError.invalid("Duplicate shell") }
            creates += 1; createdDirectories.append(cwd)
            let pid = Int32(100 + creates)
            let pane = TerminalSession(id: paneID, title: "Unisession", cwd: cwd, pid: pid)
            sessions.append(pane)
            identities[paneID] = SupervisorProcessIdentity(pid: pid, ownerUID: getuid(), startedAtSeconds: 1, startedAtMicroseconds: 1)
            return pane
        }
        func processIdentity(paneID: String, backendPID: Int32) throws -> SupervisorProcessIdentity? { identities[paneID] }
    }
}
