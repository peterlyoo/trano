import AppKit
import SwiftUI
import XCTest
import TerminalCore
@testable import TranoApp

@MainActor
final class TerminalSettingsFormTests: XCTestCase {
    final class Model: ObservableObject {
        @Published var preferences = TerminalPreferences()
        @Published var legacy = TerminalSettings()
        var clearCount = 0
    }
    struct Harness: View {
        @ObservedObject var model: Model
        var body: some View {
            TerminalSettingsForm(terminalPreferences: $model.preferences, legacy: $model.legacy,
                                 clearRecentPaths: { model.clearCount += 1 })
        }
    }
    func host(_ model: Model, width: CGFloat = 620) -> NSHostingView<Harness> {
        let host = NSHostingView(rootView: Harness(model: model))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 560)
        settle(host)
        return host
    }
    func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        view.layoutSubtreeIfNeeded()
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func control<T: NSView>(_ id: String, in view: NSView, as type: T.Type = T.self,
                            file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(descendants(view).first { $0.identifier?.rawValue == id } as? T, id, file: file, line: line)
    }
    func click(_ id: String, in view: NSView) throws {
        let button: NSButton = try control(id, in: view)
        button.performClick(nil)
        settle(view)
    }
    func choose(_ id: String, value: String, in view: NSView) throws {
        let popup: NSPopUpButton = try control(id, in: view)
        let item = try XCTUnwrap(popup.itemArray.first { $0.representedObject as? String == value }, value)
        popup.select(item)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(popup.action), to: popup.target, from: popup))
        settle(view)
    }
    func edit(_ id: String, value: String, in view: NSView) throws {
        let field: NSTextField = try control(id, in: view)
        field.stringValue = value
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(field.action), to: field.target, from: field))
        settle(view)
    }

    // Implements: FR-SET-66, FR-SET-67, FR-SET-85
    func testLegacyEditsClearOnlyShadowingOverridesAndPreserveCustomProfiles() throws {
        let model = Model()
        model.preferences.fontSize = 27
        model.preferences.fontName = "Monaco"
        model.preferences.optionKey = .meta
        model.legacy.background = "#102030"
        model.legacy.keyBindings = ["custom": ["cmd+shift+j"]]
        var profile = AppearanceProfile(name: "User Custom", settings: model.legacy)
        profile.fontName = "Monaco"
        profile.fontSize = 21
        model.legacy.appearanceProfiles = [profile]
        model.legacy.paneAppearanceProfiles = [UUID().uuidString.lowercased(): profile.id]
        model.legacy.notifications = false
        model.legacy.automaticRestore = false
        let baseline = model.legacy
        let view = host(model)
        try edit("terminal.fontSize", value: "18", in: view)
        XCTAssertEqual(model.legacy.fontSize, 18)
        XCTAssertNil(model.preferences.fontSize)
        XCTAssertEqual(model.preferences.fontName, "Monaco")
        try choose("terminal.optionKey", value: "specialCharacters", in: view)
        XCTAssertEqual(model.legacy.optionAsMeta, false)
        XCTAssertNil(model.preferences.optionKey)
        XCTAssertEqual(model.legacy.background, baseline.background)
        XCTAssertEqual(model.legacy.keyBindings, baseline.keyBindings)
        XCTAssertEqual(model.legacy.appearanceProfiles, baseline.appearanceProfiles)
        XCTAssertEqual(model.legacy.paneAppearanceProfiles, baseline.paneAppearanceProfiles)
        XCTAssertEqual(model.legacy.notifications, baseline.notifications)
        XCTAssertEqual(model.legacy.automaticRestore, baseline.automaticRestore)
        try edit("terminal.scrollbackLines", value: "24000", in: view)
        XCTAssertEqual(model.legacy.scrollbackLines, 24000)
    }

    // Implements: FR-SET-80, FR-SET-81, FR-SET-82, FR-SET-83
    func testCursorCustomIntervalAppearsOnlyForCustomAndActionsSurviveRedraw() throws {
        let model = Model()
        let view = host(model)
        XCTAssertFalse(descendants(view).contains { $0.identifier?.rawValue == "terminal.cursorBlinkIntervalMS" })
        try choose("terminal.cursorBlinkSpeed", value: "custom", in: view)
        try edit("terminal.cursorBlinkIntervalMS", value: "915", in: view)
        XCTAssertEqual(model.preferences.cursorBlinkIntervalMS, 915)
        try choose("terminal.cursorStyle", value: "underline", in: view)
        try click("terminal.forceCursorStyle", in: view)
        XCTAssertEqual(model.preferences.cursorStyle, .underline)
        XCTAssertTrue(model.preferences.forceCursorStyle)
        model.preferences.copyOnSelection = true
        settle(view)
        try click("terminal.forceCursorStyle", in: view)
        XCTAssertFalse(model.preferences.forceCursorStyle)
        for speed in ["off", "slow", "normal", "fast"] {
            try choose("terminal.cursorBlinkSpeed", value: speed, in: view)
            XCTAssertEqual(model.preferences.cursorBlinkSpeed?.rawValue, speed)
            XCTAssertFalse(descendants(view).contains { $0.identifier?.rawValue == "terminal.cursorBlinkIntervalMS" })
        }
    }

    // Implements: FR-SET-70, FR-SET-71, FR-SET-72, FR-SET-73, FR-SET-74, FR-SET-75, FR-SET-77, FR-SET-78, FR-SET-79, FR-SET-84, FR-SET-86, FR-SET-87, FR-SET-88, FR-SET-89, FR-SET-92, FR-SET-95, FR-SET-96
    func testScalarAndBooleanControlsBindTheTypedSidecarIncludingFalse() throws {
        let model = Model()
        model.legacy.fontName = "Monaco"
        let view = host(model)
        try click("terminal.advancedFonts", in: view)
        try edit("terminal.lineHeight", value: "1.25", in: view)
        try edit("terminal.characterSpacing", value: "12", in: view)
        try choose("terminal.characterSpacingUnit", value: "percent", in: view)
        try choose("terminal.fontStyles", value: "neither", in: view)
        try edit("terminal.minimumContrastRatio", value: "4.5", in: view)
        try edit("terminal.selectionCornerRadius", value: "6", in: view)
        let initial = model.preferences
        let booleans: [(String, WritableKeyPath<TerminalPreferences, Bool>)] = [
            ("ligatures", \.ligatures), ("forceFontStyles", \.forceFontStyles),
            ("fontSmoothing", \.fontSmoothing), ("forceThemePaletteForText", \.forceThemePaletteForText),
            ("useDisplayP3", \.useDisplayP3), ("showKeySequenceHints", \.showKeySequenceHints),
            ("smoothScrolling", \.smoothScrolling), ("smoothResizing", \.smoothResizing),
            ("copyOnSelection", \.copyOnSelection), ("animateCopy", \.animateCopy),
            ("showRecentPaths", \.showRecentPaths), ("preferGeneratedTitles", \.preferGeneratedTitles)
        ]
        for (name, key) in booleans {
            try click("terminal." + name, in: view)
            XCTAssertEqual(model.preferences[keyPath: key], !initial[keyPath: key], name)
        }
        XCTAssertEqual(model.preferences.lineHeight, 1.25)
        XCTAssertEqual(model.preferences.characterSpacing, TerminalCharacterSpacing(value: 12, unit: .percent))
        XCTAssertEqual(model.preferences.fontStyles, .neither)
        XCTAssertEqual(model.preferences.minimumContrastRatio, 4.5)
        XCTAssertEqual(model.preferences.selectionCornerRadius, 6)
        XCTAssertFalse(model.preferences.showKeySequenceHints)
        try model.preferences.validate()
    }

    // Implements: FR-SET-76, FR-SET-93, FR-SET-94, FR-SET-95, FR-SET-97
    func testFallbackOrderingTrustedRevocationAndExactArgvIncludingEmptyValues() throws {
        let model = Model()
        model.preferences.fallbackFonts = ["Monaco", "Menlo-Regular"]
        model.preferences.trustedLinks = [TerminalTrustedLink(scheme: "ssh", host: "example.invalid", port: 2222)]
        model.preferences.startupCommand = TerminalStartupCommand(executable: "/bin/zsh", arguments: ["", "two words", "'quoted';"])
        let view = host(model)
        try click("terminal.advancedFonts", in: view)
        try click("terminal.fallback.1.up", in: view)
        XCTAssertEqual(model.preferences.fallbackFonts, ["Menlo-Regular", "Monaco"])
        try click("terminal.fallback.0.remove", in: view)
        try click("terminal.fallback.0.remove", in: view)
        XCTAssertEqual(model.preferences.fallbackFonts, [])
        try click("terminal.fallback.add", in: view)
        XCTAssertEqual(model.preferences.fallbackFonts, ["AppleSDGothicNeo-Regular"])
        try click("terminal.fallback.0.remove", in: view)
        XCTAssertEqual(model.preferences.fallbackFonts, [])
        try choose("terminal.applicationLinks", value: "never", in: view)
        XCTAssertEqual(model.preferences.applicationLinks, .never)
        XCTAssertTrue(descendants(view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "ssh://example.invalid:2222" })
        try click("terminal.trusted.0.revoke", in: view)
        XCTAssertTrue(model.preferences.trustedLinks.isEmpty)
        try click("terminal.clearRecentPaths", in: view)
        XCTAssertEqual(model.clearCount, 1)
        try edit("terminal.argument.1", value: "two words; $(untouched)", in: view)
        XCTAssertEqual(model.preferences.startupCommand?.arguments, ["", "two words; $(untouched)", "'quoted';"])
        try click("terminal.argument.add", in: view)
        XCTAssertEqual(model.preferences.startupCommand?.arguments.last, "")
        try click("terminal.argument.1.remove", in: view)
        XCTAssertEqual(model.preferences.startupCommand?.arguments, ["", "'quoted';", ""])
        try choose("terminal.startupMode", value: "login", in: view)
        XCTAssertNil(model.preferences.startupCommand)
        try choose("terminal.startupMode", value: "custom", in: view)
        XCTAssertEqual(model.preferences.startupCommand?.arguments, ["", "'quoted';", ""])
        try model.preferences.validate()
    }

    // Implements: FR-SET-68, FR-SET-69, FR-SET-90, FR-SET-91
    func testInstalledFacesAndSelectionColors() throws {
        let model = Model()
        let view = host(model)
        try choose("terminal.fontStyle", value: "Menlo-Italic", in: view)
        XCTAssertEqual(model.preferences.fontStyle, "Menlo-Italic")
        XCTAssertFalse(descendants(view).contains { $0.identifier?.rawValue == "terminal.fontWeight" })
        for (id, key) in [("terminal.selectionForeground", \TerminalPreferences.selectionForeground),
                          ("terminal.selectionBackground", \TerminalPreferences.selectionBackground)] {
            let well: NSColorWell = try control(id, in: view)
            well.color = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(well.action), to: well.target, from: well))
            XCTAssertEqual(model.preferences[keyPath: key], "#336699")
        }
    }

    // Implements: FR-SET-69
    func testVariableWeightControlUsesActualInstalledAxis() throws {
        let candidates = ["Skia-Regular", "Skia", "SFPro-Regular", "SFCompact-Regular"].compactMap { NSFont(name: $0, size: 14) }
        guard let font = candidates.first(where: { TerminalFontAdapter.weightAxis(for: $0) != nil }) else {
            throw XCTSkip("No installed variable font exposes a wght axis")
        }
        let model = Model()
        model.legacy.fontName = font.fontName
        let view = host(model)
        let axis = try XCTUnwrap(TerminalFontAdapter.weightAxis(for: font))
        let slider: NSSlider = try control("terminal.fontWeight", in: view)
        XCTAssertEqual(slider.minValue, axis.minimum)
        XCTAssertEqual(slider.maxValue, axis.maximum)
        slider.doubleValue = axis.maximum
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(slider.action), to: slider.target, from: slider))
        XCTAssertEqual(model.preferences.fontWeight, axis.maximum)
    }

    // Implements: FR-SET-66, FR-SET-68, FR-SET-69
    func testPrimaryInstalledFontPickerClearsFaceThatWouldShadowNewSelection() throws {
        let model = Model()
        model.preferences.fontName = "Menlo-Regular"
        model.preferences.fontStyle = "Menlo-Bold"
        let view = host(model)
        let popup = try XCTUnwrap(descendants(view).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Terminal font" })
        let menu = try XCTUnwrap(popup.menu)
        menu.delegate?.menuNeedsUpdate?(menu)
        let item = try XCTUnwrap(popup.itemArray.first { $0.representedObject as? String == "Menlo-Italic" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        settle(view)
        XCTAssertEqual(model.legacy.fontName, "Menlo-Italic")
        XCTAssertNil(model.preferences.fontName)
        XCTAssertNil(model.preferences.fontStyle)
        XCTAssertNil(model.preferences.fontWeight)
        XCTAssertEqual(model.preferences.resolved(legacy: model.legacy).fontName, "Menlo-Italic")
    }

    // Implements: FR-SET-67, FR-SET-70
    func testDecimalTypingPreservesPartialInputAndRejectsInvalidCommit() throws {
        let model = Model()
        let view = host(model)
        let field: NSTextField = try control("terminal.lineHeight", in: view)
        field.stringValue = "1."
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(field.stringValue, "1.")
        field.stringValue = "1.25"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(model.preferences.lineHeight, 1.25)
        try edit("terminal.fontSize", value: "nan", in: view)
        XCTAssertEqual(model.legacy.fontSize, 14)
        try edit("terminal.fontSize", value: "100000", in: view)
        XCTAssertEqual(model.legacy.fontSize, 14)
        XCTAssertEqual(try control("terminal.fontSize", in: view, as: NSTextField.self).stringValue, "14")
    }

    // Implements: FR-SET-66 through FR-SET-97
    func testOpeningAndExpandingPreserveEveryDraftValueWithoutNormalizing() throws {
        let model = Model()
        model.preferences.fallbackFonts = []
        model.preferences.showKeySequenceHints = false
        model.preferences.smoothScrolling = false
        model.preferences.smoothResizing = false
        model.preferences.startupCommand = TerminalStartupCommand(executable: "/bin/zsh", arguments: ["", "a b", "'", ";"])
        model.preferences.trustedLinks = [TerminalTrustedLink(scheme: "ssh", host: nil)]
        model.legacy.fontName = "Monaco"
        model.legacy.keyBindings = ["custom": ["cmd+j"]]
        let preferences = model.preferences
        let legacy = model.legacy
        let view = host(model)
        try click("terminal.advancedFonts", in: view)
        XCTAssertEqual(model.preferences, preferences)
        XCTAssertEqual(model.legacy, legacy)
        XCTAssertTrue(descendants(view).contains { $0.identifier?.rawValue == "terminal.forceFontStyles" })
        model.legacy.fontName = "Menlo-Regular"
        settle(view)
        XCTAssertFalse(descendants(view).contains { $0.identifier?.rawValue == "terminal.forceFontStyles" })
    }

    // Implements: FR-SET-66, FR-SET-67, FR-SET-68, FR-SET-71
    func testFontPreviewUsesCurrentFace() throws {
        let model = Model()
        model.preferences.fontStyle = "Menlo-Italic"
        model.preferences.fontSize = 19
        let view = host(model)
        let preview: NSTextField = try control("terminal.fontPreview", in: view)
        XCTAssertEqual(preview.font?.fontName, "Menlo-Italic")
        XCTAssertEqual(preview.font?.pointSize, 19)
    }

    // Implements: FR-SET-71
    func testSpacingUnitCannotLeaveInvalidDraft() throws {
        let model = Model()
        model.preferences.characterSpacing = TerminalCharacterSpacing(value: 300, unit: .percent)
        let view = host(model)
        try click("terminal.advancedFonts", in: view)
        try choose("terminal.characterSpacingUnit", value: "pixels", in: view)
        XCTAssertEqual(model.preferences.characterSpacing, TerminalCharacterSpacing(value: 64, unit: .pixels))
        try model.preferences.validate()
    }

    // Implements: FR-SET-66, FR-SET-76
    func testFontMenusStayLazyAndAllFontBrowsingHasNoEmptyPrimaryChoice() throws {
        let model = Model()
        let view = host(model)
        let popup = try XCTUnwrap(descendants(view).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Terminal font" })
        XCTAssertLessThanOrEqual(popup.numberOfItems, 2)
        try click("terminal.allFonts", in: view)
        XCTAssertLessThanOrEqual(popup.numberOfItems, 2)
        let menu = try XCTUnwrap(popup.menu)
        menu.delegate?.menuNeedsUpdate?(menu)
        let proportional = try XCTUnwrap(InstalledFontCatalog.shared.all.first { NSFont(name: $0.id, size: 14)?.isFixedPitch == false })
        let item = try XCTUnwrap(popup.itemArray.first { $0.representedObject as? String == proportional.id })
        XCTAssertFalse(popup.itemArray.contains { $0.representedObject as? String == "" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        settle(view)
        XCTAssertEqual(model.legacy.fontName, proportional.id)
        try click("terminal.copyOnSelection", in: view)
        XCTAssertTrue(popup.itemArray.contains { $0 === item })
    }

    // Implements: FR-SET-97
    func testReselectingStartupModeDoesNotOverwriteExactCommandDraft() throws {
        let model = Model()
        let command = TerminalStartupCommand(executable: "/usr/bin/env", arguments: ["", "A=two words", "/bin/zsh", "-l"])
        model.preferences.startupCommand = command
        let view = host(model)
        try choose("terminal.startupMode", value: "custom", in: view)
        XCTAssertEqual(model.preferences.startupCommand, command)
        try choose("terminal.startupMode", value: "login", in: view)
        try choose("terminal.startupMode", value: "login", in: view)
        try choose("terminal.startupMode", value: "custom", in: view)
        XCTAssertEqual(model.preferences.startupCommand, command)
    }

    // Implements: FR-SET-66 through FR-SET-97
    func testControlBoundsAndDraftCancelSaveProjection() throws {
        let model = Model()
        let basePreferences = model.preferences
        let baseLegacy = model.legacy
        let view = host(model, width: 560)
        try click("terminal.advancedFonts", in: view)
        try edit("terminal.fontSize", value: "22", in: view)
        try click("terminal.copyOnSelection", in: view)
        for control in descendants(view).compactMap({ $0 as? NSControl }) where control.identifier?.rawValue.hasPrefix("terminal.") == true {
            let bounds = control.convert(control.bounds, to: view)
            XCTAssertGreaterThanOrEqual(bounds.minX, -1, control.identifier!.rawValue)
            XCTAssertLessThanOrEqual(bounds.maxX, view.bounds.maxX + 1, control.identifier!.rawValue)
            XCTAssertGreaterThan(control.bounds.width, 0)
            XCTAssertGreaterThan(control.bounds.height, 0)
        }
        var savedPreferences = basePreferences
        var savedLegacy = baseLegacy
        savedPreferences.merge(model.preferences, from: basePreferences)
        savedLegacy.merge(model.legacy, from: baseLegacy)
        XCTAssertTrue(savedPreferences.copyOnSelection)
        XCTAssertEqual(savedLegacy.fontSize, 22)
        model.preferences = basePreferences
        model.legacy = baseLegacy
        settle(view)
        XCTAssertEqual(model.preferences, basePreferences)
        XCTAssertEqual(model.legacy, baseLegacy)
        XCTAssertTrue(savedPreferences.copyOnSelection)
    }
}
