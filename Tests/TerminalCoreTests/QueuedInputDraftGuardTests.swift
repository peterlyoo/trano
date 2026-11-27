import XCTest
@testable import TerminalCore

private final class InputDeliveryResult: @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    private var failed = false
    func wrote() { lock.lock(); writes += 1; lock.unlock() }
    func completed(_ result: Result<Int, Error>) { lock.lock(); if case .failure = result { failed = true }; lock.unlock() }
    var value: (Int, Bool) { lock.lock(); defer { lock.unlock() }; return (writes, failed) }
}

final class QueuedInputDraftGuardTests: XCTestCase {
    private func fixture() throws -> (TerminalRuntime, TerminalInputBinding, URL) {
        let root = URL(fileURLWithPath: "/tmp/tq-" + String(UUID().uuidString.prefix(12)))
        let runtime = try TerminalRuntime(root: root)
        let paneID = UUID().uuidString.lowercased(); let generation = UUID().uuidString.lowercased()
        let binding = TerminalInputBinding(paneID: paneID, backendPID: 100, generation: generation, providerPID: 200)
        try runtime.update { state in
            state.sessions.append(TerminalSession(id: paneID, title: "Unit", cwd: "/", pid: 100))
            var launch = AgentLaunch(paneID: paneID, provider: .claude, cwd: "/", accountID: nil, configurationRoot: "/private/unit", bootID: "unit")
            launch.id = generation; launch.processID = 150; launch.providerPID = 200; state.agentLaunches.append(launch)
        }
        return (runtime, binding, root)
    }
    private func clean(_ binding: TerminalInputBinding, root: URL) throws -> TerminalInputLease {
        var ledger = TerminalInputLedger()
        let written = try ledger.beginManualWrite(binding: binding, submissionCandidate: true)
        ledger.finishWrite(written, succeeded: true); ledger.observeTrustedSubmit(binding: binding)
        try TerminalInputLedgerStore(root: root).save(ledger)
        return try XCTUnwrap(ledger.readiness(binding: binding).lease)
    }
    // Implements: FR-QUEUE-5
    func testManualDraftTypedWhileWorkingNeverReceivesQueuedPasteOrEnter() throws {
        let (runtime, binding, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let lease = try clean(binding, root: root)
        var ledger = try TerminalInputLedgerStore(root: root).load()
        let draft = try ledger.beginManualWrite(binding: binding); ledger.finishWrite(draft, succeeded: true)
        try TerminalInputLedgerStore(root: root).save(ledger)
        var stream = "user draft"
        XCTAssertThrowsError(try runtime.withTerminalAutomaticInputLease(lease) { stream += "queued input\r" })
        XCTAssertEqual(stream, "user draft")
    }
    // Implements: FR-QUEUE-5
    func testGenerationAndProviderReplacedBetweenReadinessAndCommitNeverWrites() throws {
        let (runtime, binding, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let lease = try clean(binding, root: root)
        try runtime.update { $0.agentLaunches[0].providerPID = 201 }
        var writes = 0
        XCTAssertThrowsError(try runtime.withTerminalAutomaticInputLease(lease) { writes += 1 })
        XCTAssertEqual(writes, 0)
    }
    // Implements: FR-QUEUE-5
    func testCleanDoneFIFOConsumesEachReadinessLeaseExactlyOnce() throws {
        let (runtime, binding, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try clean(binding, root: root)
        var sent: [String] = []
        try runtime.withTerminalAutomaticInputLease(first) { sent.append("one") }
        XCTAssertThrowsError(try runtime.withTerminalAutomaticInputLease(first) { sent.append("two") })
        var ledger = try TerminalInputLedgerStore(root: root).load()
        XCTAssertTrue(ledger.observeTrustedSubmit(binding: binding))
        try TerminalInputLedgerStore(root: root).save(ledger)
        let second = try XCTUnwrap(ledger.readiness(binding: binding).lease)
        try runtime.withTerminalAutomaticInputLease(second) { sent.append("two") }
        XCTAssertEqual(sent, ["one", "two"])
    }
    // Implements: FR-QUEUE-5
    func testAmbiguousPartialDeliveryCannotRetryTheSameLease() throws {
        let (runtime, binding, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let lease = try clean(binding, root: root)
        enum Failed: Error { case partial }
        XCTAssertThrowsError(try runtime.withTerminalAutomaticInputLease(lease) { throw Failed.partial })
        var retried = false
        XCTAssertThrowsError(try runtime.withTerminalAutomaticInputLease(lease) { retried = true })
        XCTAssertFalse(retried)
    }
    // Implements: FR-QUEUE-5
    func testDelayedNativeInputCannotReachReplacementProviderInSameBackendPane() throws {
        let (runtime, binding, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try runtime.update { $0.agentLaunches[0].providerPID = 201 }
        let result = InputDeliveryResult()
        runtime.deliverTerminalInput(paneID: binding.paneID, expectedPID: binding.backendPID, expectedBinding: binding,
            bytes: Array("old draft".utf8), segments: [TerminalUserInputSegment(bytes: Array("old draft".utf8), submissionCandidate: false)],
            write: { _, done in result.wrote(); done(.success(9)) }, completion: { result.completed($0) })
        XCTAssertTrue(result.value.1); XCTAssertEqual(result.value.0, 0)
    }
    // Implements: FR-QUEUE-5
    func testOldRelayInvalidationCannotDirtyNewProviderBinding() throws {
        let (runtime, old, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try runtime.update { $0.agentLaunches[0].providerPID = 201 }
        let replacement = TerminalInputBinding(paneID: old.paneID, backendPID: old.backendPID, generation: old.generation, providerPID: 201)
        let lease = try clean(replacement, root: root)
        XCTAssertThrowsError(try runtime.markTerminalInputUncertain(paneID: old.paneID, expectedPID: old.backendPID, expectedBinding: old))
        XCTAssertEqual(try runtime.terminalInputReadiness(paneID: old.paneID, generation: old.generation).lease, lease)
    }
    // Implements: FR-QUEUE-5
    func testUnknownAPIInputRequiresReviewAndFutureTrustedSubmission() throws {
        let (runtime, binding, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try clean(binding, root: root)
        try runtime.markTerminalInputUncertain(paneID: binding.paneID)
        var ledger = try TerminalInputLedgerStore(root: root).load()
        let ignored = try ledger.beginManualWrite(binding: binding, submissionCandidate: true)
        ledger.finishWrite(ignored, succeeded: true)
        XCTAssertFalse(ledger.observeTrustedSubmit(binding: binding))
        try TerminalInputLedgerStore(root: root).save(ledger)
        XCTAssertEqual(try runtime.terminalInputReadiness(paneID: binding.paneID, generation: binding.generation), .inputReviewRequired)
        try runtime.reviewTerminalInput(paneID: binding.paneID, generation: binding.generation)
        XCTAssertEqual(try runtime.terminalInputReadiness(paneID: binding.paneID, generation: binding.generation), .inputReviewRequired)
        ledger = try TerminalInputLedgerStore(root: root).load()
        let future = try ledger.beginManualWrite(binding: binding, submissionCandidate: true)
        ledger.finishWrite(future, succeeded: true); ledger.observeTrustedSubmit(binding: binding)
        try TerminalInputLedgerStore(root: root).save(ledger)
        XCTAssertNotNil(try runtime.terminalInputReadiness(paneID: binding.paneID, generation: binding.generation).lease)
    }

}
