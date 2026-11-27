import AppKit
import SwiftTerm
import XCTest
@testable import TerminalCore

private final class NativeInputGuardProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[UInt8]] = []
    func record(_ bytes: [UInt8]) { lock.lock(); values.append(bytes); lock.unlock() }
    var bytes: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return values }
}

final class QueuedInputNativeTransportTests: XCTestCase {
    private func fixture() throws -> (TerminalRuntime, TerminalInputBinding, TerminalInputLease, URL) {
        let root = URL(fileURLWithPath: "/tmp/tn-" + String(UUID().uuidString.prefix(12)))
        let runtime = try TerminalRuntime(root: root)
        let binding = TerminalInputBinding(paneID: UUID().uuidString.lowercased(), backendPID: 100,
            generation: UUID().uuidString.lowercased(), providerPID: 200)
        try runtime.update { state in
            state.sessions.append(TerminalSession(id: binding.paneID, title: "Unit", cwd: "/", pid: 100))
            var launch = AgentLaunch(paneID: binding.paneID, provider: .claude, cwd: "/", accountID: nil,
                configurationRoot: "/private/unit", bootID: "unit")
            launch.id = binding.generation; launch.providerPID = 200; launch.processID = 150; state.agentLaunches.append(launch)
        }
        var ledger = TerminalInputLedger()
        let receipt = try ledger.beginManualWrite(binding: binding, submissionCandidate: true)
        ledger.finishWrite(receipt, succeeded: true); ledger.observeTrustedSubmit(binding: binding)
        try TerminalInputLedgerStore(root: root).save(ledger)
        return (runtime, binding, try XCTUnwrap(ledger.readiness(binding: binding).lease), root)
    }

    @MainActor private func bind(_ runtime: TerminalRuntime, _ binding: TerminalInputBinding, probe: NativeInputGuardProbe) -> (LocalProcessTerminalView, TerminalInputRelay) {
        _ = NSApplication.shared
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        let relay = TerminalInputRelay(deliver: { bytes, segments, _, completion in
            runtime.deliverTerminalInput(paneID: binding.paneID, expectedPID: binding.backendPID, bytes: bytes,
                segments: segments, write: { bytes, done in
                    XCTAssertFalse(Thread.isMainThread)
                    XCTAssertEqual(try? runtime.terminalInputReadiness(paneID: binding.paneID, generation: binding.generation), .inputInFlight)
                    done(.success(bytes.count)); probe.record(bytes)
                }, completion: completion)
        }, invalidated: { _ in })
        view.setProcessInputHandler { bytes, origin, write in
            let user: Bool
            switch origin { case .user: user = true; case .response: user = false }
            relay.send(bytes, user: user) { bytes, done in write(bytes) { done($0.mapError { $0 as Error }) } }
        }
        return (view, relay)
    }

    @MainActor private func waitForInput(_ probe: NativeInputGuardProbe) async throws {
        let deadline = Date().addingTimeInterval(2)
        while probe.bytes.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(probe.bytes.isEmpty)
    }

    // Implements: FR-QUEUE-5
    @MainActor func testNativeManualDraftAfterQueueReadinessNeverReceivesPasteOrEnter() async throws {
        let (runtime, binding, lease, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = NativeInputGuardProbe(); let (view, relay) = bind(runtime, binding, probe: probe)
        view.send(txt: "manual draft")
        try await waitForInput(probe)
        var queuedWrites = 0
        XCTAssertThrowsError(try runtime.withTerminalAutomaticInputLease(lease) { queuedWrites += 1 })
        XCTAssertEqual(queuedWrites, 0)
        XCTAssertEqual(probe.bytes, [Array("manual draft".utf8)])
        withExtendedLifetime((view, relay)) {}
    }

    // Implements: FR-QUEUE-5
    @MainActor func testNativeIMEPreeditKeepsLeaseAndCommitInvalidatesItBeforeBytes() async throws {
        let (runtime, binding, lease, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = NativeInputGuardProbe(); let (view, relay) = bind(runtime, binding, probe: probe)
        view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(try runtime.terminalInputReadiness(paneID: binding.paneID, generation: binding.generation).lease, lease)
        XCTAssertTrue(probe.bytes.isEmpty)
        view.insertText("한글", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await waitForInput(probe)
        XCTAssertEqual(try runtime.terminalInputReadiness(paneID: binding.paneID, generation: binding.generation), .inputReviewRequired)
        XCTAssertEqual(probe.bytes, [Array("한글".utf8)])
        withExtendedLifetime((view, relay)) {}
    }

    // Implements: FR-QUEUE-5
    @MainActor func testParserReplyPreservesUserInputRevisionAndReadiness() async throws {
        let (runtime, binding, lease, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = NativeInputGuardProbe(); let (view, relay) = bind(runtime, binding, probe: probe)
        view.feed(text: "\u{1b}[5n")
        try await waitForInput(probe)
        XCTAssertEqual(probe.bytes, [Array("\u{1b}[0n".utf8)])
        XCTAssertEqual(try runtime.terminalInputReadiness(paneID: binding.paneID, generation: binding.generation).lease, lease)
        withExtendedLifetime((view, relay)) {}
    }
}
