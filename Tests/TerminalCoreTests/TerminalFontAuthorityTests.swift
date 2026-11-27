import XCTest
@testable import TerminalCore

final class TerminalFontAuthorityTests: XCTestCase {
    private let paneID = "38a65412-119a-4f10-9ddf-4c0eb932fca5"
    private let profileID = "ee9c4513-e9f6-47df-912b-ad7ebc00d32f"

    private func settingsWithProfile(size: Double = 21) -> TerminalSettings {
        var settings = TerminalSettings()
        settings.fontName = "Monaco"
        settings.fontSize = 16
        settings.appearance.fallbackFontName = "GlobalFallback-Exact"
        var owned = settings
        owned.fontName = "Menlo-Regular"
        owned.fontSize = size
        owned.background = "#123456"
        owned.appearance.lineSpacing = 1.3
        owned.appearance.fallbackFontName = "ProfileFallback-Exact"
        owned.appearance.foreground = "#ABCDEF"
        owned.appearance.selection = "#214365"
        owned.appearance.cursorStyle = .beam
        owned.appearance.cursorBlink = true
        settings.appearanceProfiles = [AppearanceProfile(id: profileID, name: "Custom Profile", settings: owned),
                                       AppearanceProfile(id: "bd070f37-c250-48f5-a389-7027fba41df5", name: "Unrelated Profile", settings: settings)]
        settings.paneAppearanceProfiles = [paneID: profileID]
        settings.keyBindings = ["custom": ["cmd+shift+j"]]
        return settings
    }
    private func globalOverrides() -> TerminalPreferences {
        var preferences = TerminalPreferences()
        preferences.fontName = "Skia-Regular"
        preferences.fontSize = 33
        preferences.fontStyle = "Helvetica-Bold"
        preferences.fontWeight = 650
        preferences.lineHeight = 2
        preferences.fallbackFonts = ["GlobalFirst-Exact", "GlobalSecond-Exact"]
        preferences.selectionForeground = "#001122"
        preferences.selectionBackground = "#334455"
        preferences.cursorStyle = .underline
        preferences.cursorBlinkSpeed = .custom
        preferences.cursorBlinkIntervalMS = 975
        return preferences
    }

    // Implements: FR-SET-66, FR-SET-67, FR-SET-68, FR-SET-69, FR-SET-70, FR-SET-76, FR-SET-80, FR-SET-82, FR-SET-90, FR-SET-91
    func testAssignedProfileRetainsEveryLegacyOwnedAppearanceField() {
        let settings = settingsWithProfile()
        let preferences = globalOverrides()
        let legacy = settings.resolvedAppearance(for: paneID)
        let actual = preferences.resolved(legacy: legacy, profileAssigned: true)
        XCTAssertEqual(actual.fontName, "Menlo-Regular")
        XCTAssertEqual(actual.fontSize, 21)
        XCTAssertNil(actual.fontStyle)
        XCTAssertNil(actual.fontWeight)
        XCTAssertEqual(actual.lineHeight, 1.3)
        XCTAssertEqual(actual.fallbackFonts, ["ProfileFallback-Exact"])
        XCTAssertEqual(actual.selectionForeground, "#ABCDEF")
        XCTAssertEqual(actual.selectionBackground, "#214365")
        XCTAssertEqual(actual.cursorStyle, .beam)
        XCTAssertEqual(actual.cursorBlinkInterval, 0.7)
        XCTAssertEqual(settings, settingsWithProfile())
        XCTAssertEqual(preferences, globalOverrides())
    }

