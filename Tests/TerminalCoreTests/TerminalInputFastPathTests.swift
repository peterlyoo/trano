import XCTest
import Darwin
@testable import TerminalCore

private final class Delivery: @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0, failures = 0, completions = 0
    func wrote() { lock.lock(); writes += 1; lock.unlock() }
    func completed(_ result: Result<Int, Error>) {
        lock.lock(); completions += 1; if case .failure = result { failures += 1 }; lock.unlock()
    }
    var value: (writes: Int, failures: Int, completions: Int) { lock.lock(); defer { lock.unlock() }; return (writes, failures, completions) }
}

final class TerminalInputFastPathTests: XCTestCase {
    private func fixture() throws -> (TerminalRuntime, TerminalInputBinding, URL) {
        let root = URL(fileURLWithPath: "/tmp/tf-" + String(UUID().uuidString.prefix(12)))
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

    private func makeReady(_ binding: TerminalInputBinding, root: URL) throws {
        let store = TerminalInputLedgerStore(root: root)
        var ledger = try store.load()
        let written = try ledger.beginManualWrite(binding: binding, submissionCandidate: true)
        ledger.finishWrite(written, succeeded: true)
        while ledger.readiness(binding: binding).lease == nil { XCTAssertTrue(ledger.observeTrustedSubmit(binding: binding)) }
        try store.save(ledger)
    }

    private func type(_ runtime: TerminalRuntime, _ binding: TerminalInputBinding, _ text: String, into result: Delivery,
                      submit: Bool = false, during: @escaping @Sendable () -> Void = {}) {
        let bytes = Array(text.utf8)
        runtime.deliverTerminalInput(paneID: binding.paneID, expectedPID: binding.backendPID, expectedBinding: binding, bytes: bytes,
            segments: [TerminalUserInputSegment(bytes: bytes, submissionCandidate: submit)],
            write: { sent, done in result.wrote(); during(); done(.success(sent.count)) }, completion: { result.completed($0) })
    }

    private func ledgerInode(_ root: URL) -> UInt64 {
        var info = stat()
        XCTAssertEqual(lstat(root.appendingPathComponent("input-state/terminal-input.json").path, &info), 0)
        return UInt64(info.st_ino)
    }

    // Implements: FR-INPUT-2
    func testTypingAfterTheFirstKeyNeitherWaitsForTheRuntimeLockNorRewritesTheLedger() throws {
        let (runtime, binding, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try makeReady(binding, root: root)
        let result = Delivery()
        type(runtime, binding, "한", into: result)
        XCTAssertNil(try runtime.terminalInputReadiness(paneID: binding.paneID, generation: binding.generation).lease)
        let inode = ledgerInode(root)
        // Another process holding the runtime lock must not delay a keystroke.
        let other = open(root.appendingPathComponent("state.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(other, 0); XCTAssertEqual(flock(other, LOCK_EX), 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { self.type(runtime, binding, "글", into: result); finished.signal() }
        let outcome = finished.wait(timeout: .now() + 5)
        _ = flock(other, LOCK_UN); close(other)
        XCTAssertEqual(outcome, .success, "A plain keystroke waited for the shared runtime lock")
        XCTAssertEqual(result.value.writes, 2); XCTAssertEqual(result.value.failures, 0); XCTAssertEqual(result.value.completions, 2)
        XCTAssertEqual(ledgerInode(root), inode)
        XCTAssertNil(try runtime.terminalInputReadiness(paneID: binding.paneID, generation: binding.generation).lease)
    }

    // Implements: FR-INPUT-2
    func testKeystrokeRacingAnAutomaticInputLeaseStillInvalidatesIt() throws {
        let (runtime, binding, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try makeReady(binding, root: root)
        let result = Delivery()
        type(runtime, binding, "a", into: result)
        type(runtime, binding, "b", into: result, during: { try? self.makeReady(binding, root: root) })
        XCTAssertEqual(result.value.writes, 2); XCTAssertEqual(result.value.failures, 0)
        XCTAssertNil(try runtime.terminalInputReadiness(paneID: binding.paneID, generation: binding.generation).lease)
    }

    // Implements: FR-INPUT-2
    func testSubmissionAndFirstKeyAfterItStillReachTheLedger() throws {
        let (runtime, binding, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try makeReady(binding, root: root)
        let result = Delivery()
        type(runtime, binding, "a", into: result); type(runtime, binding, "b", into: result)
        type(runtime, binding, "\r", into: result, submit: true)
        var ledger = try TerminalInputLedgerStore(root: root).load()
        XCTAssertTrue(ledger.observeTrustedSubmit(binding: binding))
        try TerminalInputLedgerStore(root: root).save(ledger)
        XCTAssertNotNil(try runtime.terminalInputReadiness(paneID: binding.paneID, generation: binding.generation).lease)
        type(runtime, binding, "c", into: result)
        XCTAssertEqual(result.value.failures, 0)
        XCTAssertNil(try runtime.terminalInputReadiness(paneID: binding.paneID, generation: binding.generation).lease)
    }

    // Implements: FR-INPUT-2
    func testKeystrokeForAReplacedProviderIsNotWritten() throws {
        let (runtime, binding, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try makeReady(binding, root: root)
        let result = Delivery()
        type(runtime, binding, "a", into: result); type(runtime, binding, "b", into: result)
        try runtime.update { $0.agentLaunches[0].providerPID = 201 }
        type(runtime, binding, "c", into: result)
        XCTAssertEqual(result.value.writes, 2); XCTAssertEqual(result.value.failures, 1)
    }
}
