import Foundation
import XCTest
import Darwin
@testable import TerminalCore

final class SupervisorTests: XCTestCase {
    // Implements: FR-SUP-2, FR-SUP-5
    func testBirthIdentityIsPersistedAndPIDReuseCannotBeAdoptedOrStopped() throws {
        let f = try fixture()
        defer { dispose(f) }
        let configuration = SupervisorConfiguration(provider: .claude, cwd: f.root.path)
        let initial = try f.coordinator.start(configuration: configuration, instructions: "Continue assigned work.")
        let binding = try XCTUnwrap(initial.binding)
        let expected = try XCTUnwrap(binding.processIdentity)
        XCTAssertEqual(expected, try f.store.load()?.processIdentity)
        f.backend.observation.backendIdentities[binding.paneID] = SupervisorProcessIdentity(pid: binding.backendPID,
            ownerUID: getuid(), startedAtSeconds: expected.startedAtSeconds + 1, startedAtMicroseconds: expected.startedAtMicroseconds)
        XCTAssertEqual(try f.coordinator.state().phase, .needsAttention)
        XCTAssertThrowsError(try f.coordinator.start(configuration: configuration, instructions: "Do not replay."))
        XCTAssertThrowsError(try f.coordinator.stop(expectedPaneID: binding.paneID, expectedBackendPID: binding.backendPID))
        XCTAssertTrue(f.backend.terminated.isEmpty)
        XCTAssertEqual(f.backend.created.count, 1)
    }

