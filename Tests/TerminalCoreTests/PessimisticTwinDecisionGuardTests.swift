import Foundation
import XCTest
@testable import TerminalCore

final class PessimisticTwinDecisionGuardTests: XCTestCase {
    // Implements: FR-TWIN-6
    func testWorkflowDecisionCannotBeSelfApprovedOrConsumedByGenericAgentRoutes() throws {
        let fixture = try fixture()
        XCTAssertThrowsError(try fixture.runtime.resolveDecision(fixture.entry.id, generation: fixture.entry.generation, action: "choose", optionID: "merge"))
        for operation in ["poll", "abandon"] {
            let reply = try fixture.runtime.decisionAdapter(.object(["type": .string(operation), "request_id": .string(fixture.entry.id)]))
            XCTAssertEqual(reply["ok"], .bool(false))
        }
    }

    func testWorkflowCardDoesNotPreventTheFutureSourceDoneOrQueuedInputBoundary() throws {
        let fixture = try fixture()
        XCTAssertNil(try fixture.runtime.decisionGateReason(paneID: fixture.entry.paneID, generation: fixture.entry.generation))
        let reply = try fixture.runtime.decisionAdapter(.object(["type": .string("gate"), "agent": .string("claude"), "session_id": .string(fixture.entry.question.source.sessionID)]))
        XCTAssertEqual(reply["decision"], .string("allow"))
    }

    private func fixture() throws -> (runtime: TerminalRuntime, entry: DecisionInboxEntry) {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("trano-twin-choice-" + UUID().uuidString.prefix(8))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let runtime = try TerminalRuntime(root: root)
        let paneID = UUID().uuidString.lowercased(), conversation = UUID().uuidString.lowercased()
        let pane = TerminalSession(id: paneID, title: "Twin", cwd: "/fixture", pid: getpid())
        var launch = AgentLaunch(paneID: paneID, provider: .claude, providerSessionID: conversation, cwd: "/fixture", accountID: nil, configurationRoot: "/profile", bootID: try TerminalRuntime.bootIdentity(), processID: getpid())
        launch.providerPID = getpid()
        try runtime.update { $0.sessions = [pane]; $0.agentLaunches = [launch] }
        let question = DecisionQuestion(requestID: "7477696e-0000-4000-8000-000000000001", threadID: UUID().uuidString,
            source: DecisionSource(agent: "claude", sessionID: conversation, workspace: "/fixture"), question: DecisionText(en: "Merge reviewed result?", ko: "검토 결과를 합칠까요?"),
            options: [DecisionOption(id: "merge", label: DecisionText(en: "Merge", ko: "합치기"), description: DecisionText(en: "Explicit user choice", ko: "사람이 직접 선택합니다"))])
        let entry = DecisionInboxEntry(question: question, paneID: paneID, generation: launch.id, createdAt: Date(), status: "pending", delivered: false)
        let data = try JSONEncoder().encode(JSONValue.object(["version": .number(1), "entries": try .encoded([entry])]))
        try TerminalRuntime.atomicWrite(data, to: root.appendingPathComponent("decision-inbox.json"))
        return (runtime, entry)
    }
}
