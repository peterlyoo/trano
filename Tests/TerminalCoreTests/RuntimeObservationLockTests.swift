import Darwin
import Foundation
import XCTest
@testable import TerminalCore

final class RuntimeObservationLockTests: XCTestCase {
    // Implements: FR-QUEUE-5, FR-NAV-9
    func testListMetadataProbeAllowsNativeInputAndAnotherRuntimeTransaction() throws {
        try assertProbeReleasesOwnTransaction(.sessions)
    }

    // Implements: FR-QUEUE-5, FR-LOAD-1, FR-LOAD-2
    func testSessionLoadMetadataProbeAllowsNativeInputAndAnotherRuntimeTransaction() throws {
        try assertProbeReleasesOwnTransaction(.targets)
    }

    // Implements: FR-QUEUE-5, FR-NAV-9
    func testListRetainsExplicitCallerTransactionAfterMetadataReturns() throws {
        try assertExplicitCallerTransactionRemainsHeld(.sessions)
    }

    // Implements: FR-QUEUE-5, FR-LOAD-1, FR-LOAD-2
    func testSessionLoadTargetsRetainExplicitCallerTransactionAfterMetadataReturns() throws {
        try assertExplicitCallerTransactionRemainsHeld(.targets)
    }

    private enum ObservationKind { case sessions, targets }
    private enum Observation {
        case sessions([TerminalSession])
        case targets([SessionLoadTarget])
    }

    private final class LockedValue<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func set(_ value: Value) { lock.lock(); self.value = value; lock.unlock() }
        func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func observe(_ kind: ObservationKind, runtime: TerminalRuntime) throws -> Observation {
        switch kind {
        case .sessions: return .sessions(try runtime.list())
        case .targets: return .targets(try runtime.sessionLoadTargets())
        }
    }

    private func assertProbeReleasesOwnTransaction(_ kind: ObservationKind) throws {
        let fixture = try Fixture()
        let group = DispatchGroup()
        defer {
            fixture.releaseProbe()
            XCTAssertEqual(group.wait(timeout: .now() + 8), .success)
            fixture.cleanup()
        }
        let observation = LockedValue<Result<Observation, Error>?>(nil)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            observation.set(Result { try self.observe(kind, runtime: fixture.runtime) })
        }
        guard fixture.waitForProbe() else { XCTFail("Fake pane listing never entered"); return }

        let inputFinished = DispatchSemaphore(value: 0)
        let input = LockedValue<Result<Int, Error>?>(nil)
        let reservedBeforeWrite = LockedValue(false)
        group.enter()
        DispatchQueue.global().async {
            fixture.runtime.deliverTerminalInput(paneID: fixture.paneID, expectedPID: fixture.binding.backendPID,
                expectedBinding: fixture.binding, bytes: [120],
                segments: [TerminalUserInputSegment(bytes: [120], submissionCandidate: false)],
                write: { bytes, completion in
                    let ledger = try? TerminalInputLedgerStore(root: fixture.root).load()
                    reservedBeforeWrite.set(ledger?.readiness(binding: fixture.binding) == .inputInFlight)
                    completion(.success(bytes.count))
                }, completion: { result in
                    input.set(result)
                    inputFinished.signal()
                    group.leave()
                })
        }

