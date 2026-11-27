import XCTest
@testable import TerminalCore

final class LastTabCloseTests: XCTestCase {
    // Implements: FR-NAV-4, FR-NAV-6
    func testLastTabSelectsTheNextWorkspaceAndItsRememberedPane() throws {
        var layout = WorkspaceLayout()
        let first = layout.addWorkspace(title: "First")
        layout.addTab(paneID: "first")
        let middle = layout.addWorkspace(title: "Middle")
        let closing = layout.addTab(paneID: "middle")
        let next = layout.addWorkspace(title: "Next")
        let nextTab = layout.addTab(paneID: "next")
        try layout.split(tabID: nextTab, paneID: "next-focused", axis: .horizontal)
        try layout.selectWorkspace(middle)

        layout.closeTab(closing)

        XCTAssertEqual(layout.selectedWorkspaceID, next)
        XCTAssertNotEqual(layout.selectedWorkspaceID, first)
        XCTAssertEqual(layout.selectedTabID, nextTab)
        XCTAssertEqual(layout.focusedPaneID, "next-focused")
        XCTAssertTrue(try XCTUnwrap(layout.workspaces.first { $0.id == middle }).closed)
        XCTAssertEqual(layout.closedTabs.last?.id, closing)
    }

    // Implements: FR-NAV-4, FR-NAV-6
    func testLastTabWrapsPastClosedWorkspacesWithoutReopeningThem() throws {
        var layout = WorkspaceLayout()
        let hidden = layout.addWorkspace(title: "Hidden")
        layout.addTab(paneID: "hidden")
        let next = layout.addWorkspace(title: "Next")
        let nextTab = layout.addTab(paneID: "next")
        let last = layout.addWorkspace(title: "Last")
        let closing = layout.addTab(paneID: "last")
        layout.closeWorkspace(hidden)
        try layout.selectWorkspace(last)

        layout.closeTab(closing)

        XCTAssertEqual(layout.selectedWorkspaceID, next)
        XCTAssertEqual(layout.selectedTabID, nextTab)
        XCTAssertTrue(try XCTUnwrap(layout.workspaces.first { $0.id == hidden }).closed)
    }

    // Implements: FR-NAV-4, FR-NAV-6
    func testClosingAnInactiveWorkspacesLastTabKeepsTheCurrentSelection() throws {
        var layout = WorkspaceLayout()
        let inactive = layout.addWorkspace(title: "Inactive")
        let closing = layout.addTab(paneID: "inactive")
        let active = layout.addWorkspace(title: "Active")
        let activeTab = layout.addTab(paneID: "active")

        layout.closeTab(closing)

        XCTAssertEqual(layout.selectedWorkspaceID, active)
        XCTAssertEqual(layout.selectedTabID, activeTab)
        XCTAssertEqual(layout.focusedPaneID, "active")
        XCTAssertTrue(try XCTUnwrap(layout.workspaces.first { $0.id == inactive }).closed)
    }

    // Implements: FR-NAV-4, FR-NAV-6
    func testPassiveMirrorSelectsItsClosedWorkspacesSuccessorInsteadOfAnotherWindowsSelection() throws {
        var state = RuntimeState()
        let first = state.layout.addWorkspace(title: "First")
        state.layout.addTab(paneID: "first")
        let closingWorkspace = state.layout.addWorkspace(title: "Closing")
        let closingTab = state.layout.addTab(paneID: "closing")
        let next = state.layout.addWorkspace(title: "Next")
        let nextTab = state.layout.addTab(paneID: "next")
        let unrelated = state.layout.addWorkspace(title: "Unrelated")
        state.layout.addTab(paneID: "unrelated")
        try state.layout.selectWorkspace(closingWorkspace)
        var mirror = WindowSelection()
        _ = mirror.resolve(state, ownAction: false, acceptsRequests: false)
        try state.layout.selectWorkspace(first)
        var independent = WindowSelection()
        _ = independent.resolve(state, ownAction: false, acceptsRequests: false)
        try state.layout.selectWorkspace(unrelated)

        state.layout.closeTab(closingTab)

        let resolved = mirror.resolve(state, ownAction: false, acceptsRequests: false)
        XCTAssertEqual(resolved.layout.selectedWorkspaceID, next)
        XCTAssertEqual(resolved.layout.selectedTabID, nextTab)
        XCTAssertEqual(independent.resolve(state, ownAction: false, acceptsRequests: false).layout.selectedWorkspaceID, first)
        XCTAssertEqual(state.layout.selectedWorkspaceID, unrelated)
    }

    // Implements: FR-NAV-4, FR-NAV-6
    func testFinalTabClearsSelectionAndCanRestoreTheSameWorkspaceAndPane() throws {
        var layout = WorkspaceLayout()
        let workspace = layout.addWorkspace(title: "Final")
        let tab = layout.addTab(paneID: "retained")
        layout.closeTab(tab)
        XCTAssertNil(layout.selectedWorkspaceID)
        XCTAssertNil(layout.selectedTabID)
        XCTAssertNil(layout.focusedPaneID)
        var snapshot = RuntimeState()
        snapshot.layout = layout
        var selection = WindowSelection()
        for _ in 0..<3 {
            snapshot = selection.resolve(snapshot, ownAction: false, acceptsRequests: false)
            XCTAssertNil(snapshot.layout.selectedWorkspaceID)
        }

        layout.restoreTab()

        XCTAssertEqual(layout.selectedWorkspaceID, workspace)
        XCTAssertEqual(layout.selectedTabID, tab)
        XCTAssertEqual(layout.focusedPaneID, "retained")
        XCTAssertFalse(try XCTUnwrap(layout.workspaces.first).closed)
    }

    // Implements: FR-NAV-4, FR-NAV-6
    func testClosingANonfinalTabStaysWithinItsWorkspace() throws {
        var layout = WorkspaceLayout()
        let workspace = layout.addWorkspace(title: "Current")
        let remaining = layout.addTab(paneID: "remaining")
        let closing = layout.addTab(paneID: "closing")
        layout.addWorkspace(title: "Other")
        layout.addTab(paneID: "other")
        try layout.selectTab(closing)

        layout.closeTab(closing)

        XCTAssertEqual(layout.selectedWorkspaceID, workspace)
        XCTAssertEqual(layout.selectedTabID, remaining)
        XCTAssertFalse(try XCTUnwrap(layout.workspaces.first).closed)
    }

    // Implements: FR-NAV-4, FR-NAV-6
    func testTransferDetachDoesNotCloseTheWorkspaceOrRecordAClosedTab() throws {
        var layout = WorkspaceLayout()
        let workspace = layout.addWorkspace(title: "Source")
        layout.addTab(paneID: "moving")

        layout.detach("moving")

        XCTAssertEqual(layout.selectedWorkspaceID, workspace)
        XCTAssertFalse(try XCTUnwrap(layout.workspaces.first).closed)
        XCTAssertTrue(layout.closedTabs.isEmpty)
    }
}
