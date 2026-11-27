import Foundation
import XCTest
@testable import TerminalCore

final class PessimisticTwinDecisionPruningTests: XCTestCase {
    // Implements: FR-TWIN-6, FR-TWIN-9
    func testKnownPrunedReservedHistoryDoesNotExhaustInboxForCurrentCard() throws {
        let f = twinDecisionFixture()
        let template = try TwinDecisionBridge.entry(run: f.run, round: f.round, decisionID: f.binding.decisionID)
        let orphans = (0..<600).map { _ -> DecisionInboxEntry in
            let id = TwinDecisionID.make(runID: UUID().uuidString.lowercased(), round: 1)
            return DecisionInboxEntry(question: .init(requestID: id, threadID: UUID().uuidString.lowercased(), source: template.question.source, question: template.question.question, options: template.question.options), paneID: template.paneID, generation: template.generation, createdAt: template.createdAt, status: "abandoned", resolution: nil, delivered: true)
        }
        let result = TwinDecisionBridge.project(orphans, state: f.state)
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result.first?.id, template.id)
        XCTAssertTrue(orphans.allSatisfy { TwinDecisionID.isReserved($0.id) })
    }
    func testKnownMissingRunOrRoundDropsItsReservedCard() throws {
        let f = twinDecisionFixture()
        let entry = try TwinDecisionBridge.entry(run: f.run, round: f.round, decisionID: f.binding.decisionID)
        XCTAssertTrue(TwinDecisionBridge.project([entry], state: .init()).isEmpty)
        XCTAssertTrue(TwinDecisionBridge.project([entry], state: .init(decisionBindings: [f.binding])).isEmpty)
        var noRound = f.run; noRound.rounds = []
        XCTAssertTrue(TwinDecisionBridge.project([entry], state: .init(runs: [noRound], decisionBindings: [f.binding])).isEmpty)
        XCTAssertTrue(TwinDecisionID.isReserved(entry.id))
    }
    func testUnavailableCanonicalStateRetainsAbandonedCardWithoutAuthority() throws {
        let f = twinDecisionFixture()
        var entry = try TwinDecisionBridge.entry(run: f.run, round: f.round, decisionID: f.binding.decisionID)
        entry.status = "resolved"
        entry.resolution = .init(action: "choose", optionID: "merge", instruction: nil, locale: nil, resolvedAt: Date())
        let result = TwinDecisionBridge.project([entry], state: nil)
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result.first?.id, entry.id)
        XCTAssertEqual(result.first?.status, "abandoned"); XCTAssertNil(result.first?.resolution)
        XCTAssertTrue(result.first?.delivered == true)
    }
}