    // Implements: FR-SUP-2, FR-SUP-5
    func testConcurrentStartsAcrossCoordinatorsShareOneDetachedSession() throws {
        let f = try fixture()
        defer { dispose(f) }
        let outcomes = ConcurrentOutcomes()
        let configuration = SupervisorConfiguration(provider: .claude, cwd: f.root.path)
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            let coordinator = SupervisorCoordinator(store: SupervisorStateStore(root: f.root), backend: f.backend,
                                                    helperExecutable: "/tmp/fake trano")
            outcomes.record { try coordinator.start(configuration: configuration, instructions: "Continue assigned work.") }
        }
        XCTAssertEqual(outcomes.values.count, 12)
        XCTAssertTrue(outcomes.errors.isEmpty)
        XCTAssertEqual(Set(outcomes.values.compactMap { $0.binding?.paneID }).count, 1)
        XCTAssertEqual(f.backend.created.count, 1)
        XCTAssertEqual(f.backend.commands.count, 1)
    }

    // Implements: FR-SUP-2, FR-SUP-5
    func testMissingSupervisorRequiresReviewBeforeAdvertisingANewStart() throws {
        let f = try fixture()
        defer { dispose(f) }
        let configuration = SupervisorConfiguration(provider: .claude, cwd: f.root.path)
        let initial = try f.coordinator.start(configuration: configuration, instructions: "Continue assigned work.")
        let binding = try XCTUnwrap(initial.binding)
        f.backend.observation.sessions.removeAll { $0.id == binding.paneID }
        XCTAssertEqual(try f.coordinator.state().phase, .needsAttention)
        XCTAssertThrowsError(try f.coordinator.start(configuration: configuration, instructions: "Do not replay."))
        XCTAssertEqual(f.backend.created.count, 1)
        let stopped = try f.coordinator.stop(expectedPaneID: binding.paneID, expectedBackendPID: binding.backendPID)
        XCTAssertEqual(stopped.phase, .stopped)
        XCTAssertNotNil(stopped.binding?.stoppedAt)
    }

    // Implements: FR-SUP-1, FR-SUP-2, FR-SUP-5
    func testGenericRecoveryLeavesReservedSupervisorAndAmbiguousDetachedJobsUntouched() {
        let own = UUID().uuidString.lowercased()
        let attached = UUID().uuidString.lowercased()
        let detached = UUID().uuidString.lowercased()
        let panes: Set<String> = [attached]
        XCTAssertFalse(SupervisorPaneReservation.bound(own).permitsGenericRecovery(own, attachedPaneIDs: panes))
        XCTAssertTrue(SupervisorPaneReservation.bound(own).permitsGenericRecovery(attached, attachedPaneIDs: panes))
        XCTAssertTrue(SupervisorPaneReservation.absent.permitsGenericRecovery(detached, attachedPaneIDs: panes))
        XCTAssertFalse(SupervisorPaneReservation.unavailable.permitsGenericRecovery(detached, attachedPaneIDs: panes))
        XCTAssertTrue(SupervisorPaneReservation.unavailable.permitsGenericRecovery(attached, attachedPaneIDs: panes))
    }

    // Implements: FR-SUP-1, FR-SUP-5
    func testSupervisorReservationCannotBeAdoptedAsAnOrdinaryDetachedTerminal() {
        let own = UUID().uuidString.lowercased()
        let peer = UUID().uuidString.lowercased()
        XCTAssertTrue(SupervisorPaneReservation.absent.permitsDetachedStartupReuse(peer))
        XCTAssertFalse(SupervisorPaneReservation.bound(own).permitsDetachedStartupReuse(own))
        XCTAssertTrue(SupervisorPaneReservation.bound(own).permitsDetachedStartupReuse(peer))
        XCTAssertFalse(SupervisorPaneReservation.unavailable.permitsDetachedStartupReuse(own))
        XCTAssertFalse(SupervisorPaneReservation.unavailable.permitsDetachedStartupReuse(peer))
    }

    // Implements: FR-SUP-2, FR-SUP-5
    func testStartCreatesOneDetachedManagedSessionAndKeepsWorkspaceSelection() throws {
        let f = try fixture()
        defer { dispose(f) }
        let original = f.backend.observation.layout
        let config = SupervisorConfiguration(provider: .claude, cwd: f.root.path)
        let first = try f.coordinator.start(configuration: config, instructions: "Supervise existing assigned work.")
        let second = try f.coordinator.start(configuration: config, instructions: "Supervise existing assigned work.")
        let binding = try XCTUnwrap(first.binding)
        XCTAssertEqual(first.phase, .starting)
        XCTAssertEqual(second.binding, binding)
        XCTAssertEqual(f.backend.created.count, 1)
        XCTAssertEqual(f.backend.commands.count, 1)
        XCTAssertEqual(f.backend.observation.layout, original)
        XCTAssertFalse(original.tabs.flatMap(\.panes).contains(binding.paneID))
        XCTAssertEqual(f.backend.commands[0].paneID, binding.paneID)
        XCTAssertEqual(f.backend.commands[0].plan.arguments,
                       ["/tmp/fake trano", "run", "--agent", "claude", "--", "Supervise existing assigned work."])
        XCTAssertEqual(try f.coordinator.state().binding, binding)
    }

    // Implements: FR-SUP-2, FR-SUP-5
    func testManagedAccountLaunchPreservesUnicodePromptAsOneArgument() throws {
        let f = try fixture()
        defer { dispose(f) }
        let account = AccountProfile(provider: .codex, label: "Fixture")
        f.backend.observation.accounts = [account]
        let text = "한글 \"quoted\"; next step\n한글"
        let state = try f.coordinator.start(configuration: SupervisorConfiguration(provider: .codex, accountID: account.id, cwd: f.root.path), instructions: text)
        XCTAssertEqual(state.binding?.configuration.accountID, account.id)
        XCTAssertEqual(f.backend.commands.first?.plan.arguments,
                       ["/tmp/fake trano", "account", "exec", account.id, "--", text])
        XCTAssertEqual(f.backend.commands.first?.plan.arguments.last?.utf8.map { $0 }, Array(text.utf8))
    }

    // Implements: FR-SUP-2, FR-SUP-5
    func testFailedProviderDispatchRollsBackOnlyItsNewOwnedSession() throws {
        let f = try fixture()
        defer { dispose(f) }
        let peers = f.backend.observation.sessions
        f.backend.failLaunch = true
        XCTAssertThrowsError(try f.coordinator.start(configuration: SupervisorConfiguration(provider: .claude, cwd: f.root.path), instructions: "Continue assigned work."))
        XCTAssertEqual(f.backend.created.count, 1)
        XCTAssertEqual(f.backend.terminated, f.backend.created.map(\.id))
        XCTAssertEqual(f.backend.observation.sessions, peers)
        XCTAssertNil(try f.store.load())
    }

    // Implements: FR-SUP-2, FR-SUP-5
    func testInvalidConfigurationCannotCreateAProviderOrChangePeerJobs() throws {
        let f = try fixture()
        defer { dispose(f) }
        let peers = f.backend.observation.sessions
        for config in [SupervisorConfiguration(provider: .shell, cwd: f.root.path),
                       SupervisorConfiguration(provider: .claude, accountID: UUID().uuidString, cwd: f.root.path),
                       SupervisorConfiguration(provider: .claude, cwd: f.root.appendingPathComponent("missing").path)] {
            XCTAssertThrowsError(try f.coordinator.start(configuration: config, instructions: "Continue assigned work."))
        }
        XCTAssertTrue(f.backend.created.isEmpty)
        XCTAssertTrue(f.backend.commands.isEmpty)
        XCTAssertEqual(f.backend.observation.sessions, peers)
    }

    // Implements: FR-SUP-2, FR-SUP-5
    func testStopRequiresTheExactBoundSessionAndBackendPID() throws {
        let f = try fixture()
        defer { dispose(f) }
        let state = try f.coordinator.start(configuration: SupervisorConfiguration(provider: .claude, cwd: f.root.path), instructions: "Continue assigned work.")
        let binding = try XCTUnwrap(state.binding)
        let peers = f.backend.observation.sessions.filter { $0.id != binding.paneID }
        XCTAssertThrowsError(try f.coordinator.stop(expectedPaneID: UUID().uuidString, expectedBackendPID: binding.backendPID))
        XCTAssertThrowsError(try f.coordinator.stop(expectedPaneID: binding.paneID, expectedBackendPID: binding.backendPID + 1))
        XCTAssertTrue(f.backend.terminated.isEmpty)
        let stopped = try f.coordinator.stop(expectedPaneID: binding.paneID, expectedBackendPID: binding.backendPID)
        XCTAssertEqual(stopped.phase, .stopped)
        XCTAssertNotNil(stopped.binding?.stoppedAt)
        XCTAssertEqual(f.backend.terminated, [binding.paneID])
        XCTAssertEqual(f.backend.observation.sessions, peers)
    }

    // Implements: FR-SUP-2, FR-SUP-5
    func testReplacedBackendCannotBeAdoptedOrTerminatedByAnOldBinding() throws {
        let f = try fixture()
        defer { dispose(f) }
        let config = SupervisorConfiguration(provider: .claude, cwd: f.root.path)
        let initial = try f.coordinator.start(configuration: config, instructions: "Continue assigned work.")
        let binding = try XCTUnwrap(initial.binding)
        let index = try XCTUnwrap(f.backend.observation.sessions.firstIndex { $0.id == binding.paneID })
        f.backend.observation.sessions[index].pid += 100
        XCTAssertEqual(try f.coordinator.state().phase, .needsAttention)
        XCTAssertThrowsError(try f.coordinator.start(configuration: config, instructions: "Do not replay."))
        XCTAssertThrowsError(try f.coordinator.stop(expectedPaneID: binding.paneID, expectedBackendPID: binding.backendPID))
        XCTAssertEqual(f.backend.created.count, 1)
        XCTAssertTrue(f.backend.terminated.isEmpty)
    }

    // Implements: FR-SUP-3, FR-SUP-4
    func testProjectionExcludesSelfAndDoesNotTreatDoneAsEmptyInputProof() throws {
        let f = try fixture()
        defer { dispose(f) }
        let state = try f.coordinator.start(configuration: SupervisorConfiguration(provider: .claude, cwd: f.root.path), instructions: "Continue assigned work.")
        let binding = try XCTUnwrap(state.binding)
        f.backend.observation.sessions[0].activity.state = .done
        f.backend.observation.sessions[1].activity.state = .blocked
        f.backend.observation.pendingDecisionPaneIDs = [f.backend.observation.sessions[1].id]
        let projected = try f.coordinator.state()
        XCTAssertEqual(projected.targets.count, 2)
        XCTAssertFalse(projected.targets.contains { $0.paneID == binding.paneID })
        XCTAssertEqual(projected.targets.first { $0.paneID == f.backend.observation.sessions[0].id }?.continuation, .inputReviewRequired)
        XCTAssertEqual(projected.targets.first { $0.paneID == f.backend.observation.sessions[1].id }?.continuation, .decisionRequired)
    }

    // Implements: FR-SUP-3, FR-SUP-5
    func testWatchCursorIgnoresSelfAndTitleOnlyChangesButDetectsTargetTransitions() throws {
        let f = try fixture()
        defer { dispose(f) }
        let initial = try f.coordinator.start(configuration: SupervisorConfiguration(provider: .claude, cwd: f.root.path), instructions: "Continue assigned work.")
        let binding = try XCTUnwrap(initial.binding)
        let before = try f.coordinator.state().cursor
        let own = try XCTUnwrap(f.backend.observation.sessions.firstIndex { $0.id == binding.paneID })
        f.backend.observation.sessions[own].activity.state = .running
        f.backend.observation.sessions[own].activity.updatedAt = Date().addingTimeInterval(20)
        f.backend.observation.sessions[0].terminalTitle = "A title update"
        XCTAssertEqual(try f.coordinator.state().cursor, before)
        f.backend.observation.sessions[0].activity.state = .done
        XCTAssertNotEqual(try f.coordinator.state().cursor, before)
    }

    // Implements: FR-SUP-5
    func testPrivateSidecarSurvivesAnOldPrimaryStateRewrite() throws {
        let f = try fixture()
        defer { dispose(f) }
        let binding = SupervisorBinding(paneID: UUID().uuidString.lowercased(), backendPID: 1234,
                                        configuration: SupervisorConfiguration(provider: .claude, cwd: f.root.path))
        try f.store.save(binding)
        try Data("{\"schemaVersion\":1}\n".utf8).write(to: f.root.appendingPathComponent("state.json"))
        XCTAssertEqual(try SupervisorStateStore(root: f.root).load(), binding)
        let attributes = try FileManager.default.attributesOfItem(atPath: f.store.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // Implements: FR-SUP-5
    func testSidecarRejectsSymlinksAndPublicFilesBeforeReadingOrReplacingThem() throws {
        let f = try fixture()
        defer { dispose(f) }
        let other = f.root.appendingPathComponent("other.json")
        try Data("null\n".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: f.store.url, withDestinationURL: other)
        XCTAssertThrowsError(try f.store.load())
        XCTAssertThrowsError(try f.store.save(nil))
        XCTAssertEqual(try Data(contentsOf: other), Data("null\n".utf8))
        try FileManager.default.removeItem(at: f.store.url)
        try Data("null\n".utf8).write(to: f.store.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.store.url.path)
        XCTAssertThrowsError(try f.store.load())
        XCTAssertThrowsError(try f.store.save(nil))
    }

    private struct Fixture {
        let root: URL
        let backend: FakeSupervisorBackend
        let store: SupervisorStateStore
        let coordinator: SupervisorCoordinator<FakeSupervisorBackend>
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-supervisor-unit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let backend = FakeSupervisorBackend()
        let store = SupervisorStateStore(root: root)
        return Fixture(root: root, backend: backend, store: store,
                       coordinator: SupervisorCoordinator(store: store, backend: backend, helperExecutable: "/tmp/fake trano"))
    }

    private func dispose(_ fixture: Fixture) { try? FileManager.default.removeItem(at: fixture.root) }
}

private final class ConcurrentOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [SupervisorState] = []
    private(set) var errors: [Error] = []
    func record(_ work: () throws -> SupervisorState) {
        let result = Result { try work() }
        lock.lock(); defer { lock.unlock() }
        switch result {
        case .success(let value): values.append(value)
        case .failure(let error): errors.append(error)
        }
    }
}

