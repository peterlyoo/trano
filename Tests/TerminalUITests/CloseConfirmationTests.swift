import XCTest
import AppKit
@testable import TranoApp
@testable import TerminalCore

final class CloseConfirmationTests: XCTestCase {
    private func fixture(_ states: [(AgentKind, ActivityState)]) -> (RuntimeState, [TerminalSession], HeaderMenuContext, String) {
        var layout = WorkspaceLayout()
        let workspace = layout.addWorkspace(title: "w")
        var sessions: [TerminalSession] = []
        var tabID = ""
        for (index, (agent, activity)) in states.enumerated() {
            var session = TerminalSession(id: UUID().uuidString.lowercased(), title: "pane\(index)", cwd: "/tmp", pid: 0, agent: agent)
            session.activity.state = activity
            session.activity.updatedAt = Date(timeIntervalSince1970: 100)
            sessions.append(session)
            if index == 0 { tabID = layout.addTab(paneID: session.id) }
            else { try? layout.split(tabID: tabID, paneID: session.id, axis: .horizontal) }
        }
        var state = RuntimeState()
        state.layout = layout
        return (state, sessions, HeaderMenuContext(workspaceID: workspace, tabID: tabID, paneID: sessions[0].id), tabID)
    }

    func testIdleShellClosesWithoutConfirmation() {
        let (state, sessions, context, _) = fixture([(.shell, .idle)])
        XCTAssertNil(CloseConfirmation.reason(.closePane, context: context, state: state, sessions: sessions, preferGeneratedTitles: false))
    }

    func testWorkingWaitingAndUnreadDoneAgentsRequireConfirmation() {
        for activity in [ActivityState.running, .blocked, .done] {
            let (state, sessions, context, _) = fixture([(.claude, activity)])
            let reason = CloseConfirmation.reason(.closePane, context: context, state: state, sessions: sessions, preferGeneratedTitles: false)
            XCTAssertEqual(reason?.title, "Close this pane?")
            XCTAssertTrue(reason?.detail.contains("Claude") == true, activity.rawValue)
        }
    }

    func testReadDoneDoesNotAskAgain() {
        var (state, sessions, context, _) = fixture([(.codex, .done)])
        state.activityReadAt[sessions[0].id] = Date(timeIntervalSince1970: 200)
        XCTAssertNil(CloseConfirmation.reason(.closePane, context: context, state: state, sessions: sessions, preferGeneratedTitles: false))
    }

    func testTabCloseCountsEveryPaneAndOtherPanesSkipsTheKeptPane() {
        let (state, sessions, context, _) = fixture([(.shell, .idle), (.claude, .running)])
        XCTAssertEqual(CloseConfirmation.reason(.closeTab, context: context, state: state, sessions: sessions, preferGeneratedTitles: false)?.title, "Close this tab?")
        XCTAssertNil(CloseConfirmation.reason(.closePane, context: context, state: state, sessions: sessions, preferGeneratedTitles: false))
        XCTAssertNotNil(CloseConfirmation.reason(.closeOtherPanes, context: context, state: state, sessions: sessions, preferGeneratedTitles: false))
    }

    @MainActor func testCancelKeepsAndCloseProceeds() {
        let reason = CloseConfirmation.Reason(title: "t", detail: "d")
        XCTAssertFalse(CloseConfirmation.confirm(reason) { _ in .alertSecondButtonReturn })
        XCTAssertTrue(CloseConfirmation.confirm(reason) { alert in
            XCTAssertTrue(alert.buttons[0].hasDestructiveAction)
            return .alertFirstButtonReturn
        })
    }
}
