import XCTest
@testable import TerminalCore

final class WorkspaceOrderTests: XCTestCase {
    // Implements: FR-NAV-8
    func testMoveUpSwapsAdjacentOpenWorkspacesAcrossClosedSlots() throws {
        var layout = fixture()
        var expected = layout
        expected.workspaces.swapAt(1, 4)

        try layout.reorderWorkspace("b", delta: -1)

        XCTAssertEqual(layout.workspaces.map(\.id), ["closed-start", "b", "closed-gap-1", "closed-gap-2", "a", "closed-gap-3", "c", "closed-end"])
        XCTAssertEqual(layout, expected)
    }

    // Implements: FR-NAV-8
    func testMoveDownSwapsAdjacentOpenWorkspacesAcrossClosedSlots() throws {
        var layout = fixture()
        var expected = layout
        expected.workspaces.swapAt(4, 6)

        try layout.reorderWorkspace("b", delta: 1)

        XCTAssertEqual(layout.workspaces.map(\.id), ["closed-start", "a", "closed-gap-1", "closed-gap-2", "c", "closed-gap-3", "b", "closed-end"])
        XCTAssertEqual(layout, expected)
    }

    // Implements: FR-NAV-8
    func testBoundaryMovesAndSingleOpenWorkspaceLeaveLayoutUnchanged() throws {
        var layout = fixture()
        let before = layout
        try layout.reorderWorkspace("a", delta: -1)
        XCTAssertEqual(layout, before)
        try layout.reorderWorkspace("c", delta: 1)
        XCTAssertEqual(layout, before)

        for index in layout.workspaces.indices { layout.workspaces[index].closed = layout.workspaces[index].id != "a" }
        let single = layout
        try layout.reorderWorkspace("a", delta: -1)
        try layout.reorderWorkspace("a", delta: 1)
        XCTAssertEqual(layout, single)
    }

    // Implements: FR-NAV-8
    func testInvalidDeltasThrowWithoutMutatingLayout() {
        var layout = fixture()
        let before = layout
        for delta in [0, 2, -2, Int.min, Int.max] {
            XCTAssertThrowsError(try layout.reorderWorkspace("b", delta: delta)) { error in
                guard case TerminalError.invalid = error else { return XCTFail("Expected invalid delta, got \(error)") }
            }
            XCTAssertEqual(layout, before)
        }
    }

    // Implements: FR-NAV-8
    func testClosedMissingAndEmptyTargetsThrowWithoutMutatingLayout() {
        var layout = fixture()
        let before = layout
        for id in ["closed-start", "closed-gap-1", "closed-end", "missing"] {
            for delta in [-1, 1] {
                XCTAssertThrowsError(try layout.reorderWorkspace(id, delta: delta)) { error in
                    guard case TerminalError.invalid = error else { return XCTFail("Expected invalid workspace, got \(error)") }
                }
                XCTAssertEqual(layout, before)
            }
        }
        var empty = WorkspaceLayout()
        XCTAssertThrowsError(try empty.reorderWorkspace("missing", delta: 1))
        XCTAssertEqual(empty, WorkspaceLayout())
    }

    // Implements: FR-NAV-4, FR-NAV-8
    func testReorderedLayoutRoundTripsAndSessionCycleUsesDurableOrder() throws {
        var layout = fixture()
        var expected = layout
        expected.workspaces.swapAt(4, 6)
        try layout.reorderWorkspace("b", delta: 1)
        XCTAssertEqual(layout, expected)

        let restored = try JSONDecoder().decode(WorkspaceLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(restored, expected)
        var navigation = restored
        navigation.cycleWorkspace(1)
        XCTAssertEqual(navigation.selectedWorkspaceID, "c")
        XCTAssertEqual(navigation.selectedTabID, "c-tab")
        XCTAssertEqual(navigation.focusedPaneID, "c-right")
        navigation.cycleWorkspace(1)
        XCTAssertEqual(navigation.selectedWorkspaceID, "b")
        XCTAssertEqual(navigation.selectedTabID, "b-tab")
        XCTAssertEqual(navigation.focusedPaneID, "b-right")
        XCTAssertEqual(navigation.tabs, expected.tabs)
        XCTAssertEqual(navigation.closedTabs, expected.closedTabs)
    }

    private func fixture() -> WorkspaceLayout {
        var layout = WorkspaceLayout()
        for id in ["closed-start", "a", "closed-gap-1", "closed-gap-2", "b", "closed-gap-3", "c", "closed-end"] {
            var workspace = WorkspaceRecord(title: "Session \(id)")
            workspace.id = id
            workspace.selectedTabID = "\(id)-tab"
            workspace.focusedPaneID = "\(id)-right"
            workspace.collapsed = id == "b"
            workspace.closed = id.hasPrefix("closed-")
            layout.workspaces.append(workspace)

            var tab = TerminalTab(paneID: "\(id)-left")
            tab.id = "\(id)-tab"
            tab.workspaceID = id
            tab.focusedPaneID = "\(id)-right"
            tab.tree = .split(id: "\(id)-split", axis: .vertical, ratio: 0.37, first: .pane("\(id)-left"), second: .pane("\(id)-right"))
            layout.tabs.append(tab)
        }
        var closedTab = TerminalTab(paneID: "retained-pane")
        closedTab.id = "retained-tab"
        closedTab.workspaceID = "a"
        layout.closedTabs = [closedTab]
        layout.selectedWorkspaceID = "a"
        layout.selectedTabID = "a-tab"
        layout.focusedPaneID = "a-right"
        return layout
    }
}
