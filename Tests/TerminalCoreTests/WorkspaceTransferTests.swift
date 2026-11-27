import XCTest
@testable import TerminalCore

final class WorkspaceTransferTests: XCTestCase {
    // Implements: FR-NAV-4
    func testMovingTabPreservesCompleteSplitIdentityAndRepairsSourceSelection() throws {
        var layout = WorkspaceLayout()
        let source = layout.addWorkspace(title: "Source")
        let tabID = layout.addTab(paneID: "one")
        try layout.split(tabID: tabID, paneID: "two", axis: .vertical)
        let other = layout.addTab(paneID: "other")
        try layout.selectTab(tabID)
        let tree = try XCTUnwrap(layout.tabs.first { $0.id == tabID }?.tree)
        let target = layout.addWorkspace(title: "Destination")
        let targetTab = layout.addTab(paneID: "three")
        try layout.transferTab(tabID, from: source, to: target, before: targetTab)
        let moved = try XCTUnwrap(layout.tabs.first { $0.id == tabID })
        XCTAssertEqual(moved.tree, tree)
        XCTAssertEqual(moved.focusedPaneID, "two")
        XCTAssertEqual(layout.currentTabs.map(\.id), [tabID, targetTab])
        XCTAssertEqual(layout.workspaces.first { $0.id == source }?.selectedTabID, other)
        XCTAssertEqual(layout.workspaces.first { $0.id == source }?.focusedPaneID, "other")
        XCTAssertEqual(layout.closedTabs.count, 0)
    }

    // Implements: FR-NAV-4
    func testInvalidTabTransferCannotPartiallyMutateEitherWorkspace() throws {
        var layout = WorkspaceLayout()
        let source = layout.addWorkspace(title: "Source")
        let tabID = layout.addTab(paneID: "one")
        let target = layout.addWorkspace(title: "Destination")
        let targetTab = layout.addTab(paneID: "two")
        let before = layout
        for (from, to, neighbor) in [("missing", target, targetTab), (source, "missing", targetTab), (source, target, tabID), (source, target, "missing")] {
            XCTAssertThrowsError(try layout.transferTab(tabID, from: from, to: to, before: neighbor))
            XCTAssertEqual(layout, before)
        }
    }

    // Implements: FR-NAV-4
    func testFinalPaneMovesToNewDestinationTabAndLeavesSourceWorkspaceEmpty() throws {
        var layout = WorkspaceLayout()
        let source = layout.addWorkspace(title: "Source")
        let sourceTab = layout.addTab(paneID: "one")
        let target = layout.addWorkspace(title: "Destination")
        let targetTab = layout.addTab(paneID: "two")
        let newTab = try layout.transferPane("one", from: sourceTab, sourceWorkspaceID: source, to: target, tabID: nil)
        XCTAssertNotEqual(newTab, sourceTab)
        XCTAssertEqual(layout.currentTabs.map(\.id), [targetTab, newTab])
        XCTAssertEqual(layout.tabs.first { $0.id == newTab }?.panes, ["one"])
        XCTAssertFalse(layout.tabs.contains { $0.id == sourceTab })
        XCTAssertEqual(layout.workspaces.first { $0.id == source }?.closed, false)
        XCTAssertNil(layout.workspaces.first { $0.id == source }?.selectedTabID)
        XCTAssertNil(layout.workspaces.first { $0.id == source }?.focusedPaneID)
    }

    // Implements: FR-NAV-4
    func testPaneTransferValidatesOriginalTabAndTargetBeforeMutation() throws {
        var layout = WorkspaceLayout()
        let source = layout.addWorkspace(title: "Source")
        let sourceTab = layout.addTab(paneID: "one")
        let target = layout.addWorkspace(title: "Destination")
        let targetTab = layout.addTab(paneID: "two")
        let before = layout
        XCTAssertThrowsError(try layout.transferPane("one", from: targetTab, sourceWorkspaceID: source, to: target, tabID: targetTab))
        XCTAssertEqual(layout, before)
        XCTAssertThrowsError(try layout.transferPane("one", from: sourceTab, sourceWorkspaceID: source, to: target, tabID: sourceTab))
        XCTAssertEqual(layout, before)
        XCTAssertThrowsError(try layout.transferPane("one", from: sourceTab, sourceWorkspaceID: target, to: target, tabID: targetTab))
        XCTAssertEqual(layout, before)
    }
}
