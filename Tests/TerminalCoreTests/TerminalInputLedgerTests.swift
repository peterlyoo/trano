import XCTest
@testable import TerminalCore

final class TerminalInputLedgerTests: XCTestCase {
    let binding = TerminalInputBinding(paneID: "pane-a", backendPID: 101, generation: "generation-a")

    // Implements: FR-QUEUE-5
    func testFreshAndEnterOnlyNeverProveAnEmptyDraft() throws {
        var ledger = TerminalInputLedger()
        XCTAssertEqual(ledger.readiness(binding: binding), .inputReviewRequired)
        let enter = try ledger.beginManualWrite(binding: binding, submissionCandidate: true)
        XCTAssertTrue(ledger.finishWrite(enter, succeeded: true))
        XCTAssertEqual(ledger.readiness(binding: binding), .inputReviewRequired)
    }

    // Implements: FR-QUEUE-5
    func testTrustedSubmitUsesCapturedReceiptAndWaitsForWriteCompletion() throws {
        var ledger = TerminalInputLedger()
        let submission = try ledger.beginManualWrite(binding: binding, submissionCandidate: true)
        XCTAssertTrue(ledger.observeTrustedSubmit(binding: binding))
        XCTAssertEqual(ledger.readiness(binding: binding), .inputInFlight)
        XCTAssertTrue(ledger.finishWrite(submission, succeeded: true))
        XCTAssertNotNil(ledger.readiness(binding: binding).lease)
    }

    // Implements: FR-QUEUE-5
    func testUserDraftAfterSubmittedTurnRemainsDirtyAcrossDelayedHook() throws {
        var ledger = TerminalInputLedger()
        let submission = try ledger.beginManualWrite(binding: binding, submissionCandidate: true)
        _ = ledger.finishWrite(submission, succeeded: true)
        let draft = try ledger.beginManualWrite(binding: binding)
        _ = ledger.finishWrite(draft, succeeded: true)
        XCTAssertTrue(ledger.observeTrustedSubmit(binding: binding))
        XCTAssertEqual(ledger.readiness(binding: binding), .inputReviewRequired)
    }

    // Implements: FR-QUEUE-5
    func testTrustedSubmitConsumesOldestReceiptInsteadOfNewestDraft() throws {
        var ledger = TerminalInputLedger()
        let first = try ledger.beginManualWrite(binding: binding, submissionCandidate: true)
        _ = ledger.finishWrite(first, succeeded: true)
        let second = try ledger.beginManualWrite(binding: binding, submissionCandidate: true)
        _ = ledger.finishWrite(second, succeeded: true)
        XCTAssertTrue(ledger.observeTrustedSubmit(binding: binding))
        XCTAssertNil(ledger.readiness(binding: binding).lease)
        XCTAssertTrue(ledger.observeTrustedSubmit(binding: binding))
        XCTAssertNotNil(ledger.readiness(binding: binding).lease)
    }

    // Implements: FR-QUEUE-5
    func testMissingReceiptAndDuplicateHookInvalidatePreviousProof() throws {
        var ledger = try cleanLedger()
        let lease = try XCTUnwrap(ledger.readiness(binding: binding).lease)
        XCTAssertFalse(ledger.observeTrustedSubmit(binding: binding))
        XCTAssertFalse(ledger.validate(lease))
        XCTAssertEqual(ledger.readiness(binding: binding), .inputReviewRequired)
    }

    // Implements: FR-QUEUE-5
    func testManualInputAfterEnqueueInvalidatesCommitTimeLease() throws {
        var ledger = try cleanLedger()
        let queuedLease = try XCTUnwrap(ledger.readiness(binding: binding).lease)
        let draft = try ledger.beginManualWrite(binding: binding)
        XCTAssertFalse(ledger.validate(queuedLease))
        XCTAssertEqual(ledger.readiness(binding: binding), .inputInFlight)
        _ = ledger.finishWrite(draft, succeeded: true)
        XCTAssertThrowsError(try ledger.beginAutomaticWrite(queuedLease))
        XCTAssertEqual(ledger.readiness(binding: binding), .inputReviewRequired)
    }

    // Implements: FR-QUEUE-5
    func testFailedWriteCannotBeCleanedByItsDelayedTrustedHook() throws {
        var ledger = TerminalInputLedger()
        let receipt = try ledger.beginManualWrite(binding: binding, submissionCandidate: true)
        XCTAssertTrue(ledger.finishWrite(receipt, succeeded: false))
        XCTAssertFalse(ledger.observeTrustedSubmit(binding: binding))
        XCTAssertEqual(ledger.readiness(binding: binding), .inputReviewRequired)
    }

