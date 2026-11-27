import XCTest
@testable import TerminalCore

final class AppearanceKeyBindingTests: XCTestCase {
    // Implements: FR-NAV-2
    func testActivityCommandPeriodDefaultAndExplicitBindingPrecedence() throws {
        XCTAssertEqual(try KeyBindingMap().action(for: "cmd+."), .activity)
        XCTAssertEqual(ActionCatalog.action(for: "cmd+.")?.action, .activity)
        XCTAssertEqual(ActionCatalog.all.first(where: { $0.action == .activity })?.shortcut, "⌘.")
        let override = try KeyBindingMap(overrides: [ActionID.voice.rawValue: ["cmd+."]])
        XCTAssertEqual(override.action(for: "cmd+."), .voice)
        XCTAssertEqual(override.bindings[ActionID.activity.rawValue], [])
        XCTAssertThrowsError(try KeyBindingMap(overrides: [ActionID.voice.rawValue: ["cmd+."], ActionID.activity.rawValue: ["cmd+."]]))
        XCTAssertNil(try KeyBindingMap(overrides: [ActionID.activity.rawValue: []]).action(for: "cmd+."))
        let sequence = try TerminalKeySequenceMap(overrides: [ActionID.voice.rawValue: ["cmd+.,cmd+x"]])
        XCTAssertNil(sequence.singles.action(for: "cmd+."))
        XCTAssertEqual(sequence.bindings[ActionID.voice.rawValue], ["cmd+.,cmd+x"])
    }

    // Implements: FR-NAV-2
    func testCommandPaletteUsesShiftPAndPlainCommandPHasNoDefaultPicker() throws {
        let map = try KeyBindingMap()
        XCTAssertEqual(map.action(for: "cmd+shift+p"), .palette)
        XCTAssertNil(map.action(for: "cmd+p"))
        XCTAssertEqual(ActionCatalog.all.first(where: { $0.action == .palette })?.bindings, ["cmd+shift+p"])
        XCTAssertEqual(ActionCatalog.all.first(where: { $0.action == .goToAnything })?.bindings, [])
        XCTAssertEqual(try KeyBindingMap(overrides: [ActionID.goToAnything.rawValue: ["cmd+p"]]).action(for: "cmd+p"), .goToAnything)
        XCTAssertEqual(map.action(for: "cmd+k"), .switchSession)
        XCTAssertEqual(map.action(for: "cmd+."), .activity)
    }

    // Implements: FR-HINT-1, FR-NAV-2
    func testURLHintDefaultYieldsToPreviouslyValidExplicitShortcuts() throws {
        XCTAssertEqual(try KeyBindingMap().action(for: "ctrl+shift+e")?.rawValue, "terminal.url_hints")
        let overrides = [ActionID.voice.rawValue: ["ctrl+shift+e"]]
        let map = try KeyBindingMap(overrides: overrides)
        XCTAssertEqual(map.action(for: "ctrl+shift+e"), .voice)
        XCTAssertEqual(map.bindings["terminal.url_hints"], [])
    }

    // Implements: FR-QUEUE-4, FR-NAV-2
    func testNewQueuedInputDefaultPreservesPreviouslyValidExplicitShortcuts() throws {
        let bindings = try KeyBindingMap(overrides: [ActionID.voice.rawValue: ["cmd+shift+u"], ActionID.newTab.rawValue: ["cmd+y"]])
        XCTAssertEqual(bindings.action(for: "cmd+shift+u"), .voice)
        XCTAssertEqual(bindings.action(for: "cmd+y"), .newTab)
        XCTAssertNil(bindings.action(for: "cmd+t"))
        XCTAssertEqual(bindings.bindings["input.queued"], [])
        XCTAssertThrowsError(try KeyBindingMap(overrides: [ActionID.voice.rawValue: ["cmd+shift+u"], "input.queued": ["cmd+shift+u"]]))
    }

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
