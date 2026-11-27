import AppKit
import XCTest
@testable import TerminalCore
@testable import TranoApp

@MainActor final class DecisionArrivalPresentationTests: XCTestCase {
    // Implements: FR-DECISION-4
    func testArrivedQuestionOpensItsCardOnceAndWaitsWhileAnotherSurfaceIsBusy() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-decision-arrival-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try TerminalRuntime(root: root)
        let focused = TerminalSession(id: UUID().uuidString.lowercased(), title: "Focused", cwd: root.path, pid: 100)
        let asking = TerminalSession(id: UUID().uuidString.lowercased(), title: "Asking", cwd: root.path, pid: 101)
        var layout = WorkspaceLayout()
        layout.addWorkspace(title: "unit-workspace")
        layout.addTab(paneID: asking.id)
        let focusedTab = layout.addTab(paneID: focused.id)
        try layout.selectTab(focusedTab)
        try runtime.update { state in
            state.settings.automaticRestore = false
            state.sessions = [focused, asking]; state.layout = layout
        }
        let store = AppStore(runtime: runtime, startServices: false)
        let sessions = [focused, asking]
        func apply() throws { store.applyCapturedNavigation(try runtime.state(), sessions: sessions) }
        func entry() -> DecisionInboxEntry {
            let label = DecisionText(en: "Disk", ko: "디스크")
            let question = DecisionQuestion(requestID: UUID().uuidString.lowercased(), threadID: UUID().uuidString.lowercased(),
                source: DecisionSource(agent: "claude", sessionID: "fixture-session", workspace: root.path), question: label,
                options: [DecisionOption(id: "disk", label: label, description: label), DecisionOption(id: "memory", label: label, description: label)])
            return DecisionInboxEntry(question: question, paneID: asking.id, generation: "generation", createdAt: Date(), status: "pending", delivered: false)
        }

        try apply()
        XCTAssertNil(store.decisionPaneID)

        let first = entry()
        store.message = "busy"
        store.decisionEntries = [first]
        try apply()
        XCTAssertNil(store.decisionPaneID, "A question must not replace another open surface")

        store.message = nil
        try apply()
        XCTAssertEqual(store.decisionPaneID, asking.id, "A question from a background pane must open its own card")
        XCTAssertEqual(store.preferredDecisionID, first.id)

        store.dismissDecisions()
        try apply()
        XCTAssertNil(store.decisionPaneID, "A dismissed question must not reopen on the next refresh")

        let second = entry()
        store.decisionEntries = [first, second]
        try apply()
        XCTAssertEqual(store.decisionPaneID, asking.id)
        XCTAssertEqual(store.preferredDecisionID, second.id)
    }
}
