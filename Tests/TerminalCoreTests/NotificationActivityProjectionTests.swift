import Foundation
import XCTest
@testable import TerminalCore

final class NotificationActivityProjectionTests: XCTestCase {
    // Implements: FR-NOTIFY-2
    func testIdleFilterAndGroupedTabRetainExactAttentionPaneTarget() throws {
        var layout = WorkspaceLayout(); layout.addTab(paneID: "running"); try layout.split(tabID: layout.tabs[0].id, paneID: "blocked", axis: .horizontal)
        layout.tabs[0].title = "Build"
        let sessions = [session("running", .running), session("blocked", .blocked), session("idle", .idle), session("unknown", .unknown)]
        var preferences = NotificationPreferences(); preferences.includeIdleProcesses = false
        XCTAssertEqual(Set(NotificationActivityProjection.rows(layout: layout, sessions: sessions, preferences: preferences).map(\.id)), ["running", "blocked"])
        preferences.showEachProcessInTabs = false
        let rows = NotificationActivityProjection.rows(layout: layout, sessions: sessions, preferences: preferences)
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.id, "blocked"); XCTAssertEqual(rows.first?.title, "Build")
    }

    // Implements: FR-NOTIFY-2
    func testUngroupedStandalonePaneSurvivesTabGrouping() {
        var layout = WorkspaceLayout(); layout.addTab(paneID: "running")
        var preferences = NotificationPreferences(); preferences.showEachProcessInTabs = false
        let rows = NotificationActivityProjection.rows(layout: layout, sessions: [session("running", .running), session("standalone", .done)], preferences: preferences)
        XCTAssertEqual(Set(rows.map(\.id)), ["running", "standalone"])
    }

    // Implements: FR-NOTIFY-2
    func testClosedTabAndClosedWorkspacePanesStayOutOfActivityWhileStandalonePanesRemain() throws {
        var layout = WorkspaceLayout()
        let first = layout.addWorkspace(title: "first")
        let openTab = layout.addTab(paneID: "open")
        try layout.split(tabID: openTab, paneID: "closed-pane", axis: .horizontal)
        layout.closePane("closed-pane")
        layout.addTab(paneID: "closed-tab")
        layout.closeTab(layout.tabs.first(where: { $0.panes.contains("closed-tab") })!.id)
        let second = layout.addWorkspace(title: "second")
        layout.addTab(paneID: "closed-workspace")
        layout.closeWorkspace(second)
        try layout.selectWorkspace(first)
        XCTAssertTrue(layout.tabs.contains(where: { $0.panes.contains("closed-workspace") }), "Closed workspace tabs stay retained")
        XCTAssertTrue(layout.isClosedPane("closed-pane")); XCTAssertTrue(layout.isClosedPane("closed-tab")); XCTAssertTrue(layout.isClosedPane("closed-workspace"))
        XCTAssertFalse(layout.isClosedPane("open")); XCTAssertFalse(layout.isClosedPane("standalone"))
        let sessions = ["open", "closed-pane", "closed-tab", "closed-workspace", "standalone"].map { session($0, .done) }
        for showEach in [true, false] {
            var preferences = NotificationPreferences(); preferences.showEachProcessInTabs = showEach
            let rows = NotificationActivityProjection.rows(layout: layout, sessions: sessions, preferences: preferences)
            XCTAssertEqual(Set(rows.map(\.id)), ["open", "standalone"], "showEachProcessInTabs=\(showEach)")
        }
        // A sibling kept in a split-close snapshot stays presentable after it leaves its tab without being closed.
        var detached = layout
        try detached.split(tabID: openTab, paneID: "keep", axis: .horizontal)
        detached.detach("open")
        XCTAssertFalse(detached.isClosedPane("open"), "A detached sibling of a closed split pane was never closed")
        XCTAssertTrue(detached.isClosedPane("closed-pane"))
        layout.restoreTab()
        XCTAssertFalse(layout.isClosedPane("closed-workspace"), "An explicit reopen of the last closed workspace makes its pane presentable again")
        XCTAssertTrue(layout.isClosedPane("closed-tab"), "Other closed tabs stay closed")
    }

    // Implements: FR-NOTIFY-2
    func testTabIndicatorObeysPerStateGlobalAndReadReceiptGates() {
        var layout = WorkspaceLayout(); layout.addTab(paneID: "pane")
        let pane = session("pane", .done); let tab = layout.tabs[0]
        var preferences = NotificationPreferences()
        XCTAssertEqual(NotificationActivityProjection.indicatorState(tab: tab, sessions: [pane], readAt: [:], preferences: preferences), .done)
        XCTAssertNil(NotificationActivityProjection.indicatorState(tab: tab, sessions: [pane], readAt: [pane.id: pane.activity.updatedAt], preferences: preferences))
        preferences.done.tabIndicator = false
        XCTAssertNil(NotificationActivityProjection.indicatorState(tab: tab, sessions: [pane], readAt: [:], preferences: preferences))
        preferences.done.tabIndicator = true; preferences.showActivityInTabs = false
        XCTAssertNil(NotificationActivityProjection.indicatorState(tab: tab, sessions: [pane], readAt: [:], preferences: preferences))
        preferences.showActivityInTabs = true; preferences.done.enabled = false
        XCTAssertNil(NotificationActivityProjection.indicatorState(tab: tab, sessions: [pane], readAt: [:], preferences: preferences))
    }

    // Implements: FR-NOTIFY-2
    func testRunningNeverShowsADotEvenWithLegacyWorkingIndicatorEnabled() throws {
        var layout = WorkspaceLayout(); layout.addTab(paneID: "pane")
        let preferences = try JSONDecoder().decode(NotificationPreferences.self,
            from: Data(#"{"working":{"enabled":true,"tabIndicator":true}}"#.utf8))
        var pane = session("pane", .done)
        XCTAssertEqual(NotificationActivityProjection.indicatorState(tab: layout.tabs[0], sessions: [pane], readAt: [:], preferences: preferences), .done)
        pane.activity.state = .running
        XCTAssertNil(NotificationActivityProjection.indicatorState(tab: layout.tabs[0], sessions: [pane], readAt: [:], preferences: preferences))
        XCTAssertEqual(ActivityInbox.sections([pane]).first?.id, "working")
        pane.activity.state = .done; pane.activity.updatedAt.addTimeInterval(1)
        let readAt = [pane.id: pane.activity.updatedAt.addingTimeInterval(-1)]
        XCTAssertEqual(NotificationActivityProjection.indicatorState(tab: layout.tabs[0], sessions: [pane], readAt: readAt, preferences: preferences), .done)
        XCTAssertNil(NotificationActivityProjection.indicatorState(tab: layout.tabs[0], sessions: [pane], readAt: [pane.id: pane.activity.updatedAt], preferences: preferences))
        XCTAssertTrue(preferences.working.tabIndicator, "Rendering must not rewrite stored preferences")
    }

    // Implements: FR-NOTIFY-2
    func testRunningPaneDoesNotMaskAnotherPanesCompletionOrAttention() throws {
        var layout = WorkspaceLayout(); layout.addTab(paneID: "running")
        try layout.split(tabID: layout.tabs[0].id, paneID: "other", axis: .horizontal)
        var preferences = NotificationPreferences(); preferences.working.tabIndicator = true
        for state in [ActivityState.done, .blocked, .error] {
            let panes = [session("running", .running), session("other", state)]
            XCTAssertEqual(NotificationActivityProjection.indicatorState(tab: layout.tabs[0], sessions: panes, readAt: [:], preferences: preferences), state)
        }
    }

    private func session(_ id: String, _ state: ActivityState) -> TerminalSession {
        var session = TerminalSession(id: id, title: id, cwd: "/fixture", pid: 0)
        session.activity.state = state; session.activity.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        return session
    }
}
