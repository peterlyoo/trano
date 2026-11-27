import XCTest
@testable import TerminalCore

final class TerminalNavigationPolicyTests: XCTestCase {
    // Implements: FR-SET-84
    func testCanonicalFullBindingsKeepSingleAndTwoOrThreeStrokeSequences() throws {
        let overrides = [ActionID.newTab.rawValue: ["CTRL+x, CTRL+t", "ctrl+x,ctrl+c,ctrl+t"], ActionID.splitRight.rawValue: ["ctrl+alt+d"]]
        let map = try TerminalKeySequenceMap(overrides: overrides)
        XCTAssertEqual(map.bindings[ActionID.newTab.rawValue], ["ctrl+x,ctrl+t", "ctrl+x,ctrl+c,ctrl+t"])
        XCTAssertEqual(map.bindings[ActionID.splitRight.rawValue], ["ctrl+alt+d"])
        XCTAssertNil(map.singles.action(for: "cmd+t"))
        XCTAssertEqual(map.singles.action(for: "ctrl+alt+d"), .splitRight)
        let action = try XCTUnwrap(ActionCatalog.resolved(overrides: overrides).first { $0.action == .newTab })
        XCTAssertEqual(action.bindings, map.bindings[ActionID.newTab.rawValue])
    }

    // Implements: FR-SET-84
    func testDefaultCatalogAndSingleMapStayIdenticalWhenNoSequencesExist() throws {
        XCTAssertEqual(try TerminalKeySequenceMap().bindings, try KeyBindingMap().bindings)
        let actions = try ActionCatalog.resolved(overrides: [:])
        XCTAssertEqual(actions.first { $0.action == .newTab }?.bindings, ["cmd+t"])
    }

    // Implements: FR-SET-84
    func testSequenceValidationStillRejectsReservedAmbiguousAndUnmodifiedStrokes() {
        for overrides in [
            [ActionID.newTab.rawValue: ["cmd+q,ctrl+t"]],
            [ActionID.newTab.rawValue: ["cmd+k,ctrl+t"]],
            [ActionID.newTab.rawValue: ["ctrl+x,t"]],
            [ActionID.newTab.rawValue: ["ctrl+x,ctrl+t"], ActionID.splitRight.rawValue: ["ctrl+x,ctrl+t,ctrl+d"]]
        ] { XCTAssertThrowsError(try TerminalKeySequenceMap(overrides: overrides)) }
    }

    // Implements: FR-SET-84
    func testCommaShortcutAndCommaStrokeRemainDistinctFromSequenceSeparators() throws {
        let explicit = try TerminalKeySequenceMap(overrides: [ActionID.settings.rawValue: ["cmd+,"]])
        XCTAssertEqual(explicit.singles.action(for: "cmd+,"), .settings)
        XCTAssertEqual(explicit.bindings[ActionID.settings.rawValue], ["cmd+,"])
        let sequence = try TerminalKeySequenceMap(overrides: [ActionID.newTab.rawValue: ["ctrl+x,ctrl+,"]])
        XCTAssertEqual(sequence.action(for: ["ctrl+x", "ctrl+,"]), .newTab)
        XCTAssertThrowsError(try TerminalKeySequenceMap(overrides: [ActionID.newTab.rawValue: ["ctrl+x,,ctrl+t"]]))
    }

    // Implements: FR-SET-96
    func testDefaultsPreserveExistingShellAndAgentOSCDisplay() throws {
        XCTAssertFalse(TerminalPreferences().preferGeneratedTitles)
        XCTAssertFalse(ResolvedTerminalPreferences().preferGeneratedTitles)
        for agent in AgentKind.allCases {
            var session = TerminalSession(id: "pane", title: "Stored title", cwd: "/tmp/project", pid: 1)
            session.agent = agent
            session.terminalTitle = "Actual OSC · 한글"
            XCTAssertEqual(session.displayTitle(preferGeneratedTitles: false), session.displayTitle)
            XCTAssertEqual(session.displayTitle(preferGeneratedTitles: false), "Actual OSC · 한글")
        }
        XCTAssertFalse(try JSONDecoder().decode(TerminalPreferences.self, from: Data("{}".utf8)).preferGeneratedTitles)
    }

    // Implements: FR-SET-96
    func testEnabledTitlePreferenceUsesActualProgramAndDirectoryWithoutMutation() {
        var session = TerminalSession(id: "pane", title: "Stored title", cwd: "/tmp/한글 project", pid: 1)
        session.foregroundProgram = .codex
        session.terminalTitle = "Shell title"
        let before = session
        XCTAssertEqual(session.displayTitle(preferGeneratedTitles: true), "codex · 한글 project")
        XCTAssertEqual(session, before)
        XCTAssertEqual(session.displayTitle, "Shell title")
    }

    // Implements: FR-SET-96
    func testManualTitleWinsAndBlankOrOversizedMetadataFallsBackSafely() {
        XCTAssertEqual(TerminalTitlePolicy.displayTitle(manualTitle: "Manual tab", generatedTitle: "codex · repo", terminalTitle: "OSC", fallbackTitle: "Terminal", preferGeneratedTitles: true), "Manual tab")
        XCTAssertEqual(TerminalTitlePolicy.displayTitle(generatedTitle: "codex · repo", terminalTitle: "OSC", fallbackTitle: "Stored", preferGeneratedTitles: false), "OSC")
        XCTAssertEqual(TerminalTitlePolicy.displayTitle(generatedTitle: nil, terminalTitle: " \n ", fallbackTitle: "Stored", preferGeneratedTitles: false), "Stored")
        XCTAssertEqual(TerminalTitlePolicy.displayTitle(generatedTitle: String(repeating: "x", count: 8193), terminalTitle: "Fallback OSC", fallbackTitle: "Stored", preferGeneratedTitles: true), "Fallback OSC")
        XCTAssertEqual(TerminalTitlePolicy.displayTitle(generatedTitle: nil, terminalTitle: nil, fallbackTitle: "", preferGeneratedTitles: false), "Terminal")
        XCTAssertEqual(TerminalTitlePolicy.generatedTitle(program: .zsh, directory: "/"), "zsh · /")
        XCTAssertEqual(TerminalTitlePolicy.generatedTitle(program: .shell, directory: ""), "shell")
    }
}