private final class FakeSupervisorBackend: SupervisorBackend {
    var observation: SupervisorObservation
    var created: [TerminalSession] = []
    var commands: [(paneID: String, plan: SupervisorLaunchPlan)] = []
    var terminated: [String] = []
    var failLaunch = false
    private let lock = NSRecursiveLock()

    init() {
        let peers = (0..<2).map { TerminalSession(id: UUID().uuidString.lowercased(), title: "Peer \($0)", cwd: "/tmp", pid: Int32(2000 + $0)) }
        var layout = WorkspaceLayout()
        layout.addWorkspace(title: "Existing workspace")
        for peer in peers { layout.addTab(paneID: peer.id) }
        observation = SupervisorObservation(layout: layout, sessions: peers)
    }

    func transaction<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
    func observe() -> SupervisorObservation { observation }
    func createDetached(cwd: String) -> TerminalSession {
        let pane = TerminalSession(id: UUID().uuidString.lowercased(), title: "Supervisor", cwd: cwd, pid: Int32(10_000 + created.count))
        created.append(pane)
        observation.sessions.append(pane)
        observation.backendIdentities[pane.id] = SupervisorProcessIdentity(pid: pane.pid, ownerUID: getuid(), startedAtSeconds: 1, startedAtMicroseconds: 1)
        return pane
    }
    func launch(paneID: String, plan: SupervisorLaunchPlan) throws {
        if failLaunch { throw TerminalError.runtime("Fixture launch failure") }
        commands.append((paneID, plan))
    }
    func terminate(paneID: String) {
        terminated.append(paneID)
        observation.sessions.removeAll { $0.id == paneID }
    }
    func processIdentity(paneID: String, backendPID: Int32) -> SupervisorProcessIdentity? {
        observation.backendIdentities[paneID]
    }
}
