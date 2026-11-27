import AppKit
import XCTest
import TerminalCore
@testable import TranoApp

final class SystemMonospacedFontAdapterTests: XCTestCase {
    // Implements: U05, U21
    @MainActor func testSystemMonospacedIdentifierResolvesThroughNativeAPIAtRequestedSize() async throws {
        var preferences = ResolvedTerminalPreferences()
        preferences.fontName = "system-monospace"
        preferences.fontSize = 21
        let font = try TerminalFontAdapter.font(for: preferences)
        XCTAssertEqual(font.fontName, NSFont.monospacedSystemFont(ofSize: 21, weight: .regular).fontName)
        XCTAssertEqual(font.pointSize, 21)
        XCTAssertTrue(font.isFixedPitch)
        let cascade = try XCTUnwrap(font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor])
        XCTAssertEqual(cascade.map(\.postscriptName), ["AppleSDGothicNeo-Regular"])
    }

    // Implements: U05, U21
    @MainActor func testInstalledCustomFontsFacesAndInvalidRequestsKeepExistingBehavior() async throws {
        var preferences = ResolvedTerminalPreferences()
        preferences.fontName = "Menlo-Regular"
        preferences.fontStyle = "Menlo-Italic"
        preferences.fontSize = 18
        XCTAssertEqual(try TerminalFontAdapter.font(for: preferences).fontName, "Menlo-Italic")
        preferences.fontStyle = nil
        preferences.fontName = "system-monospace"
        for size in [2.0, 257.0, .infinity, .nan] {
            preferences.fontSize = size
            XCTAssertThrowsError(try TerminalFontAdapter.font(for: preferences))
        }
        preferences.fontSize = 18
        preferences.fontName = "TranoUnavailableFixture"
        XCTAssertThrowsError(try TerminalFontAdapter.font(for: preferences))
    }
    @MainActor func testSettingsValidationUsesNativeSystemFontForExplicitChoice() throws {
        var settings = TerminalSettings(); settings.fontName = "system-monospace"
        let draft = SettingsDraft(settings: settings, automaticallyChecksForUpdates: false, automaticallyDownloadsUpdates: false)
        XCTAssertNotNil(SettingsDraft.font(named: settings.fontName, size: settings.fontSize))
        XCTAssertNoThrow(try draft.validate())
    }

}
