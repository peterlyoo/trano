import XCTest
@testable import TerminalCore
@testable import TranoApp

final class TerminalTitlePresentationPolicyTests: XCTestCase {
    // Implements: FR-SET-96
    func testTabAndHoverUseExplicitPreferenceAndManualTabTitleAlwaysWins() {
        var session = TerminalSession(id: "pane", title: "Stored pane name", cwd: "/tmp/project", pid: 1)
        session.terminalTitle = "OSC title"
        session.foregroundProgram = .codex
        var tab = TerminalTab(paneID: session.id)
        let before = session
        XCTAssertEqual(TabPresentation(tab: tab, sessions: [session]).title, "OSC title")
        XCTAssertEqual(TabPresentation(tab: tab, sessions: [session], preferGeneratedTitles: true).title, "codex · project")
        let hover = TabActivitySnapshot(tab: tab, sessions: [session], preferGeneratedTitles: true)
        XCTAssertEqual(hover.title, "codex · project")
        XCTAssertEqual(hover.panes.first?.title, "codex · project")
        tab.title = "Manual release tab"
        XCTAssertEqual(TabPresentation(tab: tab, sessions: [session], preferGeneratedTitles: true).title, "Manual release tab")
        XCTAssertEqual(TabActivitySnapshot(tab: tab, sessions: [session], preferGeneratedTitles: true).title, "Manual release tab")
        XCTAssertEqual(session, before)
    }

    // Implements: FR-SET-96
    func testFocusedPaneSelectionDrivesGeneratedTitleWithoutChangingLayoutOrTitles() {
        var first = TerminalSession(id: "first", title: "First stored", cwd: "/tmp/first", pid: 1)
        first.foregroundProgram = .claude
        var second = TerminalSession(id: "second", title: "Second stored", cwd: "/tmp/second", pid: 2)
        second.foregroundProgram = .codex
        var tab = TerminalTab(paneID: first.id)
        tab.tree = .split(id: "split", axis: .horizontal, ratio: 0.5, first: .pane(first.id), second: .pane(second.id))
        let before = tab
        XCTAssertEqual(TabPresentation(tab: tab, sessions: [first, second], focusedPaneID: second.id, preferGeneratedTitles: true).title, "codex · second")
        XCTAssertEqual(TabPresentation(tab: tab, sessions: [first, second], focusedPaneID: first.id, preferGeneratedTitles: true).title, "claude · first")
        XCTAssertEqual(tab, before)
        XCTAssertEqual(first.title, "First stored")
        XCTAssertEqual(second.title, "Second stored")
    }
}
