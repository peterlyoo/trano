import Darwin
import Foundation
import XCTest
@testable import TerminalCore

final class SupervisorFinalAuthorityTests: XCTestCase {
    // Implements: FR-SUP-6, FR-SUP-7
    func testOwnPendingDecisionRevokesCapturedReadyRequestWithoutWriting() throws {
        let fixture = try Fixture()
        let request = try fixture.request()
        fixture.pendingDecisionPaneIDs.insert(fixture.binding.paneID)
        XCTAssertFalse(fixture.pendingDecisionPaneIDs.contains(fixture.targetID))
        try assertRevoked(fixture, request: request)
    }

    // Implements: FR-SUP-6, FR-SUP-7
    func testOwnBlockedStateRevokesCapturedReadyRequestWithoutWriting() throws {
        let fixture = try Fixture()
        let request = try fixture.request()
        fixture.snapshot.sessions[0].activity.state = .blocked
        try assertRevoked(fixture, request: request)
    }

    // Implements: FR-SUP-6, FR-SUP-7
    func testOwnErrorStateRevokesCapturedReadyRequestWithoutWriting() throws {
        let fixture = try Fixture()
        let request = try fixture.request()
        fixture.snapshot.sessions[0].activity.state = .error
        try assertRevoked(fixture, request: request)
    }

    // Implements: FR-SUP-6
    func testCleanSupervisorKeepsSameOfferAndCommitsExactlyOnce() throws {
        let fixture = try Fixture()
        let request = try fixture.request()
        XCTAssertEqual(try fixture.continuationContext().authority, request.authority)
        let result = try fixture.coordinator.continueWork(request)
        XCTAssertEqual(result.paneID, fixture.targetID)
        XCTAssertEqual(fixture.writes, [request.text])
        XCTAssertThrowsError(try fixture.coordinator.continueWork(request))
        XCTAssertEqual(fixture.writes.count, 1)
    }

    private func assertRevoked(_ fixture: Fixture, request: SupervisorContinuationRequest,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let context = try fixture.continuationContext()
        XCTAssertNil(context.authority, file: file, line: line)
        XCTAssertEqual(context.candidates.first?.target, request.offer.target, file: file, line: line)
        XCTAssertEqual(context.candidates.first?.offer(now: fixture.now), request.offer, file: file, line: line)
        XCTAssertThrowsError(try fixture.coordinator.continueWork(request), file: file, line: line)
        XCTAssertTrue(fixture.writes.isEmpty, file: file, line: line)
    }

    private final class Fixture: SupervisorContinuationBackend {
        let now = Date(timeIntervalSince1970: 1000)
        let targetID = UUID().uuidString
        let binding: SupervisorBinding
        var snapshot = RuntimeState()
        var ledger = TerminalInputLedger()
        var pendingDecisionPaneIDs: Set<String> = []
        var processes: [Int32: SupervisorContinuationProcess] = [:]
        var writes: [String] = []
        var coordinator: SupervisorContinuationCoordinator<Fixture> {
            SupervisorContinuationCoordinator(backend: self, now: { self.now })
        }

        init() throws {
            let ownID = UUID().uuidString
            let birth = SupervisorProcessIdentity(pid: 100, ownerUID: getuid(), startedAtSeconds: 900, startedAtMicroseconds: 0)
            binding = SupervisorBinding(paneID: ownID, backendPID: 100,
                configuration: SupervisorConfiguration(provider: .claude, cwd: "/fixture/project"), processIdentity: birth)
            for (paneID, pid) in [(ownID, Int32(100)), (targetID, Int32(200))] {
                var pane = TerminalSession(id: paneID, title: "Fixture", cwd: "/fixture/project", pid: pid)
                pane.agent = .claude
                pane.activity.state = paneID == ownID ? .running : .done
                pane.activity.source = "hook"
                snapshot.sessions.append(pane)
                let launch = AgentLaunch(paneID: paneID, provider: .claude, providerSessionID: UUID().uuidString,
                    cwd: pane.cwd, accountID: nil, configurationRoot: "/fixture/profile", bootID: "fixture-boot",
                    processID: pid, providerPID: pid + 1)
                snapshot.agentLaunches.append(launch)
                let backend = SupervisorProcessIdentity(pid: pid, ownerUID: getuid(), startedAtSeconds: 900, startedAtMicroseconds: 0)
                let provider = SupervisorProcessIdentity(pid: pid + 1, ownerUID: getuid(), startedAtSeconds: 901, startedAtMicroseconds: 0)
                processes[pid] = SupervisorContinuationProcess(identity: backend, parentPID: 1, executable: "/bin/zsh")
                processes[pid + 1] = SupervisorContinuationProcess(identity: provider, parentPID: pid, executable: "/fixture/bin/claude")
                if paneID == targetID {
                    let input = TerminalInputBinding(paneID: paneID, backendPID: pid, generation: launch.id, providerPID: pid + 1)
                    let receipt = try ledger.beginManualWrite(binding: input, submissionCandidate: true, capturedAt: now.addingTimeInterval(-3))
                    ledger.finishWrite(receipt, succeeded: true)
                    XCTAssertTrue(ledger.observeTrustedSubmit(binding: input, originStartedAt: now.addingTimeInterval(-2)))
                    var turn = FollowUpTurn(paneID: paneID, generation: launch.id)
                    turn.completionID = UUID().uuidString
                    turn.completedAt = now.addingTimeInterval(-1)
                    turn.completionOriginPID = 9000
                    turn.providerPID = pid + 1
                    turn.providerIdentity = "901.0:/fixture/bin/claude"
                    snapshot.followUpTurns = [turn]
                    var monitor = AgentSupervision(generation: launch.id)
                    monitor.atTurnBoundary = true
                    snapshot.supervision = [monitor]
                }
            }
        }

        func request() throws -> SupervisorContinuationRequest {
            let context = try continuationContext()
            return SupervisorContinuationRequest(authority: try XCTUnwrap(context.authority),
                offer: try XCTUnwrap(context.candidates.first?.offer(now: now)), text: "Continue the assigned work")
        }
        func transaction<T>(_ body: () throws -> T) throws -> T { try body() }
        func continuationContext() throws -> SupervisorContinuationContext {
            SupervisorContinuationRuntimeProjection.make(snapshot: snapshot, sessions: snapshot.sessions, binding: binding,
                ledger: ledger, pendingDecisionPaneIDs: pendingDecisionPaneIDs, limitedAccountIDs: [], bootID: "fixture-boot",
                now: now, process: { self.processes[$0] }, originExited: { $0 == 9000 })
        }
        func reserveAndCommit(_ request: SupervisorContinuationRequest) throws {
            let receipt = try ledger.beginAutomaticWrite(request.offer.lease)
            writes.append(request.text)
            ledger.finishWrite(receipt, succeeded: true)
            snapshot.followUpTurns[0].consumedCompletionID = request.offer.completionID
        }
        func reviewInput(authority: SupervisorContinuationAuthority, target: SupervisorContinuationIdentity) throws {
            XCTFail("Review is outside this regression")
        }
    }
}
