import AppKit
import XCTest
import SwiftTerm
import TerminalCore
@testable import TranoApp

final class TerminalThemeConfigurationTests: XCTestCase {
    // Implements: FR-SET-63, FR-SET-65
    @MainActor func testExtendedOnlyChangePassesTheLiveTranoViewConfigurationFingerprint() {
        let view = TranoView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        var preferences = ThemePreferences()
        let initial = preferences.application(for: .dark, legacy: TerminalSettings())
        view.configure(initial.settings, themeApplication: initial)
        preferences.darkExtendedPalette = true
        let extended = preferences.application(for: .dark, legacy: TerminalSettings())
        XCTAssertEqual(extended.settings, initial.settings)
        view.configure(extended.settings, themeApplication: extended)
        switch view.terminalStateSnapshot().ansi256PaletteStrategy {
        case .base16Lab: break
        default: XCTFail("A theme-only extended toggle must reach the live renderer")
        }
        view.configure(initial.settings, themeApplication: initial)
        switch view.terminalStateSnapshot().ansi256PaletteStrategy {
        case .xterm: break
        default: XCTFail("Disabling the theme-only toggle must restore xterm colors")
        }
    }

    // Implements: FR-SET-62, FR-SET-64
    @MainActor func testOptionalThemeColorsApplyThroughLiveConfigurationWithoutChangingLegacySettings() throws {
        let view = TranoView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        let legacy = TerminalSettings()
        var preferences = ThemePreferences()
        let palette = ThemePalette(name: "Live", background: "#102030", foreground: "#DDEEFF",
                                   cursor: "#123456", cursorText: "#ABCDEF", selection: "#234567", selectionForeground: "#FEDCBA")
        try preferences.save(palette); try preferences.select(palette.id, for: .dark)
        let application = preferences.application(for: .dark, legacy: legacy)
        view.configure(application.settings, themeApplication: application)
        XCTAssertEqual(view.font.pointSize, legacy.fontSize)
        XCTAssertEqual(view.nativeBackgroundColor.usingColorSpace(.sRGB)?.blueComponent ?? 0, 48.0 / 255, accuracy: 0.001)
        XCTAssertNotNil(view.caretTextColor)
        XCTAssertEqual(view.selectedTextForegroundColor.usingColorSpace(.sRGB)?.redComponent ?? 0, 254.0 / 255, accuracy: 0.001)
        XCTAssertEqual(legacy.appearance.foreground, "#ECECEE")
        let light = preferences.application(for: .light, legacy: legacy)
        view.configure(light.settings, themeApplication: light)
        XCTAssertNil(view.caretTextColor)
    }

    // Implements: FR-SET-62, FR-SET-64, FR-SET-66, FR-SET-67, FR-SET-76
    @MainActor func testAssignedPaneProfileKeepsItsFontCascadeSizeAndColors() throws {
        var settings = TerminalSettings()
        var profileSettings = settings
        profileSettings.fontName = "Monaco"; profileSettings.fontSize = 19
        profileSettings.background = "#123456"
        profileSettings.appearance.foreground = "#FEDCBA"
        profileSettings.appearance.fallbackFontName = "AppleSDGothicNeo-Regular"
        let profile = AppearanceProfile(name: "Profile", settings: profileSettings)
        let paneID = UUID().uuidString.lowercased()
        settings.appearanceProfiles = [profile]; settings.paneAppearanceProfiles[paneID] = profile.id
        let application = ThemePreferences().application(for: .light, legacy: settings.resolvedAppearance(for: paneID), profileAssigned: true)
        let view = TranoView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        view.configure(application.settings, themeApplication: application)
        XCTAssertEqual(view.font.pointSize, 19)
        XCTAssertEqual(view.font.familyName, NSFont(name: "Monaco", size: 19)?.familyName)
        let cascade = try XCTUnwrap(view.font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor])
        XCTAssertTrue(cascade.contains { $0.postscriptName == "AppleSDGothicNeo-Regular" })
        XCTAssertEqual(view.nativeBackgroundColor.usingColorSpace(.sRGB)?.redComponent ?? 0, 18.0 / 255, accuracy: 0.001)
    }
}