    // Implements: FR-SET-72, FR-SET-73, FR-SET-74, FR-SET-75, FR-SET-77, FR-SET-78, FR-SET-79, FR-SET-83, FR-SET-84, FR-SET-85, FR-SET-86, FR-SET-87, FR-SET-88, FR-SET-89, FR-SET-92, FR-SET-95, FR-SET-96
    func testProfileResolutionKeepsNewRenderingAndInputPolicies() {
        var preferences = globalOverrides()
        preferences.ligatures = false
        preferences.fontStyles = .neither
        preferences.forceFontStyles = true
        preferences.fontSmoothing = true
        preferences.minimumContrastRatio = 4.5
        preferences.forceThemePaletteForText = true
        preferences.useDisplayP3 = true
        preferences.forceCursorStyle = true
        preferences.showKeySequenceHints = false
        preferences.optionKey = .meta
        preferences.smoothScrolling = false
        preferences.smoothResizing = false
        preferences.copyOnSelection = true
        preferences.animateCopy = true
        preferences.selectionCornerRadius = 6
        preferences.showRecentPaths = false
        preferences.preferGeneratedTitles = false
        preferences.characterSpacing = TerminalCharacterSpacing(value: 8, unit: .percent)
        let value = preferences.resolved(legacy: settingsWithProfile().resolvedAppearance(for: paneID), profileAssigned: true)
        XCTAssertFalse(value.ligatures)
        XCTAssertEqual(value.fontStyles, .neither)
        XCTAssertTrue(value.forceFontStyles)
        XCTAssertTrue(value.fontSmoothing)
        XCTAssertEqual(value.minimumContrastRatio, 4.5)
        XCTAssertTrue(value.forceThemePaletteForText)
        XCTAssertTrue(value.useDisplayP3)
        XCTAssertTrue(value.forceCursorStyle)
        XCTAssertFalse(value.showKeySequenceHints)
        XCTAssertTrue(value.optionAsMeta)
        XCTAssertFalse(value.smoothScrolling)
        XCTAssertFalse(value.smoothResizing)
        XCTAssertTrue(value.copyOnSelection)
        XCTAssertTrue(value.animateCopy)
        XCTAssertEqual(value.selectionCornerRadius, 6)
        XCTAssertFalse(value.showRecentPaths)
        XCTAssertFalse(value.preferGeneratedTitles)
        XCTAssertEqual(value.characterSpacing, preferences.characterSpacing)
    }

    // Implements: FR-SET-66, FR-SET-67, FR-SET-68, FR-SET-69, FR-SET-76, FR-SET-80
    func testUnprofiledResolutionPreservesExistingOverrideSemantics() {
        let preferences = globalOverrides()
        let settings = TerminalSettings()
        let value = preferences.resolved(legacy: settings, profileAssigned: false)
        XCTAssertEqual(value, preferences.resolved(legacy: settings))
        XCTAssertEqual(value.fontName, preferences.fontName)
        XCTAssertEqual(value.fontSize, preferences.fontSize)
        XCTAssertEqual(value.fontStyle, preferences.fontStyle)
        XCTAssertEqual(value.fontWeight, preferences.fontWeight)
        XCTAssertEqual(value.fallbackFonts, preferences.fallbackFonts)
        XCTAssertEqual(value.cursorBlinkInterval, 0.975)
    }

    // Implements: FR-SET-67
    func testUnprofiledAdjustmentStartsAtEffectiveSizeAndClearsOnlyItsShadow() throws {
        let settings = settingsWithProfile()
        let preferences = globalOverrides()
        let plan = try TerminalFontAdjustmentPlan.make(delta: 1, settings: settings, preferences: preferences, paneID: "unassigned")
        var expectedSettings = settings
        expectedSettings.fontSize = 34
        var expectedPreferences = preferences
        expectedPreferences.fontSize = nil
        XCTAssertEqual(plan.settings, expectedSettings)
        XCTAssertEqual(plan.preferences, expectedPreferences)
        XCTAssertEqual(plan.preferences.resolved(legacy: plan.settings).fontSize, 34)
        XCTAssertEqual(settings.fontSize, 16)
        XCTAssertEqual(preferences.fontSize, 33)
    }

    // Implements: FR-SET-66, FR-SET-67, FR-SET-76
    func testAssignedProfileAdjustmentChangesOnlyTheExistingProfileSize() throws {
        let settings = settingsWithProfile()
        let preferences = globalOverrides()
        let plan = try TerminalFontAdjustmentPlan.make(delta: -1, settings: settings, preferences: preferences, paneID: paneID)
        var expected = settings
        expected.appearanceProfiles[0].fontSize = 20
        XCTAssertEqual(plan.settings, expected)
        XCTAssertEqual(plan.preferences, preferences)
        XCTAssertEqual(plan.settings.fontSize, 16)
        XCTAssertEqual(plan.settings.resolvedAppearance(for: paneID).fontName, "Menlo-Regular")
        XCTAssertEqual(plan.settings.resolvedAppearance(for: paneID).appearance.fallbackFontName, "ProfileFallback-Exact")
        XCTAssertEqual(plan.preferences.resolved(legacy: plan.settings.resolvedAppearance(for: paneID), profileAssigned: true).fontSize, 20)
    }

