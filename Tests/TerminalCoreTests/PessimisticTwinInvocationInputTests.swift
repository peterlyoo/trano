import Foundation
import XCTest
@testable import TerminalCore

final class PessimisticTwinInvocationInputTests: XCTestCase {
    // Implements: FR-TWIN-3, FR-TWIN-7, FR-QUEUE-5
    let pane = "pane-owned"
    var shell: TerminalInputBinding { .init(paneID: pane, backendPID: 100, generation: "terminal:100") }
    var managed: TerminalInputBinding { .init(paneID: pane, backendPID: 100, generation: "owned-generation", providerPID: 200) }
    let captured = Date(timeIntervalSince1970: 100)

    func testOwnedArgvPromptStillRequiresTheActualTrustedUserPromptSubmit() throws {
        var ledger = TerminalInputLedger()
        try ledger.markUncertain(binding: shell)
        let fingerprint = try ledger.ownedInvocationFingerprint(paneID: pane)
        try ledger.registerOwnedInvocationPrompt(binding: managed, expectedPriorFingerprint: fingerprint, capturedAt: captured)
        XCTAssertEqual(ledger.readiness(binding: managed), .inputReviewRequired)
        XCTAssertTrue(ledger.observeTrustedSubmit(binding: managed, originStartedAt: Date(timeIntervalSince1970: 101)))
        XCTAssertNotNil(ledger.readiness(binding: managed).lease)
    }
    func testLaterUserDraftRemainsDirtyWhenTheArgvHookArrives() throws {
        var ledger = TerminalInputLedger()
        let fingerprint = try ledger.ownedInvocationFingerprint(paneID: pane)
        try ledger.registerOwnedInvocationPrompt(binding: managed, expectedPriorFingerprint: fingerprint, capturedAt: captured)
        let draft = try ledger.beginManualWrite(binding: managed, capturedAt: Date(timeIntervalSince1970: 101))
        XCTAssertTrue(ledger.finishWrite(draft, succeeded: true))
        XCTAssertTrue(ledger.observeTrustedSubmit(binding: managed, originStartedAt: Date(timeIntervalSince1970: 102)))
        XCTAssertEqual(ledger.readiness(binding: managed), .inputReviewRequired)
    }
    func testInterveningManualInputMakesRegistrationFailWithoutChangingLedger() throws {
        var ledger = TerminalInputLedger()
        try ledger.markUncertain(binding: shell)
        let fingerprint = try ledger.ownedInvocationFingerprint(paneID: pane)
        let draft = try ledger.beginManualWrite(binding: shell, capturedAt: captured)
        XCTAssertTrue(ledger.finishWrite(draft, succeeded: true))
        let before = ledger
        XCTAssertThrowsError(try ledger.registerOwnedInvocationPrompt(binding: managed, expectedPriorFingerprint: fingerprint, capturedAt: captured))
        XCTAssertEqual(ledger, before)
    }
    func testPendingWritesRefuseRegistrationEvenWithTheirCurrentFingerprint() throws {
        for protocolOnly in [false, true] {
            var ledger = TerminalInputLedger()
            if protocolOnly { _ = try ledger.beginProtocolWrite(binding: shell) }
            else { _ = try ledger.beginManualWrite(binding: shell, capturedAt: captured) }
            let fingerprint = try ledger.ownedInvocationFingerprint(paneID: pane), before = ledger
            XCTAssertThrowsError(try ledger.registerOwnedInvocationPrompt(binding: managed, expectedPriorFingerprint: fingerprint, capturedAt: captured))
            XCTAssertEqual(ledger, before)
        }
    }
    func testRegistrationIsOneShotAndCannotReplayOnTheSameManagedBinding() throws {
        var ledger = TerminalInputLedger()
        let first = try ledger.ownedInvocationFingerprint(paneID: pane)
        try ledger.registerOwnedInvocationPrompt(binding: managed, expectedPriorFingerprint: first, capturedAt: captured)
        let before = ledger, current = try ledger.ownedInvocationFingerprint(paneID: pane)
        XCTAssertThrowsError(try ledger.registerOwnedInvocationPrompt(binding: managed, expectedPriorFingerprint: first, capturedAt: captured))
        XCTAssertEqual(ledger, before)
        XCTAssertThrowsError(try ledger.registerOwnedInvocationPrompt(binding: managed, expectedPriorFingerprint: current, capturedAt: captured))
        XCTAssertEqual(ledger, before)
    }
    func testFingerprintIsOpaquePerPaneStableAcrossSerializationAndOtherPanes() throws {
        var ledger = TerminalInputLedger()
        let absent = try ledger.ownedInvocationFingerprint(paneID: pane)
        XCTAssertEqual(absent.count, 64)
        XCTAssertNotEqual(absent, try ledger.ownedInvocationFingerprint(paneID: "another-pane"))
        XCTAssertEqual(absent, try TerminalInputLedger().ownedInvocationFingerprint(paneID: pane))
        _ = try ledger.beginManualWrite(binding: .init(paneID: "another-pane", backendPID: 300, generation: "other"))
        XCTAssertEqual(absent, try ledger.ownedInvocationFingerprint(paneID: pane))
        try ledger.markUncertain(binding: shell)
        let own = try ledger.ownedInvocationFingerprint(paneID: pane)
        XCTAssertNotEqual(absent, own)
        XCTAssertEqual(own, try JSONDecoder().decode(TerminalInputLedger.self, from: JSONEncoder().encode(ledger)).ownedInvocationFingerprint(paneID: pane))
    }
    func testInvalidIdentityOrTimeCannotInstallAnInvocation() throws {
        for invalid in [shell, TerminalInputBinding(paneID: pane, backendPID: 100, generation: "managed", providerPID: 100)] {
            var ledger = TerminalInputLedger(); let before = ledger
            XCTAssertThrowsError(try ledger.registerOwnedInvocationPrompt(binding: invalid, expectedPriorFingerprint: ledger.ownedInvocationFingerprint(paneID: pane), capturedAt: captured))
            XCTAssertEqual(ledger, before)
        }
        var ledger = TerminalInputLedger(); let before = ledger
        XCTAssertThrowsError(try ledger.registerOwnedInvocationPrompt(binding: managed, expectedPriorFingerprint: ledger.ownedInvocationFingerprint(paneID: pane), capturedAt: Date(timeIntervalSinceReferenceDate: .nan)))
        XCTAssertEqual(ledger, before)
    }
    func testTooEarlyHookAndDuplicateHookNeverCreateCleanInput() throws {
        var ledger = TerminalInputLedger()
        try ledger.registerOwnedInvocationPrompt(binding: managed, expectedPriorFingerprint: ledger.ownedInvocationFingerprint(paneID: pane), capturedAt: captured)
        XCTAssertFalse(ledger.observeTrustedSubmit(binding: managed, originStartedAt: Date(timeIntervalSince1970: 99)))
        XCTAssertNil(ledger.readiness(binding: managed).lease)
        XCTAssertTrue(ledger.observeTrustedSubmit(binding: managed, originStartedAt: Date(timeIntervalSince1970: 101)))
        XCTAssertNotNil(ledger.readiness(binding: managed).lease)
        XCTAssertFalse(ledger.observeTrustedSubmit(binding: managed, originStartedAt: Date(timeIntervalSince1970: 102)))
        XCTAssertNil(ledger.readiness(binding: managed).lease)
    }
    func testRepeatedAPIUncertaintyInvalidatesAnAlreadyUncertainBootstrapReservation() throws {
        var ledger = TerminalInputLedger()
        try ledger.markUncertain(binding: shell)
        let original = try ledger.ownedInvocationFingerprint(paneID: pane)
        try ledger.markUncertain(binding: shell)
        let before = ledger
        XCTAssertNotEqual(original, try ledger.ownedInvocationFingerprint(paneID: pane))
        XCTAssertThrowsError(try ledger.registerOwnedInvocationPrompt(binding: managed, expectedPriorFingerprint: original, capturedAt: captured))
        XCTAssertEqual(ledger, before)
    }
    func testOldWriterErasingTheUnknownUncertaintyNonceFailsClosed() throws {
        var ledger = TerminalInputLedger()
        try ledger.markUncertain(binding: shell)
        let original = try ledger.ownedInvocationFingerprint(paneID: pane)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as? [String: Any])
        var records = try XCTUnwrap(root["records"] as? [String: Any])
        var record = try XCTUnwrap(records[pane] as? [String: Any])
        record.removeValue(forKey: "uncertaintyNonce"); records[pane] = record; root["records"] = records
        var oldWriter = try JSONDecoder().decode(TerminalInputLedger.self, from: JSONSerialization.data(withJSONObject: root))
        let before = oldWriter
        XCTAssertNotEqual(original, try oldWriter.ownedInvocationFingerprint(paneID: pane))
        XCTAssertThrowsError(try oldWriter.registerOwnedInvocationPrompt(binding: managed, expectedPriorFingerprint: original, capturedAt: captured))
        XCTAssertEqual(oldWriter, before)
    }
    func testCompletedProtocolReplyPreservesTheReservationAndNormalReadyLease() throws {
        var ledger = TerminalInputLedger()
        try ledger.markUncertain(binding: shell)
        let fingerprint = try ledger.ownedInvocationFingerprint(paneID: pane)
        let reply = try ledger.beginProtocolWrite(binding: shell)
        XCTAssertTrue(ledger.finishWrite(reply, succeeded: true))
        XCTAssertEqual(fingerprint, try ledger.ownedInvocationFingerprint(paneID: pane))
        try ledger.registerOwnedInvocationPrompt(binding: managed, expectedPriorFingerprint: fingerprint, capturedAt: captured)
        XCTAssertTrue(ledger.observeTrustedSubmit(binding: managed, originStartedAt: Date(timeIntervalSince1970: 101)))
        let lease = try XCTUnwrap(ledger.readiness(binding: managed).lease)
        let later = try ledger.beginProtocolWrite(binding: managed)
        XCTAssertTrue(ledger.finishWrite(later, succeeded: true))
        XCTAssertEqual(ledger.readiness(binding: managed).lease, lease)
    }

}
