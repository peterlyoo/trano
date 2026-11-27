import AppKit
import XCTest
@testable import TerminalCore
@testable import TranoApp

@MainActor final class SupervisorTargetCurrentGuardTests: XCTestCase {
    // Implements: FR-SUP-6, FR-SUP-7
    func testExactDropdownTargetAndAuthorityStayRequiredAfterActionDelivery() {
        let reference = identity(), own = identity()
        let authority = SupervisorContinuationAuthority(binding: SupervisorBinding(paneID: own.paneID, backendPID: own.backendPID,
            configuration: SupervisorConfiguration(provider: .claude, cwd: own.cwd), createdAt: Date(), processIdentity: own.backendIdentity), launch: own)
        var first = SupervisorTarget(paneID: reference.paneID, backendPID: reference.backendPID, alive: true, title: "First",
            provider: reference.provider, activity: .done, generation: reference.generation, pendingDecision: false,
            quotaLimited: false, continuation: .inputReviewRequired)
        first.reference = reference
        var second = first
        second.reference = identity()
        let services = SupervisorTargetActionServices(validateTarget: { _, _ in }, reviewInput: { _, _ in }, captureOwner: { _, _ in nil })
        let model = SupervisorTargetActionsModel(services: services, scheduler: Scheduler())
        model.update(authority: authority, targets: [first])
        XCTAssertTrue(model.navigationIsCurrent(authority: authority, target: reference))
        model.update(authority: authority, targets: [second])
        XCTAssertFalse(model.navigationIsCurrent(authority: authority, target: reference))
        model.update(authority: authority, targets: [first])
        XCTAssertTrue(model.navigationIsCurrent(authority: authority, target: reference))
        model.select(nil)
        XCTAssertFalse(model.navigationIsCurrent(authority: authority, target: reference))
        model.select(SupervisorTargetSelection(first))
        model.update(authority: nil, targets: [first])
        XCTAssertFalse(model.navigationIsCurrent(authority: authority, target: reference))
    }
    private struct Scheduler: SupervisorPanelScheduling {
        func schedule(_ work: @escaping @Sendable () -> Void) {}
        func deliver(_ work: @escaping @MainActor @Sendable () -> Void) {}
    }
    private func identity() -> SupervisorContinuationIdentity {
        SupervisorContinuationIdentity(paneID: UUID().uuidString.lowercased(), backendPID: 4711,
            backendIdentity: SupervisorProcessIdentity(pid: 4711, ownerUID: getuid(), startedAtSeconds: 1, startedAtMicroseconds: 1),
            generation: UUID().uuidString.lowercased(), provider: .claude, providerPID: 4712,
            providerIdentity: SupervisorProcessIdentity(pid: 4712, ownerUID: getuid(), startedAtSeconds: 2, startedAtMicroseconds: 1),
            providerSessionID: UUID().uuidString.lowercased(), configurationRoot: "/fixture/profile", cwd: "/fixture/project", providerExecutable: "/fixture/claude")
    }
}
