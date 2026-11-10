import XCTest
@testable import TerminalCore

final class AppearanceKeyBindingTests: XCTestCase {
    // Implements: U03, U05, U09, FR-NAV-2
    func testOverridesDisableDefaultsAndCanonicalizeModifierOrder() throws {
        let overrides = [ActionID.newTab.rawValue: ["shift+cmd+y"], ActionID.palette.rawValue: []]
        let bindings = try KeyBindingMap(overrides: overrides)
        XCTAssertNil(bindings.action(for: "cmd+t"))
        XCTAssertNil(bindings.action(for: "cmd+shift+p"))
        XCTAssertEqual(bindings.action(for: "cmd+shift+y"), .newTab)
        XCTAssertEqual(bindings.action(for: "ctrl+cmd+left"), .resizeLeft)
        XCTAssertThrowsError(try KeyBindingMap(overrides: [ActionID.newTab.rawValue: ["cmd+w"]]))
        XCTAssertThrowsError(try KeyBindingMap(overrides: [ActionID.newTab.rawValue: ["a"]]))
        XCTAssertThrowsError(try KeyBindingMap(overrides: ["missing.action": ["cmd+y"]]))
        XCTAssertThrowsError(try KeyBindingMap(overrides: [ActionID.newTab.rawValue: ["cmd+q"]]))
    }

    // Implements: U05, U12
    func testAppearanceValidationAndSettingsMigration() throws {
        let legacy = try JSONDecoder().decode(TerminalSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.appearance, AppearancePreferences())
        XCTAssertEqual(legacy.keyBindings, [:])
        XCTAssertNoThrow(try legacy.appearance.validate())
        XCTAssertThrowsError(try JSONDecoder().decode(AppearancePreferences.self, from: Data("{\"ansiColors\":[]}".utf8)))
        var invalid = AppearancePreferences()
        invalid.ansiColors.removeLast()
        XCTAssertThrowsError(try invalid.validate())
        invalid = AppearancePreferences(); invalid.opacity = .nan
        XCTAssertThrowsError(try invalid.validate())
        for theme in TerminalTheme.all { XCTAssertNoThrow(try theme.appearance.validate()) }
        var draft = legacy
        draft.appearance.foreground = "#F0F0F0"
        draft.keyBindings = [ActionID.newTab.rawValue: ["cmd+y"]]
        var concurrent = legacy
        concurrent.fontSize = 20
        concurrent.merge(draft, from: legacy)
        XCTAssertEqual(concurrent.fontSize, 20)
        XCTAssertEqual(concurrent.appearance, draft.appearance)
        XCTAssertEqual(concurrent.keyBindings, draft.keyBindings)
    }
}
