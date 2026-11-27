import Foundation
import Darwin
import XCTest
@testable import TerminalCore

final class PessimisticTwinRetirementTests: XCTestCase {
    // Implements: FR-TWIN-9.
    func testCancelledOrUnavailableReviewerCanStopWithoutClearingManualInputOrPendingChoice() {
        for reason in [TwinExitReason.userInterrupt, .agentUnavailable, .invalidAgentOutput] {
            XCTAssertTrue(TwinProviderRetirement.canInterruptReview(reason: reason, expectedFingerprint: "same", fingerprint: "same", pendingDecision: false))
            XCTAssertFalse(TwinProviderRetirement.canInterruptReview(reason: reason, expectedFingerprint: "old", fingerprint: "manual draft", pendingDecision: false))
            XCTAssertFalse(TwinProviderRetirement.canInterruptReview(reason: reason, expectedFingerprint: "same", fingerprint: "same", pendingDecision: true))
        }
        for reason in [nil, .agentAgreement, .roundCap, .noopCap] as [TwinExitReason?] {
            XCTAssertFalse(TwinProviderRetirement.canInterruptReview(reason: reason, expectedFingerprint: "same", fingerprint: "same", pendingDecision: false))
        }
    }
    func testProviderReceivesOneGracefulStopBeforeOneDelayedKill() throws {
        let now = Date(timeIntervalSince1970: 100)
        let stop = try TwinProviderRetirement.request(stages: [], now: now)
        XCTAssertEqual(stop.signal, SIGTERM)
        let stages = [try XCTUnwrap(stop.marker)]
        XCTAssertNil(try TwinProviderRetirement.request(stages: stages, now: now.addingTimeInterval(4.9)).signal)
        let escalation = try TwinProviderRetirement.request(stages: stages, now: now.addingTimeInterval(5))
        XCTAssertEqual(escalation.signal, SIGKILL)
        XCTAssertNil(try TwinProviderRetirement.request(stages: stages + [try XCTUnwrap(escalation.marker)], now: now.addingTimeInterval(99)).signal)
    }
    func testClockRollbackWaitsAndMalformedJournalHoldsResources() throws {
        XCTAssertNil(try TwinProviderRetirement.request(stages: ["providerStopRequested:100"], now: Date(timeIntervalSince1970: 90)).signal)
        for stages in [["providerStopRequested:bad"], ["providerStopRequested:nan"], ["providerStopRequested:1", "providerStopRequested:2"], ["providerKillRequested"]] {
            XCTAssertThrowsError(try TwinProviderRetirement.request(stages: stages, now: Date(timeIntervalSince1970: 200)))
        }
    }
    func testUnclaimedRoundAdmitsMissingOrEmptyButRetainsEveryArtifactIncludingBrokenLinks() throws {
        guard let canonical = realpath(NSTemporaryDirectory(), nil) else { throw CocoaError(.fileReadUnknown) }
        defer { free(canonical) }
        let base = URL(fileURLWithPath: String(cString: canonical)).appendingPathComponent("twin-unclaimed-unit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try TwinUnclaimedRoundResources.requireAbsent(path: base.path)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        try TwinUnclaimedRoundResources.requireAbsent(path: base.path)
        for name in ["launch-ticket.json", "profile", "snapshot-plan.json", "arbitrary-partial-artifact"] {
            let path = base.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: base.appendingPathComponent("missing").path)
            XCTAssertThrowsError(try TwinUnclaimedRoundResources.requireAbsent(path: base.path))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: path.path), base.appendingPathComponent("missing").path)
            XCTAssertEqual(unlink(path.path), 0)
        }
    }
}
