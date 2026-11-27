import XCTest
@testable import TerminalCore

final class WorkspaceLaunchSelectionTests: XCTestCase {
    // Implements: FR-NAV-1, FR-NAV-4, REQ-014
    func testMissingProjectMatchCreatesRandomWorkspaceWithoutChangingExistingNames() throws {
        var layout = WorkspaceLayout()
        let old = layout.addWorkspace(title: "My Manual 프로젝트")
        layout.addTab(paneID: "unrelated-pane")
        let before = layout
        let selected = try layout.selectProjectWorkspace(projectPaneIDs: ["new-project-pane"])
        XCTAssertNotEqual(selected, old)
        XCTAssertEqual(layout.workspaces.first, before.workspaces.first)
        XCTAssertEqual(layout.tabs, before.tabs)
        XCTAssertEqual(layout.selectedWorkspaceID, selected)
        XCTAssertNil(layout.selectedTabID)
        XCTAssertNil(layout.focusedPaneID)
        assertRandomPair(try XCTUnwrap(layout.workspaces.last?.title))
    }

    // Implements: FR-NAV-1, FR-NAV-4, REQ-014
    func testOpenMatchingProjectWorkspaceIsReusedWithItsManualNameAndExistingPane() throws {
        var layout = WorkspaceLayout()
        let project = layout.addWorkspace(title: "Project With Manual Name")
        let tab = layout.addTab(paneID: "project-pane")
        layout.addWorkspace(title: "Other")
        let before = layout
        XCTAssertEqual(try layout.selectProjectWorkspace(projectPaneIDs: ["project-pane"]), project)
        XCTAssertEqual(layout.workspaces, before.workspaces)
        XCTAssertEqual(layout.tabs, before.tabs)
        XCTAssertEqual(layout.selectedTabID, tab)
        XCTAssertEqual(layout.focusedPaneID, "project-pane")
    }

    // Implements: FR-NAV-1, FR-NAV-4, REQ-014
    func testClosedMatchingProjectWorkspaceStaysClosedWithRetainedTabs() throws {
        var layout = WorkspaceLayout()
        let closed = layout.addWorkspace(title: "Closed Manual Name")
        layout.addTab(paneID: "closed-project-pane")
        layout.closeWorkspace(closed)
        let before = layout
        let selected = try layout.selectProjectWorkspace(projectPaneIDs: ["closed-project-pane"])
        XCTAssertNotEqual(selected, closed)
        XCTAssertEqual(layout.workspaces.first, before.workspaces.first)
        XCTAssertTrue(try XCTUnwrap(layout.workspaces.first).closed)
        XCTAssertEqual(layout.tabs, before.tabs)
        XCTAssertEqual(layout.closedTabs, before.closedTabs)
        assertRandomPair(try XCTUnwrap(layout.workspaces.last?.title))
    }

    // Implements: FR-NAV-1, FR-NAV-4, REQ-014
    func testEarlierClosedMatchDoesNotHideLaterOpenProjectWorkspace() throws {
        var layout = WorkspaceLayout()
        let closed = layout.addWorkspace(title: "Closed Project")
        layout.addTab(paneID: "closed-pane")
        layout.closeWorkspace(closed)
        let open = layout.addWorkspace(title: "Open Project")
        layout.addTab(paneID: "open-pane")
        let before = layout
        XCTAssertEqual(try layout.selectProjectWorkspace(projectPaneIDs: ["closed-pane", "open-pane"]), open)
        XCTAssertEqual(layout.workspaces, before.workspaces)
        XCTAssertEqual(layout.tabs, before.tabs)
        XCTAssertEqual(layout.closedTabs, before.closedTabs)
    }

    // Implements: FR-NAV-1, FR-NAV-4, REQ-014
    func testUnownedMatchingTabCannotSelectOrReopenMissingWorkspace() throws {
        for workspaceID in [nil, "missing-workspace"] as [String?] {
            var layout = WorkspaceLayout()
            layout.addWorkspace(title: "Missing Owner")
            layout.addTab(paneID: "project-pane")
            layout.tabs[0].workspaceID = workspaceID
            layout.workspaces.removeAll()
            layout.selectedWorkspaceID = nil
            layout.selectedTabID = nil
            layout.focusedPaneID = nil
            let beforeTabs = layout.tabs
            let selected = try layout.selectProjectWorkspace(projectPaneIDs: ["project-pane"])
            XCTAssertNotEqual(selected, "missing-workspace")
            XCTAssertEqual(layout.tabs, beforeTabs)
            assertRandomPair(try XCTUnwrap(layout.workspaces.last?.title))
        }
    }