    // Implements: FR-SET-67
    func testZeroDeltaResetsExactlyFourteenForProfileAndBase() throws {
        let settings = settingsWithProfile()
        let preferences = globalOverrides()
        let profile = try TerminalFontAdjustmentPlan.make(delta: 0, settings: settings, preferences: preferences, paneID: paneID)
        var expectedProfile = settings
        expectedProfile.appearanceProfiles[0].fontSize = 14
        XCTAssertEqual(profile.settings, expectedProfile)
        XCTAssertEqual(profile.preferences, preferences)
        let base = try TerminalFontAdjustmentPlan.make(delta: 0, settings: settings, preferences: preferences, paneID: nil)
        var expectedBase = settings
        expectedBase.fontSize = 14
        var expectedPreferences = preferences
        expectedPreferences.fontSize = nil
        XCTAssertEqual(base.settings, expectedBase)
        XCTAssertEqual(base.preferences, expectedPreferences)
    }

    // Implements: FR-SET-67
    func testExistingBoundsApplyToProfileAndBaseAndUseSidecarEffectiveSize() throws {
        for (start, delta, expected) in [(9.0, -1.0, 9.0), (40, 1, 40), (21, 0.5, 21.5)] {
            let profile = try TerminalFontAdjustmentPlan.make(delta: delta, settings: settingsWithProfile(size: start), preferences: globalOverrides(), paneID: paneID)
            XCTAssertEqual(profile.settings.appearanceProfiles[0].fontSize, expected)
            var preferences = globalOverrides()
            preferences.fontSize = start
            let base = try TerminalFontAdjustmentPlan.make(delta: delta, settings: settingsWithProfile(), preferences: preferences, paneID: nil)
            XCTAssertEqual(base.settings.fontSize, expected)
            XCTAssertNil(base.preferences.fontSize)
        }
        var preferences = globalOverrides()
        preferences.fontSize = 256
        XCTAssertEqual(try TerminalFontAdjustmentPlan.make(delta: 1, settings: TerminalSettings(), preferences: preferences, paneID: nil).settings.fontSize, 40)
    }

    // Implements: FR-SET-67
    func testStaleProfileAssignmentUsesExistingGlobalFallbackWithoutCreatingOwner() throws {
        var settings = settingsWithProfile()
        settings.paneAppearanceProfiles[paneID] = UUID().uuidString.lowercased()
        let preferences = globalOverrides()
        let plan = try TerminalFontAdjustmentPlan.make(delta: -1, settings: settings, preferences: preferences, paneID: paneID)
        var expected = settings
        expected.fontSize = 32
        XCTAssertEqual(plan.settings, expected)
        XCTAssertNil(plan.preferences.fontSize)
        XCTAssertEqual(plan.settings.appearanceProfiles, settings.appearanceProfiles)
        XCTAssertEqual(plan.settings.paneAppearanceProfiles, settings.paneAppearanceProfiles)
    }

    // Implements: FR-SET-67
    func testNonfiniteAdjustmentIsRejectedBeforeAnyReturnedMutation() {
        for delta in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try TerminalFontAdjustmentPlan.make(delta: delta, settings: settingsWithProfile(), preferences: globalOverrides(), paneID: paneID))
        }
    }

    // Implements: FR-SET-76, FR-SET-80
    func testProfileEmptyCascadeAndSteadyCursorRemainExplicit() {
        var settings = settingsWithProfile()
        settings.appearanceProfiles[0].appearance.fallbackFontName = ""
        settings.appearanceProfiles[0].appearance.cursorBlink = false
        let value = globalOverrides().resolved(legacy: settings.resolvedAppearance(for: paneID), profileAssigned: true)
        XCTAssertEqual(value.fallbackFonts, [])
        XCTAssertNil(value.cursorBlinkInterval)
    }
}
