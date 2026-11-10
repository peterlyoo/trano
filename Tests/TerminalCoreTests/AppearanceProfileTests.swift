import XCTest
@testable import TerminalCore

final class AppearanceProfileTests: XCTestCase {
    // Implements: U05
    func testLegacyAppearanceDefaultsAndBounds() throws {
        let appearance = try JSONDecoder().decode(AppearancePreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(appearance.lineSpacing, 1)
        XCTAssertNil(appearance.backgroundImagePath)
        var invalid = appearance
        invalid.lineSpacing = 0.1
        XCTAssertThrowsError(try invalid.validate())
        invalid = appearance; invalid.backgroundImageOpacity = 0.9
        XCTAssertThrowsError(try invalid.validate())
        invalid = appearance; invalid.backgroundImagePath = "https://example.com/wallpaper.png"
        XCTAssertThrowsError(try invalid.validate())
    }

    // Implements: U05
    func testPaneProfileOverridesOnlyAppearanceAndSurvivesCoding() throws {
        var settings = TerminalSettings()
        settings.notifications = false
        settings.keyBindings = [ActionID.newTab.rawValue: ["cmd+y"]]
        var profileSettings = settings
        profileSettings.fontName = "Menlo-Regular"
        profileSettings.fontSize = 19
        profileSettings.background = "#171717"
        profileSettings.appearance.lineSpacing = 1.4
        let profile = AppearanceProfile(name: "Reading", settings: profileSettings)
        let pane = UUID().uuidString.lowercased()
        settings.appearanceProfiles = [profile]
        settings.paneAppearanceProfiles[pane] = profile.id
        try settings.validateAppearanceProfiles()
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: JSONEncoder().encode(settings))
        let resolved = decoded.resolvedAppearance(for: pane)
        XCTAssertEqual(resolved.fontName, "Menlo-Regular")
        XCTAssertEqual(resolved.fontSize, 19)
        XCTAssertEqual(resolved.appearance.lineSpacing, 1.4)
        XCTAssertFalse(resolved.notifications)
        XCTAssertEqual(resolved.keyBindings, settings.keyBindings)
        XCTAssertEqual(decoded.resolvedAppearance(for: UUID().uuidString).fontSize, settings.fontSize)
        var invalid = settings
        invalid.appearanceProfiles.append(profile)
        XCTAssertThrowsError(try invalid.validateAppearanceProfiles())
    }

    // Implements: U05, U09
    func testFontZoomUpdatesSelectedProfileAndRemovalRestoresDefaults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-profile-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let paneID = UUID().uuidString.lowercased()
        var settings = TerminalSettings(); settings.fontSize = 20
        let profile = AppearanceProfile(name: "Reading", settings: settings)
        try runtime.update { state in
            state.sessions.append(TerminalSession(id: paneID, title: "Test", cwd: root.path, pid: 0))
            state.layout.addTab(paneID: paneID)
        }
        try runtime.saveAppearanceProfile(profile)
        try runtime.setAppearanceProfile(profile.id, paneID: paneID)
        try runtime.performAction(.increaseFont)
        XCTAssertEqual(try runtime.state().settings.resolvedAppearance(for: paneID).fontSize, 21)
        XCTAssertEqual(try runtime.state().settings.fontSize, 14)
        try runtime.removeAppearanceProfile(profile.id)
        XCTAssertNil(try runtime.state().settings.paneAppearanceProfiles[paneID])
        XCTAssertEqual(try runtime.state().settings.resolvedAppearance(for: paneID).fontSize, 14)
    }
}
