import AppKit
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class SupervisorTargetActionsTests: XCTestCase {
    // Implements: FR-SUP-6, FR-SUP-7
    @MainActor func testGoToCapturesAuthorityAndTargetAndPublishesBusyBeforeScheduling() {
        let f = fixture()
        f.model.update(authority: f.authority, targets: [f.first, f.second])
        f.model.goToSession()
        XCTAssertTrue(f.model.isBusy)
        XCTAssertEqual(f.scheduler.work.count, 1)
        XCTAssertTrue(f.spy.validated.isEmpty)
        f.model.goToSession()
        XCTAssertEqual(f.scheduler.work.count, 1)
        f.scheduler.runWork()
        XCTAssertEqual(f.spy.validated.map(\.0), [f.authority])
        XCTAssertEqual(f.spy.validated.map(\.1), [f.first.reference!])
        XCTAssertTrue(f.spy.opened.isEmpty)
        f.scheduler.runDelivery()
        XCTAssertEqual(f.spy.opened, [f.first.reference!])
        XCTAssertFalse(f.model.isBusy)
    }

    // Implements: FR-SUP-7
    @MainActor func testReorderKeepsPaneAndGenerationButReplacementDoesNotAdoptANewTarget() {
        let f = fixture()
        f.model.update(authority: f.authority, targets: [f.first, f.second])
        let key = SupervisorTargetSelection(f.first)
        f.model.update(authority: f.authority, targets: [f.second, f.first])
        XCTAssertEqual(f.model.selection, key)
        let replacement = target(paneID: f.first.paneID, generation: "replacement")
        f.model.update(authority: f.authority, targets: [f.second, replacement])
        XCTAssertNil(f.model.selection)
        f.model.goToSession()
        XCTAssertTrue(f.scheduler.work.isEmpty)
    }

    // Implements: FR-SUP-6, FR-SUP-7
    @MainActor func testSelectionOrAuthorityChangesBeforeWorkerRunRevokeTheCapturedAction() {
        for change in 0..<3 {
            let f = fixture()
            f.model.update(authority: f.authority, targets: [f.first, f.second])
            f.model.reviewInput()
            if change == 0 { f.model.select(SupervisorTargetSelection(f.second)) }
            else if change == 1 { f.model.update(authority: authority(generation: "new-supervisor"), targets: [f.first, f.second]) }
            else { f.model.update(authority: f.authority, targets: [target(paneID: f.first.paneID, generation: "first", pid: 909), f.second]) }
            f.scheduler.runWork(); f.scheduler.runDelivery()
            XCTAssertTrue(f.spy.validated.isEmpty)
            XCTAssertTrue(f.spy.reviewed.isEmpty)
            XCTAssertTrue(f.spy.opened.isEmpty)
            XCTAssertFalse(f.model.isBusy)
        }
    }

    // Implements: FR-SUP-7
    @MainActor func testASelectionChangeAfterValidationCannotNavigateToTheUpdatedSelection() {
        let f = fixture()
        f.model.update(authority: f.authority, targets: [f.first, f.second])
        f.model.goToSession()
        f.scheduler.runWork()
        f.model.select(SupervisorTargetSelection(f.second))
        f.scheduler.runDelivery()
        XCTAssertEqual(f.spy.validated.map(\.1), [f.first.reference!])
        XCTAssertTrue(f.spy.opened.isEmpty)
        XCTAssertFalse(f.model.isBusy)
    }

    // Implements: FR-SUP-7
    @MainActor func testCapturedOwnerInvalidationOrPanelCancellationPreventsNavigation() {
        for cancel in [false, true] {
            let f = fixture()
            f.model.update(authority: f.authority, targets: [f.first])
            f.model.goToSession()
            f.scheduler.runWork()
            if cancel { f.model.cancel() } else { f.spy.ownerCurrent = false }
            f.scheduler.runDelivery()
            XCTAssertTrue(f.spy.opened.isEmpty)
            XCTAssertFalse(f.model.isBusy)
        }
    }

    // Implements: FR-SUP-6, FR-SUP-7
    @MainActor func testReviewRecordsUnknownAndNeverPromotesThePreviousReadySummary() {
        let f = fixture()
        f.model.update(authority: f.authority, targets: [f.first])
        XCTAssertEqual(f.model.readiness, .ready)
        f.model.reviewInput()
        XCTAssertTrue(f.model.isBusy)
        f.scheduler.drain()
        XCTAssertEqual(f.spy.reviewed.map(\.0), [f.authority])
        XCTAssertEqual(f.spy.reviewed.map(\.1), [f.first.reference!])
        XCTAssertEqual(f.model.readiness, .inputReviewRequired)
        XCTAssertEqual(f.spy.refreshCount, 1)
        f.model.update(authority: f.authority, targets: [f.first])
        XCTAssertEqual(f.model.readiness, .inputReviewRequired)
        XCTAssertTrue(f.spy.opened.isEmpty)
    }

    // Implements: FR-SUP-6, FR-SUP-7
    @MainActor func testValidationFailureDoesNotReviewOrNavigateAndAllowsRetry() {
        let f = fixture()
        f.model.update(authority: f.authority, targets: [f.first])
        f.spy.failValidation = true
        f.model.reviewInput()
        f.scheduler.drain()
        XCTAssertFalse(f.model.isBusy)
        XCTAssertNotNil(f.model.errorMessage)
        XCTAssertTrue(f.spy.reviewed.isEmpty)
        XCTAssertTrue(f.spy.opened.isEmpty)
        f.spy.failValidation = false
        f.model.reviewInput()
        f.scheduler.drain()
        XCTAssertEqual(f.spy.reviewed.count, 1)
        XCTAssertNil(f.model.errorMessage)
    }

    // Implements: FR-SUP-7
    @MainActor func testOwnerIsRecheckedBetweenValidationAndReviewMutation() {
        let f = fixture()
        f.model.update(authority: f.authority, targets: [f.first])
        f.model.reviewInput(); f.scheduler.runWork()
        f.spy.ownerCurrent = false
        f.scheduler.runDelivery(); f.scheduler.drain()
        XCTAssertEqual(f.spy.validated.count, 1)
        XCTAssertTrue(f.spy.reviewed.isEmpty)
        XCTAssertFalse(f.model.isBusy)
    }

    // Implements: FR-SUP-7
    @MainActor func testCancellationBeforeTheReviewWorkerDoesNotMutateAnySession() {
        let f = fixture()
        f.model.update(authority: f.authority, targets: [f.first])
        f.model.reviewInput(); f.scheduler.runWork(); f.scheduler.runDelivery()
        f.model.cancel(); f.scheduler.drain()
        XCTAssertTrue(f.spy.reviewed.isEmpty)
        XCTAssertFalse(f.model.isBusy)
    }

    // Implements: FR-SUP-6, FR-SUP-7
    @MainActor func testFailedReviewRemainsUnknownAndRefreshesReadinessWithoutNavigating() {
        let f = fixture()
        f.model.update(authority: f.authority, targets: [f.first])
        f.spy.failReview = true
        f.model.reviewInput(); f.scheduler.drain()
        XCTAssertNotNil(f.model.errorMessage)
        XCTAssertEqual(f.model.readiness, .inputReviewRequired)
        XCTAssertEqual(f.spy.refreshCount, 1)
        XCTAssertTrue(f.spy.opened.isEmpty)
    }

    // Implements: FR-SUP-7
    @MainActor func testMissingNativeOwnerHasAnExplicitReasonAndDoesNotScheduleWork() {
        let f = fixture()
        f.model.update(authority: f.authority, targets: [f.first])
        f.spy.ownerAvailable = false
        f.model.goToSession()
        XCTAssertNotNil(f.model.errorMessage)
        XCTAssertTrue(f.scheduler.work.isEmpty)
    }

    // Implements: FR-SUP-7
    @MainActor func testReviewBarrierRequiresAnUnknownObservationThenANewerCoreRevision() {
        let f = fixture()
        f.model.update(authority: f.authority, targets: [f.first])
        f.model.reviewInput(); f.scheduler.drain()
        let unknown = target(paneID: "first", generation: "first", readiness: "input_review_required", revision: nil)
        f.model.update(authority: f.authority, targets: [unknown])
        f.model.update(authority: f.authority, targets: [f.first])
        XCTAssertEqual(f.model.readiness, .inputReviewRequired)
        let later = target(paneID: "first", generation: "first", revision: 8)
        f.model.update(authority: f.authority, targets: [later])
        XCTAssertEqual(f.model.readiness, .ready)
    }

    // Implements: FR-SUP-7
    @MainActor func testPassiveRefreshOnAnotherSelectionCannotDiscardTheReviewedTargetsUnknownBarrier() {
        let f = fixture()
        f.model.update(authority: f.authority, targets: [f.first, f.second])
        f.model.reviewInput(); f.scheduler.drain()
        f.model.select(SupervisorTargetSelection(f.second))
        f.model.update(authority: f.authority, targets: [f.second, f.first])
        f.model.select(SupervisorTargetSelection(f.first))
        XCTAssertEqual(f.model.readiness, .inputReviewRequired)
    }

    // Implements: FR-SUP-7
    @MainActor func testMissingOrAmbiguousIdentityAndPanelBusyHaveExplicitDisabledReasons() {
        let f = fixture()
        for (owner, rows, busy) in [(nil, [f.first], false), (f.authority, [target(paneID: "missing", generation: "first", reference: false)], false),
            (f.authority, [f.first, f.first], false), (f.authority, [f.first], true)] {
            f.model.update(authority: owner, targets: rows, panelBusy: busy)
            XCTAssertNotNil(f.model.disabledReason)
            f.model.reviewInput()
            XCTAssertTrue(f.scheduler.work.isEmpty)
        }
    }

    // Implements: FR-SUP-7
    @MainActor func testNativeControlsFitAndTheirOwnActionsEnterTheGuardedModel() throws {
        _ = NSApplication.shared
        let f = fixture()
        let view = SupervisorTargetActionsView(model: f.model)
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 104)
        f.model.update(authority: f.authority, targets: [f.first, f.second])
        view.layoutSubtreeIfNeeded()
        for id in ["supervisor-target-picker", "supervisor-target-go", "supervisor-target-review", "supervisor-target-state"] {
            let child = try XCTUnwrap(find(id, in: view))
            XCTAssertTrue(view.bounds.insetBy(dx: -1, dy: -1).contains(child.convert(child.bounds, to: view)), id)
        }
        let button = try XCTUnwrap(find("supervisor-target-review", in: view) as? NSButton)
        button.performClick(nil)
        XCTAssertTrue(f.model.isBusy)
        XCTAssertFalse(button.isEnabled)
        XCTAssertTrue(f.spy.reviewed.isEmpty)
        f.scheduler.drain()
        XCTAssertEqual(f.spy.reviewed.count, 1)
    }

    private struct Fixture {
        let model: SupervisorTargetActionsModel; let scheduler: Scheduler; let spy: Spy
        let authority: SupervisorContinuationAuthority; let first: SupervisorTarget; let second: SupervisorTarget
    }
    @MainActor private func fixture() -> Fixture {
        let spy = Spy(), scheduler = Scheduler()
        let services = SupervisorTargetActionServices(validateTarget: { try spy.validate($0, $1) },
            reviewInput: { try spy.review($0, $1) }, captureOwner: { _, _ in
                guard spy.ownerAvailable else { return nil }
                return SupervisorTargetActionOwner(isCurrent: { spy.ownerCurrent }, goToSession: { spy.opened.append($0) })
            }, didReview: { spy.refreshCount += 1 })
        return Fixture(model: SupervisorTargetActionsModel(services: services, scheduler: scheduler), scheduler: scheduler,
            spy: spy, authority: authority(), first: target(paneID: "first", generation: "first"), second: target(paneID: "second", generation: "second"))
    }
    @MainActor private func find(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        for child in view.subviews { if let match = find(id, in: child) { return match } }
        return nil
    }
    private func identity(paneID: String, generation: String, pid: Int32 = 100) -> SupervisorContinuationIdentity {
        let backend = SupervisorProcessIdentity(pid: pid, ownerUID: 501, startedAtSeconds: 1, startedAtMicroseconds: 1)
        let provider = SupervisorProcessIdentity(pid: pid + 100, ownerUID: 501, startedAtSeconds: 2, startedAtMicroseconds: 1)
        return SupervisorContinuationIdentity(paneID: paneID, backendPID: pid, backendIdentity: backend, generation: generation,
            provider: .claude, providerPID: pid + 100, providerIdentity: provider, providerSessionID: "provider-" + generation,
            configurationRoot: "/tmp/fixture-claude", cwd: "/tmp/fixture", providerExecutable: "/synthetic/bin/claude")
    }
    private func authority(generation: String = "supervisor") -> SupervisorContinuationAuthority {
        let launch = identity(paneID: "supervisor", generation: generation, pid: 500)
        return SupervisorContinuationAuthority(binding: SupervisorBinding(paneID: launch.paneID, backendPID: launch.backendPID,
            configuration: SupervisorConfiguration(provider: .claude, cwd: "/tmp/fixture"), createdAt: Date(timeIntervalSince1970: 1),
            processIdentity: launch.backendIdentity), launch: launch)
    }
    private func target(paneID: String, generation: String, pid: Int32 = 100, reference: Bool = true,
                        readiness: String = "ready", revision: UInt64? = 7) -> SupervisorTarget {
        let identity = identity(paneID: paneID, generation: generation, pid: pid)
        var data: [String: Any] = ["paneID": paneID, "backendPID": pid, "alive": true, "title": paneID,
            "provider": "claude", "activity": "done", "generation": generation, "pendingDecision": false,
            "quotaLimited": false, "continuation": "input_review_required"]
        var summary: [String: Any] = ["state": readiness]
        if let revision { summary["revision"] = revision }
        data["inputReadiness"] = summary
        if reference { data["reference"] = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)) }
        return try! JSONDecoder().decode(SupervisorTarget.self, from: JSONSerialization.data(withJSONObject: data))
    }
}