        let mutationFinished = DispatchSemaphore(value: 0)
        let mutation = LockedValue<Result<Void, Error>?>(nil)
        group.enter()
        DispatchQueue.global().async {
            defer { mutationFinished.signal(); group.leave() }
            mutation.set(Result { try fixture.otherRuntime.update { $0.settings.fontSize += 1 } })
        }
        let inputBeforeRelease = inputFinished.wait(timeout: .now() + 1)
        let mutationBeforeRelease = mutationFinished.wait(timeout: .now() + 1)
        XCTAssertEqual(inputBeforeRelease, .success, "Metadata discovery must not block native input on the runtime mutex")
        XCTAssertEqual(mutationBeforeRelease, .success, "Metadata discovery must not retain the cross-runtime state flock")
        fixture.releaseProbe()
        guard group.wait(timeout: .now() + 5) == .success else { XCTFail("Probe work did not finish after release"); return }
        XCTAssertEqual(try XCTUnwrap(input.get()).get(), 1)
        XCTAssertTrue(reservedBeforeWrite.get(), "Input must be durably reserved before its writer runs")
        try XCTUnwrap(mutation.get()).get()
        try assertProjection(XCTUnwrap(observation.get()).get(), fixture: fixture)
        let saved = try fixture.runtime.state()
        XCTAssertEqual(saved.sessions.first?.pid, fixture.binding.backendPID)
        XCTAssertEqual(saved.sessions.first?.title, "Stored title")
        XCTAssertNil(saved.sessions.first?.terminalTitle)
        XCTAssertEqual(saved.settings.fontSize, fixture.originalFontSize + 1)
        XCTAssertEqual(try TerminalInputLedgerStore(root: fixture.root).load().readiness(binding: fixture.binding), .inputReviewRequired)
    }

    private func assertExplicitCallerTransactionRemainsHeld(_ kind: ObservationKind) throws {
        let fixture = try Fixture()
        let group = DispatchGroup()
        let releaseCaller = DispatchSemaphore(value: 0)
        defer {
            fixture.releaseProbe()
            releaseCaller.signal()
            XCTAssertEqual(group.wait(timeout: .now() + 8), .success)
            fixture.cleanup()
        }
        let observed = DispatchSemaphore(value: 0)
        let observation = LockedValue<Result<Observation, Error>?>(nil)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            observation.set(Result {
                try fixture.runtime.transaction {
                    let value = try self.observe(kind, runtime: fixture.runtime)
                    observed.signal()
                    guard releaseCaller.wait(timeout: .now() + 6) == .success else {
                        throw TerminalError.runtime("Explicit caller was never released")
                    }
                    return value
                }
            })
        }
        guard fixture.waitForProbe() else { XCTFail("Fake pane listing never entered"); return }
        let mutationFinished = DispatchSemaphore(value: 0)
        let mutation = LockedValue<Result<Void, Error>?>(nil)
        group.enter()
        DispatchQueue.global().async {
            defer { mutationFinished.signal(); group.leave() }
            mutation.set(Result { try fixture.otherRuntime.update { $0.settings.fontSize += 1 } })
        }
        XCTAssertEqual(mutationFinished.wait(timeout: .now() + 0.15), .timedOut)
        fixture.releaseProbe()
        guard observed.wait(timeout: .now() + 3) == .success else { XCTFail("Metadata did not return after release"); return }
        XCTAssertEqual(mutationFinished.wait(timeout: .now() + 0.15), .timedOut,
                       "An observation must not release its caller's explicit transaction")
        releaseCaller.signal()
        guard group.wait(timeout: .now() + 5) == .success else { XCTFail("Caller transaction did not finish"); return }
        try XCTUnwrap(mutation.get()).get()
        try assertProjection(XCTUnwrap(observation.get()).get(), fixture: fixture)
    }

    private func assertProjection(_ observation: Observation, fixture: Fixture) throws {
        switch observation {
        case .sessions(let sessions):
            let pane = try XCTUnwrap(sessions.first)
            XCTAssertEqual(sessions.count, 1)
            XCTAssertEqual(pane.id, fixture.paneID)
            XCTAssertEqual(pane.pid, fixture.observedPID)
            XCTAssertTrue(pane.alive)
            XCTAssertEqual(pane.title, "Stored title")
            XCTAssertEqual(pane.terminalTitle, "Live metadata title")
        case .targets(let targets):
            let target = try XCTUnwrap(targets.first)
            XCTAssertEqual(targets.count, 1)
            XCTAssertEqual(target.paneID, fixture.paneID)
            XCTAssertEqual(target.backendPID, fixture.observedPID)
            XCTAssertTrue(target.alive)
            XCTAssertTrue(target.local)
            XCTAssertEqual(target.provider, .claude)
            XCTAssertEqual(target.providerPID, fixture.binding.providerPID)
            XCTAssertEqual(target.providerSessionID, "fixture-conversation")
            XCTAssertEqual(target.ownershipToken, "pty:fixture-generation:\(fixture.observedPID):agent:\(fixture.binding.generation)")
        }
    }

    private final class Fixture: @unchecked Sendable {
        let root = URL(fileURLWithPath: "/tmp/trano-observe-" + UUID().uuidString.prefix(10))
        let paneID = UUID().uuidString.lowercased()
        let observedPID: Int32 = 900002
        let binding: TerminalInputBinding
        let runtime: TerminalRuntime
        let otherRuntime: TerminalRuntime
        let originalFontSize: Double
        let backend: FakePaneBackend
        private var ready: URL { root.appendingPathComponent("probe-ready") }
        private var release: URL { root.appendingPathComponent("probe-release") }

        init() throws {
            backend = FakePaneBackend(panes: [FakePaneBackend.pane(id: paneID, pid: observedPID, title: "Live metadata title",
                                                                   generation: "fixture-generation")])
            runtime = try TerminalRuntime(root: root)
            runtime.host = backend
            otherRuntime = try TerminalRuntime(root: root)
            otherRuntime.host = backend
            let ready = root.appendingPathComponent("probe-ready"), release = root.appendingPathComponent("probe-release")
            backend.listHook = {
                _ = FileManager.default.createFile(atPath: ready.path, contents: Data())
                let deadline = Date().addingTimeInterval(8)
                while !FileManager.default.fileExists(atPath: release.path) {
                    guard Date() < deadline else { throw TerminalError.runtime("Fake pane listing was never released") }
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            binding = TerminalInputBinding(paneID: paneID, backendPID: 900001,
                generation: UUID().uuidString.lowercased(), providerPID: 900003)
            originalFontSize = try runtime.state().settings.fontSize
            try runtime.update { state in
                state.sessions = [TerminalSession(id: paneID, title: "Stored title", cwd: "/tmp", pid: binding.backendPID)]
                var launch = AgentLaunch(paneID: paneID, provider: .claude, providerSessionID: "fixture-conversation",
                    cwd: "/tmp", accountID: nil, configurationRoot: "/tmp/fixture", bootID: "fixture")
                launch.id = binding.generation
                launch.providerPID = binding.providerPID
                state.agentLaunches = [launch]
            }
        }

        func waitForProbe() -> Bool {
            let deadline = Date().addingTimeInterval(3)
            while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            return FileManager.default.fileExists(atPath: ready.path)
        }

        func releaseProbe() { _ = FileManager.default.createFile(atPath: release.path, contents: Data()) }
        func cleanup() {
            XCTAssertFalse(backend.calls.contains { $0.hasPrefix("create") || $0.hasPrefix("respawn") })
            try? FileManager.default.removeItem(at: root)
        }
    }
}