    // Implements: FR-QUEUE-5
    func testUnknownAPIInputDoesNotCreateSubmissionProof() throws {
        var ledger = try cleanLedger()
        let apiWrite = try ledger.beginManualWrite(binding: binding)
        _ = ledger.finishWrite(apiWrite, succeeded: true)
        XCTAssertFalse(ledger.observeTrustedSubmit(binding: binding))
        XCTAssertEqual(ledger.readiness(binding: binding), .inputReviewRequired)
    }

    // Implements: FR-QUEUE-5
    func testCleanDoneCanDeliverFIFOThroughSeparateAutomaticReceipts() throws {
        var ledger = try cleanLedger()
        for _ in 0..<3 {
            let lease = try XCTUnwrap(ledger.readiness(binding: binding).lease)
            let automatic = try ledger.beginAutomaticWrite(lease)
            XCTAssertFalse(ledger.validate(lease))
            XCTAssertEqual(ledger.readiness(binding: binding), .inputInFlight)
            _ = ledger.finishWrite(automatic, succeeded: true)
            XCTAssertNil(ledger.readiness(binding: binding).lease)
            XCTAssertTrue(ledger.observeTrustedSubmit(binding: binding))
            XCTAssertNotNil(ledger.readiness(binding: binding).lease)
        }
    }

    // Implements: FR-QUEUE-5
    func testNewGenerationAndBackendRejectOldReceiptAndOldLease() throws {
        var ledger = try cleanLedger()
        let oldLease = try XCTUnwrap(ledger.readiness(binding: binding).lease)
        let oldReceipt = try ledger.beginManualWrite(binding: binding, submissionCandidate: true)
        let replacement = TerminalInputBinding(paneID: binding.paneID, backendPID: 102, generation: "generation-b")
        let newReceipt = try ledger.beginManualWrite(binding: replacement)
        XCTAssertFalse(ledger.finishWrite(oldReceipt, succeeded: true))
        XCTAssertFalse(ledger.validate(oldLease))
        XCTAssertEqual(ledger.readiness(binding: binding), .changed)
        XCTAssertEqual(ledger.readiness(binding: replacement), .inputInFlight)
        XCTAssertTrue(ledger.finishWrite(newReceipt, succeeded: true))
        XCTAssertEqual(ledger.readiness(binding: replacement), .inputReviewRequired)
    }

    // Implements: FR-QUEUE-5
    func testReviewDoesNotClaimDraftClearedAndRequiresFutureTrustedSubmit() throws {
        var ledger = try cleanLedger()
        let oldLease = try XCTUnwrap(ledger.readiness(binding: binding).lease)
        let oldReceipt = try ledger.beginManualWrite(binding: binding, submissionCandidate: true)
        _ = ledger.finishWrite(oldReceipt, succeeded: true)
        try ledger.review(binding: binding)
        XCTAssertFalse(ledger.validate(oldLease))
        XCTAssertFalse(ledger.observeTrustedSubmit(binding: binding))
        XCTAssertEqual(ledger.readiness(binding: binding), .inputReviewRequired)
        let future = try ledger.beginManualWrite(binding: binding, submissionCandidate: true)
        _ = ledger.finishWrite(future, succeeded: true)
        XCTAssertTrue(ledger.observeTrustedSubmit(binding: binding))
        XCTAssertNotNil(ledger.readiness(binding: binding).lease)
    }

    // Implements: FR-QUEUE-5
    func testReviewRefusesAnInFlightWriteAndCannotEraseItsReservation() throws {
        var ledger = try cleanLedger()
        let pending = try ledger.beginManualWrite(binding: binding)
        XCTAssertThrowsError(try ledger.review(binding: binding))
        XCTAssertEqual(ledger.readiness(binding: binding), .inputInFlight)
        XCTAssertTrue(ledger.finishWrite(pending, succeeded: true))
    }

    // Implements: FR-QUEUE-5
    func testDuplicateFinishCannotReopenOrAcknowledgeAnotherWrite() throws {
        var ledger = TerminalInputLedger()
        let receipt = try ledger.beginManualWrite(binding: binding)
        XCTAssertTrue(ledger.finishWrite(receipt, succeeded: true))
        let newer = try ledger.beginManualWrite(binding: binding)
        XCTAssertFalse(ledger.finishWrite(receipt, succeeded: true))
        XCTAssertEqual(ledger.readiness(binding: binding), .inputInFlight)
        XCTAssertTrue(ledger.finishWrite(newer, succeeded: true))
    }