    // Implements: FR-NAV-1, REQ-014
    func testCompleteNormalPoolUsesUniqueTwoSegmentAlphabeticNames() {
        var layout = occupiedNormalPool()
        let before = layout
        let title = layout.randomWorkspaceTitle()
        assertRandomPair(title)
        XCTAssertFalse(occupiedNames(layout).contains(title))
        XCTAssertEqual(layout, before)
        for _ in 0..<200 {
            let next = layout.randomWorkspaceTitle()
            assertRandomPair(next)
            XCTAssertFalse(occupiedNames(layout).contains(next))
            layout.addWorkspace(title: next)
        }
    }

    // Implements: FR-NAV-1, REQ-014
    func testUnusedDictionaryPairIsChosenBeforeAlphabeticOverflow() {
        var layout = occupiedNormalPool()
        layout.workspaces.removeAll { $0.title == "warm-river" }
        for _ in 0..<64 { XCTAssertEqual(layout.randomWorkspaceTitle(), "warm-river") }
    }

    // Implements: FR-NAV-1, REQ-014
    func testMixedCaseLegacyTitlesAndAlphabeticSuffixesRemainReservedAndUnchanged() {
        var layout = occupiedNormalPool()
        for index in layout.workspaces.indices {
            layout.workspaces[index].title = "  " + layout.workspaces[index].title.uppercased() + "\n"
        }
        for name in Array(occupiedNames(layout)) {
            for suffix in ["a", "b", "z", "aa"] { layout.addWorkspace(title: " " + (name + suffix).uppercased() + " ") }
        }
        layout.addWorkspace(title: "My Manual Name")
        layout.addWorkspace(title: "old-name-2")
        let before = layout
        for _ in 0..<32 {
            let next = layout.randomWorkspaceTitle()
            assertRandomPair(next)
            XCTAssertFalse(occupiedNames(layout).contains(next))
        }
        XCTAssertEqual(layout, before)
    }

    // Implements: FR-NAV-1, REQ-014
    func testAlphabeticOverflowCrossesZAndAaWithoutNumericOrThirdSegments() {
        var layout = occupiedNormalPool()
        for name in Array(occupiedNames(layout)) {
            for byte in UInt8(97)...UInt8(122) {
                layout.addWorkspace(title: name + String(decoding: [byte], as: UTF8.self))
            }
            layout.addWorkspace(title: name + "aa")
        }
        let next = layout.randomWorkspaceTitle()
        assertRandomPair(next)
        XCTAssertTrue(next.hasSuffix("ab"), next)
        XCTAssertFalse(occupiedNames(layout).contains(next))
    }

    // Implements: FR-NAV-1, REQ-014
    func testBlankSessionRequestsUseRandomPairPathWhileExplicitTitlesRemainVerbatim() throws {
        let layout = WorkspaceLayout()
        for request in [nil, "", " \n\t "] as [String?] {
            let normalized = try WorkspaceLayout.normalizedSessionTitle(request)
            XCTAssertNil(normalized)
            assertRandomPair(normalized ?? layout.randomWorkspaceTitle())
        }
        XCTAssertEqual(try WorkspaceLayout.normalizedSessionTitle(" My Named Workspace "), "My Named Workspace")
    }

    private func occupiedNormalPool() -> WorkspaceLayout {
        var layout = WorkspaceLayout()
        for adjective in ["amber", "bright", "calm", "clear", "quiet", "silver", "soft", "warm"] {
            for noun in ["cedar", "comet", "harbor", "maple", "meadow", "orbit", "pine", "river"] {
                layout.addWorkspace(title: adjective + "-" + noun)
            }
        }
        return layout
    }

    private func occupiedNames(_ layout: WorkspaceLayout) -> Set<String> {
        Set(layout.workspaces.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
    }

    private func assertRandomPair(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(title.range(of: "^[a-z]+-[a-z]+$", options: .regularExpression), title, file: file, line: line)
    }
}
