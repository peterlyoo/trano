import AppKit
import XCTest
import TerminalCore
@testable import TranoApp

final class SettingsKeySequenceDraftTests: XCTestCase {
    // Implements: FR-SET-84
    @MainActor func testTwoAndThreeStrokeDraftsValidateAndSaveThroughExistingAPI() throws {
        for binding in ["ctrl+alt+k,ctrl+alt+m", "ctrl+alt+k,ctrl+alt+m,ctrl+alt+n"] {
            var settings = TerminalSettings()
            settings.fontName = NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular).fontName
            settings.keyBindings[ActionID.newTab.rawValue] = [binding]
            let draft = SettingsDraft(settings: settings, automaticallyChecksForUpdates: false, automaticallyDownloadsUpdates: false)
            XCTAssertNoThrow(try draft.validate())
            var writes = 0
            XCTAssertNoThrow(try draft.save(persist: { edited, baseline in
                writes += 1; XCTAssertEqual(edited.keyBindings, settings.keyBindings); XCTAssertEqual(baseline, settings)
            }, updateChecks: { _ in XCTFail("Unchanged checks") }, updateDownloads: { _ in XCTFail("Unchanged downloads") }))
            XCTAssertEqual(writes, 1)
        }
    }
}
