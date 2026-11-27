import Foundation
import XCTest
@testable import TerminalCore
final class PessimisticTwinModelTests: XCTestCase {
    // Implements: FR-TWIN-1, FR-TWIN-5, FR-TWIN-6
    func testInvalidEnvelopeCannotBeUsedAsReviewResult() {
        for report in [TwinReport(status: "approved", rationale: "not authority", changedFiles: []), TwinReport(status: "working", rationale: "", changedFiles: []), TwinReport(status: "working", rationale: "x", changedFiles: ["../outside"]), TwinReport(status: "working", rationale: "x", changedFiles: ["/outside"]), TwinReport(status: "working", rationale: "x", changedFiles: ["a", "a"])] {
            XCTAssertThrowsError(try report.validate())
        }
    }
    func testWireSchemaPreservesAgentOutputFieldsAndUnicodePaths() throws {
        let value = try TwinReport.decode(Data(#"{"status":"working","rationale":"검증했습니다","changed_files":["한 글\nfile"],"agent":"codex2","round":1,"quality_score":{"correctness":9}}"#.utf8))
        XCTAssertEqual(value.changedFiles, ["한 글\nfile"])
        XCTAssertEqual(value.additionalFields["agent"], .string("codex2"))
        XCTAssertEqual(try JSONDecoder().decode(TwinReport.self, from: JSONEncoder().encode(value)), value)
        XCTAssertThrowsError(try TwinReport.decode(Data(("```json\n{}\n```" ).utf8)))
    }
    func testNoFurtherImprovementCannotClaimCommittedFixes() {
        XCTAssertThrowsError(try TwinReport(status: "no_further_improvement", rationale: "I fixed it", changedFiles: ["fixed.swift"]).validate())
    }
    func testReservedDecisionIdentityIsDeterministicAndCannotBeRecycledByPruning() {
        let run = UUID().uuidString.lowercased(), id = TwinDecisionID.make(runID: run, round: 1)
        XCTAssertNotNil(UUID(uuidString: id)); XCTAssertTrue(TwinDecisionID.isReserved(id))
        XCTAssertEqual(id, TwinDecisionID.make(runID: run, round: 1)); XCTAssertNotEqual(id, TwinDecisionID.make(runID: run, round: 2))
        XCTAssertTrue(TwinState().protectsDecision(id)); XCTAssertFalse(TwinState().protectsDecision(UUID().uuidString))
    }
}
