import AppKit
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class WorktreeCleanupSettingsTests: XCTestCase {
    // Implements: FR-WT-5
    @MainActor func testCleanupToggleIsVisibleIndependentlyAndUpdatesCurrentDraft() throws {
        _ = NSApplication.shared
        let view = IntegrationsSettingsNativeView(frame: .zero)
        var baseline = IntegrationsPreferences(); baseline.integrateWithAvailableAgents = false
        view.configure(preferences: baseline, available: [], installed: [], busy: false)
        let toggle = try XCTUnwrap(findToggle(in: view))
        XCTAssertTrue(toggle.isEnabled)
        XCTAssertEqual(toggle.state, .on)
        var result: IntegrationsPreferences?
        view.onChange = { result = $0 }
        toggle.performClick(nil)
        XCTAssertEqual(result?.automaticallyCleanWorktrees, false)
        XCTAssertEqual(result?.integrateWithAvailableAgents, false)
        view.configure(preferences: baseline, available: [.claude], installed: [], busy: true)
        XCTAssertTrue(findToggle(in: view) === toggle)
        XCTAssertFalse(toggle.isEnabled)
    }

    @MainActor private func findToggle(in view: NSView) -> NSButton? {
        if view.identifier?.rawValue == "integrations-worktree-cleanup" { return view as? NSButton }
        for child in view.subviews { if let button = findToggle(in: child) { return button } }
        return nil
    }
}