    // Implements: FR-QUEUE-5
    func testSubmissionReceiptOverflowFailsClosedUntilExplicitReview() throws {
        var ledger = TerminalInputLedger()
        for _ in 0..<65 {
            let receipt = try ledger.beginManualWrite(binding: binding, submissionCandidate: true)
            _ = ledger.finishWrite(receipt, succeeded: true)
        }
        for _ in 0..<65 { XCTAssertFalse(ledger.observeTrustedSubmit(binding: binding)) }
        XCTAssertEqual(ledger.readiness(binding: binding), .inputReviewRequired)
        try ledger.review(binding: binding)
        let receipt = try ledger.beginManualWrite(binding: binding, submissionCandidate: true)
        _ = ledger.finishWrite(receipt, succeeded: true)
        XCTAssertTrue(ledger.observeTrustedSubmit(binding: binding))
        XCTAssertNotNil(ledger.readiness(binding: binding).lease)
    }

    // Implements: FR-QUEUE-5
    func testLedgerRoundTripPreservesCleanLeaseWithoutAnyUserBytes() throws {
        let ledger = try cleanLedger()
        let lease = try XCTUnwrap(ledger.readiness(binding: binding).lease)
        let encoded = try JSONEncoder().encode(ledger)
        let restored = try JSONDecoder().decode(TerminalInputLedger.self, from: encoded)
        XCTAssertEqual(restored, ledger)
        XCTAssertTrue(restored.validate(lease))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["records", "schemaVersion"])
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("text"))
    }

    // Implements: FR-QUEUE-5
    func testSameGenerationProviderReplacementRejectsOldReceiptAndLease() throws {
        var ledger = try cleanLedger()
        let oldLease = try XCTUnwrap(ledger.readiness(binding: binding).lease)
        let oldReceipt = try ledger.beginManualWrite(binding: binding, submissionCandidate: true)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(binding)) as? [String: Any])
        object["providerPID"] = 222
        let replacement = try JSONDecoder().decode(TerminalInputBinding.self, from: JSONSerialization.data(withJSONObject: object))
        _ = try ledger.beginManualWrite(binding: replacement)
        XCTAssertFalse(ledger.finishWrite(oldReceipt, succeeded: true))
        XCTAssertFalse(ledger.validate(oldLease))
        XCTAssertEqual(ledger.readiness(binding: binding), .changed)
    }

    // Implements: FR-QUEUE-5
    func testUncertainAPIMarkerRequiresReviewBeforeAFutureNativeSubmitCanProveClean() throws {
        var ledger = try cleanLedger()
        try ledger.markUncertain(binding: binding)
        let future = try ledger.beginManualWrite(binding: binding, submissionCandidate: true)
        _ = ledger.finishWrite(future, succeeded: true)
        XCTAssertFalse(ledger.observeTrustedSubmit(binding: binding))
        XCTAssertEqual(ledger.readiness(binding: binding), .inputReviewRequired)
        try ledger.review(binding: binding)
        let reviewed = try ledger.beginManualWrite(binding: binding, submissionCandidate: true)
        _ = ledger.finishWrite(reviewed, succeeded: true)
        XCTAssertTrue(ledger.observeTrustedSubmit(binding: binding))
        XCTAssertNotNil(ledger.readiness(binding: binding).lease)
    }

    // Implements: FR-QUEUE-5
    func testUncertainMarkerKeepsOutstandingWriteReservations() throws {
        var ledger = try cleanLedger()
        let pending = try ledger.beginManualWrite(binding: binding, submissionCandidate: true)
        try ledger.markUncertain(binding: binding)
        XCTAssertEqual(ledger.readiness(binding: binding), .inputInFlight)
        XCTAssertTrue(ledger.finishWrite(pending, succeeded: true))
        XCTAssertFalse(ledger.observeTrustedSubmit(binding: binding))
        XCTAssertEqual(ledger.readiness(binding: binding), .inputReviewRequired)
    }

    // Implements: FR-QUEUE-5
    func testOldHookCannotCertifyOrConsumeACandidateCapturedAfterHookStarted() throws {
        var ledger = TerminalInputLedger()
        let originStart = Date(timeIntervalSince1970: 100)
        let captured = Date(timeIntervalSince1970: 101)
        let candidate = try ledger.beginManualWrite(binding: binding, submissionCandidate: true, capturedAt: captured)
        _ = ledger.finishWrite(candidate, succeeded: true)
        XCTAssertFalse(ledger.observeTrustedSubmit(binding: binding, originStartedAt: originStart))
        XCTAssertEqual(ledger.readiness(binding: binding), .inputReviewRequired)
        XCTAssertTrue(ledger.observeTrustedSubmit(binding: binding, originStartedAt: captured.addingTimeInterval(1)))
        XCTAssertNotNil(ledger.readiness(binding: binding).lease)
    }

    // Implements: FR-QUEUE-5
    func testDelayedPreReviewHookCannotCertifyPostReviewCandidate() throws {
        var ledger = TerminalInputLedger()
        let before = try ledger.beginManualWrite(binding: binding, submissionCandidate: true, capturedAt: Date(timeIntervalSince1970: 100))
        _ = ledger.finishWrite(before, succeeded: true)
        try ledger.markUncertain(binding: binding)
        try ledger.review(binding: binding)
        let future = try ledger.beginManualWrite(binding: binding, submissionCandidate: true, capturedAt: Date(timeIntervalSince1970: 200))
        _ = ledger.finishWrite(future, succeeded: true)
        XCTAssertFalse(ledger.observeTrustedSubmit(binding: binding, originStartedAt: Date(timeIntervalSince1970: 150)))
        XCTAssertNil(ledger.readiness(binding: binding).lease)
        XCTAssertTrue(ledger.observeTrustedSubmit(binding: binding, originStartedAt: Date(timeIntervalSince1970: 201)))
        XCTAssertNotNil(ledger.readiness(binding: binding).lease)
    }

    // Implements: FR-QUEUE-5
    func testPendingWriteBudgetRejectsAdditionalWritesWithoutForgettingEarlierOnes() throws {
        var ledger = TerminalInputLedger()
        var receipts: [TerminalInputWriteReceipt] = []
        for _ in 0..<128 { receipts.append(try ledger.beginManualWrite(binding: binding)) }
        XCTAssertThrowsError(try ledger.beginManualWrite(binding: binding))
        for receipt in receipts { XCTAssertTrue(ledger.finishWrite(receipt, succeeded: true)) }
        XCTAssertEqual(ledger.readiness(binding: binding), .inputReviewRequired)
    }

    // Implements: FR-QUEUE-5
    func testProtocolReplyReservesTransportWithoutChangingUserRevisionOrCleanProof() throws {
        var ledger = try cleanLedger()
        let before = try XCTUnwrap(ledger.readiness(binding: binding).lease)
        let protocolReply = try ledger.beginProtocolWrite(binding: binding)
        XCTAssertEqual(protocolReply.revision, before.revision)
        XCTAssertEqual(ledger.readiness(binding: binding), .inputInFlight)
        XCTAssertFalse(ledger.validate(before))
        XCTAssertTrue(ledger.finishWrite(protocolReply, succeeded: true))
        XCTAssertEqual(ledger.readiness(binding: binding).lease, before)
    }

    // Implements: FR-QUEUE-5
    func testProtocolFailureCannotLeaveCleanProofOrCreateSubmissionCandidate() throws {
        var ledger = try cleanLedger()
        let reply = try ledger.beginProtocolWrite(binding: binding)
        XCTAssertTrue(ledger.finishWrite(reply, succeeded: false))
        XCTAssertFalse(ledger.observeTrustedSubmit(binding: binding))
        XCTAssertEqual(ledger.readiness(binding: binding), .inputReviewRequired)
    }

    // Implements: FR-QUEUE-5
    func testProtocolOnlyTransportRoundTripsAndNeverEstablishesUserCleanliness() throws {
        var ledger = TerminalInputLedger()
        let reply = try ledger.beginProtocolWrite(binding: binding)
        XCTAssertEqual(reply.revision, 0)
        let reopened = try JSONDecoder().decode(TerminalInputLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(reopened.readiness(binding: binding), .inputInFlight)
        XCTAssertTrue(ledger.finishWrite(reply, succeeded: true))
        XCTAssertFalse(ledger.observeTrustedSubmit(binding: binding))
        XCTAssertEqual(ledger.readiness(binding: binding), .inputReviewRequired)
    }

    private func cleanLedger() throws -> TerminalInputLedger {
        var ledger = TerminalInputLedger()
        let receipt = try ledger.beginManualWrite(binding: binding, submissionCandidate: true)
        _ = ledger.finishWrite(receipt, succeeded: true)
        _ = ledger.observeTrustedSubmit(binding: binding)
        return ledger
    }
}
