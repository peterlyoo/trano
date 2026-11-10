import XCTest
@testable import TranoCLI
@testable import TerminalCore

final class ProviderSignalTests: XCTestCase {
    func testEndingAnAttemptConsumesItsInterrupt() {
        let relay = ProviderSignalRelay()
        relay.send(SIGINT)
        XCTAssertEqual(relay.stop(), SIGINT)
        XCTAssertNil(relay.lastSignalValue, "A completed attempt must not interrupt the next provider")
        XCTAssertFalse(relay.wasInterrupted)
    }

    func testInterruptBetweenAttemptsRemainsPending() {
        let relay = ProviderSignalRelay()
        XCTAssertNil(relay.stop())
        relay.send(SIGINT)
        XCTAssertEqual(relay.lastSignalValue, SIGINT)
        XCTAssertTrue(relay.wasInterrupted)
    }

    func testOnlyANewerSafeBoundaryClearsSurvivingTurnCancellation() {
        let relay = ProviderSignalRelay()
        relay.setPID(.max)
        relay.observeBoundary(revision: 4, safe: true)
        relay.send(SIGINT)
        relay.observeBoundary(revision: 4, safe: true)
        XCTAssertTrue(relay.wasInterrupted)
        relay.observeBoundary(revision: 5, safe: false)
        XCTAssertTrue(relay.wasInterrupted)
        relay.observeBoundary(revision: 5, safe: true)
        XCTAssertFalse(relay.wasInterrupted)
        XCTAssertNil(relay.stop())
    }

    func testTerminationCannotBeClearedOrDowngradedByTurnCancellation() {
        let relay = ProviderSignalRelay()
        relay.setPID(.max)
        relay.send(SIGTERM)
        relay.send(SIGINT)
        relay.observeBoundary(revision: 1, safe: true)
        XCTAssertEqual(relay.stop(), SIGTERM)
        XCTAssertEqual(relay.stoppedSignalValue, SIGTERM)
    }

    func testMissingTerminalDoesNotRequireForegroundOwnership() {
        let terminal = ProviderTerminalControl(descriptor: -1)
        XCTAssertNoThrow(try terminal.give(to: getpgrp()))
        terminal.restore()
    }

    func testTransferConfirmationRequiresTargetMappingAndVerifiedGeneration() {
        let source = AgentLaunch(paneID: "pane", provider: .claude, providerSessionID: "conversation", cwd: "/tmp", accountID: "source", configurationRoot: "/tmp/source", bootID: "boot")
        let plan = AccountSwitchPlan(id: "plan", paneID: "pane", provider: .claude, expectedGeneration: source.id, providerPID: nil, sourceAccountID: "source", targetAccountID: "target", providerSessionID: "conversation", cwd: "/tmp", sourceRoot: "/tmp/source", targetRoot: "/tmp/target", files: [], createdAt: Date())
        let receipt = AccountTransferReceipt(id: "plan", planID: "plan", targetAccountID: "target", files: [])
        let transfer = PendingAccountTransfer(plan: plan, receipt: receipt, source: source)
        let target = AgentLaunch(paneID: "pane", provider: .claude, providerSessionID: "conversation", cwd: "/tmp", accountID: "target", configurationRoot: "/tmp/target", bootID: "boot")
        var state = RuntimeState()
        state.agentLaunches = [target]
        var monitor = AgentSupervision(generation: source.id)
        monitor.startedSessionID = "conversation"
        state.supervision = [monitor]
        XCTAssertFalse(transfer.isConfirmed(in: state))
        monitor = AgentSupervision(generation: target.id)
        monitor.startedSessionID = "conversation"
        state.supervision = [monitor]
        XCTAssertTrue(transfer.isConfirmed(in: state))
        state.agentLaunches = [source]
        XCTAssertFalse(transfer.isConfirmed(in: state))
    }
}
