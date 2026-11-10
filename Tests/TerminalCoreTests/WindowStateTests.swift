import XCTest
@testable import TerminalCore

final class WindowStateTests: XCTestCase {
    // Implements: FR-NAV-1, FR-NAV-6
    func testPassiveRefreshKeepsEachWindowWorkspaceAndExternalFocusIsExplicit() throws {
        var state = RuntimeState()
        let first = state.layout.addWorkspace(title: "One")
        state.layout.addTab(paneID: "a")
        var a = WindowSelection(), b = WindowSelection()
        _ = a.resolve(state, ownAction: false, acceptsRequests: true)
        let second = state.layout.addWorkspace(title: "Two")
        state.layout.addTab(paneID: "b")
        _ = b.resolve(state, ownAction: true, acceptsRequests: true)
        XCTAssertEqual(a.resolve(state, ownAction: false, acceptsRequests: true).layout.selectedWorkspaceID, first)
        XCTAssertEqual(b.resolve(state, ownAction: false, acceptsRequests: false).layout.selectedWorkspaceID, second)
        try state.layout.selectWorkspace(second)
        state.navigationRequest = NavigationRequest(workspaceID: second)
        XCTAssertEqual(a.resolve(state, ownAction: false, acceptsRequests: true).layout.selectedWorkspaceID, second)
        try state.layout.selectWorkspace(first)
        XCTAssertEqual(a.resolve(state, ownAction: false, acceptsRequests: true).layout.selectedWorkspaceID, second)
    }

    // Implements: FR-CORE-4
    func testSettingsMigrationAndDraftMergePreserveConcurrentEdits() throws {
        let old = try JSONDecoder().decode(TerminalSettings.self, from: Data(#"{"fontName":"Menlo","fontSize":16}"#.utf8))
        XCTAssertEqual(old.fontName, "Menlo")
        XCTAssertTrue(old.notifications)
        var current = TerminalSettings(), draft = TerminalSettings()
        current.fontSize = 22
        draft.background = "#101010"
        current.merge(draft, from: TerminalSettings())
        XCTAssertEqual(current.fontSize, 22)
        XCTAssertEqual(current.background, "#101010")
    }
}