private final class Spy: @unchecked Sendable {
    var validated: [(SupervisorContinuationAuthority, SupervisorContinuationIdentity)] = []
    var reviewed: [(SupervisorContinuationAuthority, SupervisorContinuationIdentity)] = []
    var opened: [SupervisorContinuationIdentity] = []
    var ownerCurrent = true, ownerAvailable = true, failValidation = false, failReview = false
    var refreshCount = 0
    func validate(_ a: SupervisorContinuationAuthority, _ t: SupervisorContinuationIdentity) throws {
        validated.append((a, t)); if failValidation { throw TerminalError.invalid("Stale fixture") }
    }
    func review(_ a: SupervisorContinuationAuthority, _ t: SupervisorContinuationIdentity) throws {
        reviewed.append((a, t)); if failReview { throw TerminalError.invalid("Fixture review unavailable") }
    }
}
private final class Scheduler: SupervisorPanelScheduling, @unchecked Sendable {
    var work: [@Sendable () -> Void] = []
    var delivery: [@MainActor @Sendable () -> Void] = []
    func schedule(_ work: @escaping @Sendable () -> Void) { self.work.append(work) }
    func deliver(_ work: @escaping @MainActor @Sendable () -> Void) { delivery.append(work) }
    func runWork() { let pending = work; work = []; pending.forEach { $0() } }
    @MainActor func runDelivery() { let pending = delivery; delivery = []; pending.forEach { $0() } }
    @MainActor func drain() {
        for _ in 0..<10 {
            if work.isEmpty && delivery.isEmpty { return }
            runWork(); runDelivery()
        }
        XCTFail("Fake action did not settle")
    }
}
