import AppKit
import XCTest
@testable import TranoApp

@MainActor final class DeferredPasteOwnershipTests: XCTestCase {
    private let store = NSObject(), renderer = NSObject(), window = NSObject(), other = NSObject()
    private func fixture() -> (DeferredTerminalInputAttempt, DeferredTerminalInputState) {
        let owner = TerminalInteractionOwner(paneID: "pane", windowID: ObjectIdentifier(window), generation: UUID())
        let id = DeferredTerminalInputIdentity(owner: owner, storeID: ObjectIdentifier(store), rendererID: ObjectIdentifier(renderer),
            clientPID: 81, backendPID: 42, hostID: nil, remoteSessionID: nil, providerGeneration: "launch", providerPID: 70)
        return (DeferredTerminalInputAttempt(identity: id, lease: TerminalInteractionLease(owner: owner, sessionPID: 42, hostID: nil)),
            DeferredTerminalInputState(identity: id, focusedPaneID: "pane", keyWindowID: ObjectIdentifier(window)))
    }
    func testConsumedAdmissionRetainsImmutableOwnershipUntilActualDestinationChanges() {
        let (attempt, state) = fixture()
        XCTAssertTrue(attempt.commit(current: {state}, insert: {}))
        XCTAssertEqual(attempt.ownershipReadiness(state), .ready)
        var current = state; current.focusedPaneID = "other"
        XCTAssertEqual(attempt.ownershipReadiness(current), .cancelled)
        XCTAssertFalse(attempt.commit(current: {state}, insert: {XCTFail("Duplicate admission")}))
    }
    func testMultilineConfirmationCannotRerouteAfterProviderLeaseOrNativeFocusChanges() {
        let mutations: [(DeferredTerminalInputAttempt, inout DeferredTerminalInputState) -> Void] = [
            { _, s in s.identity = DeferredTerminalInputIdentity(owner: s.identity.owner, storeID: s.identity.storeID,
                rendererID: s.identity.rendererID, clientPID: s.identity.clientPID, backendPID: s.identity.backendPID,
                hostID: nil, remoteSessionID: nil, providerGeneration: "replacement", providerPID: 71) },
            { a, _ in a.lease.invalidate() }, { _, s in s.keyWindowID = ObjectIdentifier(self.other) },
            { _, s in s.terminalIsFirstResponder = false }, { _, s in s.intentCurrent = false },
            { _, s in s.focusedPaneID = "other" }, { _, s in s.markedText = true },
            { _, s in s.inputProtected = true }
        ]
        for mutate in mutations {
            let (attempt, initial) = fixture(); var state = initial; var writes = 0; var completions = 0
            let owner = DeferredTerminalInputOwnership(attempt: attempt, state: {state})
            TerminalDraftPaste(text: "first\nsecond", ownership: owner, history: {_ in false}, bracketed: {true},
                confirm: {text, _ in mutate(attempt, &state); return text}, report: {_ in}, insert: {_ in writes += 1},
                didInsert: { completions += 1 }).perform()
            XCTAssertEqual(writes, 0); XCTAssertEqual(completions, 0)
        }
    }
    func testHistoryReturnUsesOriginalIntentAndDoesNotClearANewerVoiceDraft() {
        let (attempt, initial) = fixture(); var state = initial; var resumed: (() -> Void)?
        var waiting = true; var writes = 0; var draft = "newer draft"
        let owner = DeferredTerminalInputOwnership(attempt: attempt, state: {state})
        let paste = TerminalDraftPaste(text: "voice", ownership: owner, history: { continuation in
            if waiting {resumed = continuation; return true}; return false
        }, bracketed: {true}, confirm: {t, _ in t}, report: {_ in}, insert: {_ in writes += 1}, didInsert: {draft = ""})
        paste.perform(); waiting = false; state.intentCurrent = false; resumed?()
        XCTAssertEqual(writes, 0); XCTAssertEqual(draft, "newer draft")
    }
    func testHistoryBoundaryCannotSwitchProviderBeforeSendingSingleLine() {
        let (attempt, initial) = fixture(); var state = initial; var writes = 0
        let owner = DeferredTerminalInputOwnership(attempt: attempt, state: {state})
        TerminalDraftPaste(text: "voice", ownership: owner, history: {_ in state.intentCurrent = false; return false},
            bracketed: {true}, confirm: {t, _ in t}, report: {_ in}, insert: {_ in writes += 1}).perform()
        XCTAssertEqual(writes, 0)
    }
    func testSuccessfulOwnedPasteWorksAfterOneShotAdmissionAndOnlyOnce() {
        let (attempt, state) = fixture(); var writes: [String] = []; var completions = 0
        let owner = DeferredTerminalInputOwnership(attempt: attempt, state: {state})
        XCTAssertTrue(attempt.commit(current: {state}, insert: {}))
        let paste = TerminalDraftPaste(text: "한글\nsecond", ownership: owner, history: {_ in false}, bracketed: {true},
            confirm: {t, _ in t}, report: {XCTFail($0)}, insert: {writes.append($0)}, didInsert: {completions += 1})
        paste.perform(); paste.perform()
        XCTAssertEqual(writes, ["한글\nsecond"]); XCTAssertEqual(completions, 1)
    }
    func testOrdinaryPasteCancelAndBracketedModeChangesNeverInsert() {
        for accepted in [false, true] {
            let (attempt, state) = fixture(); var bracketed = true; var writes = 0
            TerminalDraftPaste(text: "one\ntwo", ownership: DeferredTerminalInputOwnership(attempt: attempt, state: {state}),
                history: {_ in false}, bracketed: {bracketed}, confirm: {text, _ in bracketed = false; return accepted ? text : nil},
                report: {_ in}, insert: {_ in writes += 1}).perform()
            XCTAssertEqual(writes, 0)
        }
    }
    func testMultilinePasteWithoutBracketedModeWarnsThenPastesAfterConfirmation() {
        for accepted in [false, true] {
            let (attempt, state) = fixture(); var warned: [Bool] = []; var writes: [String] = []
            TerminalDraftPaste(text: "one\ntwo", ownership: DeferredTerminalInputOwnership(attempt: attempt, state: {state}),
                history: {_ in false}, bracketed: {false}, confirm: {text, bracketed in warned.append(bracketed); return accepted ? text : nil},
                report: {XCTFail($0)}, insert: {writes.append($0)}).perform()
            XCTAssertEqual(warned, [false]); XCTAssertEqual(writes, accepted ? ["one\ntwo"] : [])
        }
    }
    func testInvalidInitialOwnershipDoesNotPresentConfirmationOrSend() {
        let (attempt, initial) = fixture(); var state = initial; state.terminalIsFirstResponder = false
        TerminalDraftPaste(text: "one\ntwo", ownership: DeferredTerminalInputOwnership(attempt: attempt, state: {state}),
            history: {_ in XCTFail("Should not leave history"); return false}, bracketed: {true},
            confirm: {_, _ in XCTFail("Must not present"); return nil}, report: {_ in}, insert: {_ in XCTFail("Must not paste")}).perform()
    }
    func testVoiceDraftSurvivesDetachedSheetResponderGapAndTimeoutForExplicitReview() {
        let (attempt, initial) = fixture(); var gap = initial; gap.terminalIsFirstResponder = false
        let presentation = UUID(); var recovery = VoiceInputRecoveryDraft()
        XCTAssertTrue(recovery.remember("원래 음성 초안", presentationID: presentation, currentID: presentation))
        XCTAssertEqual(attempt.readiness(gap), .cancelled)
        XCTAssertFalse(attempt.commit(current: {gap}, insert: {XCTFail("Must not force focus")}))
        XCTAssertEqual(recovery.reviewOnNextOpen(currentID: presentation), "원래 음성 초안")
        XCTAssertNil(recovery.reviewOnNextOpen(currentID: presentation))
    }
    func testStaleCompletionCannotClearOrReplaceANewerPresentationRecoveryDraft() {
        let old = UUID(), newer = UUID(); var recovery = VoiceInputRecoveryDraft()
        XCTAssertTrue(recovery.remember("old", presentationID: old, currentID: old))
        XCTAssertEqual(recovery.reviewOnNextOpen(currentID: old), "old")
        XCTAssertTrue(recovery.remember("new draft", presentationID: newer, currentID: newer))
        XCTAssertFalse(recovery.remember("stale callback", presentationID: old, currentID: newer))
        recovery.clearInserted(presentationID: old, currentID: newer)
        XCTAssertEqual(recovery.reviewOnNextOpen(currentID: newer), "new draft")
    }
    func testSuccessfullyInsertedVoiceClearsOnlyItsOwnRecoveryAndDraftLimitIsUTF8Bytes() {
        let id = UUID(); var recovery = VoiceInputRecoveryDraft()
        XCTAssertTrue(recovery.remember("kept", presentationID: id, currentID: id))
        recovery.clearInserted(presentationID: id, currentID: id)
        XCTAssertNil(recovery.reviewOnNextOpen(currentID: id))
        XCTAssertTrue(recovery.remember(String(repeating: "a", count: 1_048_576), presentationID: id, currentID: id))
        XCTAssertFalse(recovery.remember(String(repeating: "한", count: 349_526), presentationID: id, currentID: id))
        XCTAssertEqual(recovery.reviewOnNextOpen(currentID: id)?.utf8.count, 1_048_576)
    }
}
