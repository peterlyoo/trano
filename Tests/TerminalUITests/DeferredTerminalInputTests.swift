import AppKit
import XCTest
@testable import TranoApp

@MainActor final class DeferredTerminalInputTests: XCTestCase {
    private let store = NSObject(), renderer = NSObject(), window = NSObject(), other = NSObject(), sheet = NSObject()
    private func identity(pid: Int32 = 42, host: String? = nil, remote: String? = nil, generation: UUID = UUID()) -> DeferredTerminalInputIdentity {
        DeferredTerminalInputIdentity(owner: TerminalInteractionOwner(paneID: "pane", windowID: ObjectIdentifier(window), generation: generation),
            storeID: ObjectIdentifier(store), rendererID: ObjectIdentifier(renderer), clientPID: 81, backendPID: pid, hostID: host, remoteSessionID: remote)
    }
    private func fixture() -> (DeferredTerminalInputAttempt, DeferredTerminalInputState) {
        let id = identity()
        return (DeferredTerminalInputAttempt(identity: id, lease: TerminalInteractionLease(owner: id.owner, sessionPID: id.backendPID, hostID: id.hostID)),
                DeferredTerminalInputState(identity: id, focusedPaneID: id.owner.paneID, keyWindowID: id.owner.windowID))
    }
    func testSameOwnerCommitsOnceAndDoesNotReplayInput() {
        let (attempt, state) = fixture(); var writes = 0
        XCTAssertTrue(attempt.commit(current: { state }, insert: { writes += 1 }))
        XCTAssertFalse(attempt.commit(current: { state }, insert: { writes += 1 }))
        XCTAssertEqual(writes, 1)
    }
    func testBackendHostRemoteSessionRendererAndGenerationChangesRejectTheOriginalIntent() {
        let (attempt, state) = fixture()
        let id = state.identity
        let changed = [identity(pid: 43, generation: id.owner.generation), identity(host: "new-host", remote: "remote", generation: id.owner.generation),
            identity(remote: "new-remote", generation: id.owner.generation), identity(),
            DeferredTerminalInputIdentity(owner: id.owner, storeID: id.storeID, rendererID: ObjectIdentifier(other), clientPID: id.clientPID, backendPID: id.backendPID, hostID: nil, remoteSessionID: nil),
            DeferredTerminalInputIdentity(owner: id.owner, storeID: ObjectIdentifier(other), rendererID: id.rendererID, clientPID: id.clientPID, backendPID: id.backendPID, hostID: nil, remoteSessionID: nil),
            DeferredTerminalInputIdentity(owner: id.owner, storeID: id.storeID, rendererID: id.rendererID, clientPID: 82, backendPID: id.backendPID, hostID: nil, remoteSessionID: nil)]
        for value in changed {
            var current = state; current.identity = value
            XCTAssertEqual(attempt.readiness(current), .cancelled)
            XCTAssertFalse(attempt.commit(current: { current }, insert: { XCTFail("Rerouted stale input") }))
        }
    }
    func testNativeFocusVisibilityModalIMEAndNewPresentationEachPreventInsertion() {
        let mutations: [(inout DeferredTerminalInputState) -> Void] = [
            { $0.focusedPaneID = "another" }, { $0.visible = false }, { $0.appActive = false },
            { $0.keyWindowID = ObjectIdentifier(self.other) }, { $0.terminalIsFirstResponder = false },
            { $0.attachedSheetID = ObjectIdentifier(self.other) }, { $0.modalWindowID = ObjectIdentifier(self.other) },
            { $0.markedText = true }, { $0.inputProtected = true }, { $0.intentCurrent = false }
        ]
        for mutate in mutations {
            let (attempt, initial) = fixture(); var state = initial; mutate(&state)
            XCTAssertEqual(attempt.readiness(state), .cancelled)
            XCTAssertFalse(attempt.commit(current: { state }, insert: { XCTFail("Protected input received insertion") }))
        }
    }
    func testLeaseInvalidatedByLateNativeStateReadCannotCommit() {
        let (attempt, state) = fixture()
        XCTAssertFalse(attempt.commit(current: { attempt.lease.invalidate(); return state }, insert: { XCTFail("Invalidated during final read") }))
    }
    func testOnlyTheExactClosingVoiceSheetCanWaitAndAReplacementSheetCancels() {
        let (attempt, initial) = fixture(); var state = initial
        state.attachedSheetID = ObjectIdentifier(sheet); state.keyWindowID = ObjectIdentifier(sheet); state.terminalIsFirstResponder = false
        XCTAssertEqual(attempt.readiness(state, closingSheetID: ObjectIdentifier(sheet)), .closingPresentation)
        XCTAssertEqual(attempt.readiness(state), .cancelled)
        state.attachedSheetID = ObjectIdentifier(other)
        XCTAssertEqual(attempt.readiness(state, closingSheetID: ObjectIdentifier(sheet)), .cancelled)
        XCTAssertEqual(attempt.readiness(initial, closingSheetID: ObjectIdentifier(sheet)), .ready)
    }
    func testFailedReadNeverConsumesOrClearsANewerDraft() {
        let (attempt, _) = fixture(); var draft = "new draft"
        XCTAssertFalse(attempt.commit(current: { nil }, insert: { draft = "" }))
        XCTAssertEqual(draft, "new draft"); XCTAssertFalse(attempt.consumed)
    }
}
