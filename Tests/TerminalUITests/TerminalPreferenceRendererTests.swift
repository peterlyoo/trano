#if os(macOS)
import AppKit
import CoreText
import XCTest
import TerminalCore
@testable import SwiftTerm
@testable import TranoApp

@MainActor
final class TerminalPreferenceRendererTests: XCTestCase {
    private func view() -> TerminalView {
        _ = NSApplication.shared
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 360, height: 160), font: NSFont(name: "Menlo-Regular", size: 14))
        view.frameDriver.invalidate()
        view.caretViewTracksFocus = false
        return view
    }
    private func apply(_ prefs: TerminalPreferences, to view: TerminalView, legacy: TerminalSettings = TerminalSettings(),
                       theme: ThemeApplication? = nil, profile: Bool = false,
                       previous: ResolvedTerminalPreferences? = nil, reduceMotion: Bool = false) throws -> ResolvedTerminalPreferences {
        try TerminalPreferenceRenderer.apply(prefs, legacy: legacy, themeApplication: theme,
            profileAssigned: profile, previousResolved: previous, reduceMotion: reduceMotion, to: view)
    }

    // Implements: FR-SET-66, FR-SET-67, FR-SET-68, FR-SET-70, FR-SET-72, FR-SET-73, FR-SET-74, FR-SET-75, FR-SET-76, FR-SET-77, FR-SET-78, FR-SET-79, FR-SET-85, FR-SET-86, FR-SET-87, FR-SET-92
    func testRealComponentAppliesTypographyCascadeAndNativeRenderingPoliciesWithoutChangingModes() throws {
        let view = view()
        view.feed(text: "abc\u{1b}[?2004h\u{1b}[?1000h\u{1b}[?1h")
        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 2, row: 0))
        let input = view.terminalInputStateSnapshot()
        var prefs = TerminalPreferences()
        prefs.fontName = "Menlo-Regular"; prefs.fontStyle = "Menlo-Italic"; prefs.fontSize = 20
        prefs.lineHeight = 1.4; prefs.fallbackFonts = ["Apple Symbols", "AppleSDGothicNeo-Regular"]
        prefs.ligatures = false; prefs.fontStyles = .italicOnly; prefs.forceFontStyles = true
        prefs.fontSmoothing = true; prefs.minimumContrastRatio = 4.5; prefs.forceThemePaletteForText = true
        prefs.useDisplayP3 = true; prefs.optionKey = .meta; prefs.smoothScrolling = false; prefs.smoothResizing = false
        prefs.selectionCornerRadius = 9
        _ = try apply(prefs, to: view)
        XCTAssertEqual(view.font.fontName, "Menlo-Italic")
        XCTAssertEqual(view.font.pointSize, 20)
        XCTAssertEqual(view.lineSpacing, 1.4, accuracy: 0.001)
        let cascade = try XCTUnwrap(view.font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor])
        XCTAssertEqual(cascade.map(\.postscriptName), ["AppleSymbols", "AppleSDGothicNeo-Regular"])
        XCTAssertFalse(view.ligaturesEnabled)
        XCTAssertEqual(view.textStyleOptions, .italic)
        XCTAssertTrue(view.forceFontStyles)
        XCTAssertTrue(view.fontSmoothing)
        XCTAssertEqual(view.minimumContrastRatio, 4.5, accuracy: 0.001)
        XCTAssertTrue(view.forceThemePaletteForText)
        XCTAssertTrue(view.useDisplayP3)
        XCTAssertTrue(view.optionAsMetaKey)
        XCTAssertFalse(view.smoothScrolling)
        XCTAssertFalse(view.smoothResizing)
        XCTAssertEqual(view.selectionCornerRadius, 9)
        XCTAssertEqual(view.terminalInputStateSnapshot()?.bracketedPasteMode, input?.bracketedPasteMode)
        XCTAssertEqual(view.terminalInputStateSnapshot()?.mouseMode, input?.mouseMode)
        XCTAssertEqual(view.terminalInputStateSnapshot()?.applicationCursor, input?.applicationCursor)
        XCTAssertTrue(view.selection.active)
    }

    // Implements: FR-SET-69
    func testInvalidWeightOrFaceOrProfileFailsBeforeAnyRendererMutation() throws {
        let view = view()
        let font = view.font
        let background = view.nativeBackgroundColor
        let meta = view.optionAsMetaKey
        var prefs = TerminalPreferences()
        prefs.fontSize = 28; prefs.fontWeight = 650; prefs.useDisplayP3 = true; prefs.optionKey = .specialCharacters
        XCTAssertThrowsError(try apply(prefs, to: view))
        XCTAssertEqual(view.font, font)
        XCTAssertEqual(view.nativeBackgroundColor, background)
        XCTAssertFalse(view.useDisplayP3)
        XCTAssertEqual(view.optionAsMetaKey, meta)
        prefs.fontWeight = nil; prefs.fontStyle = "Helvetica-Bold"
        XCTAssertThrowsError(try apply(prefs, to: view))
        var invalidProfile = TerminalSettings(); invalidProfile.fontSize = .nan
        XCTAssertThrowsError(try apply(TerminalPreferences(), to: view, legacy: invalidProfile, profile: true))
        XCTAssertEqual(view.font, font)
    }

    // Implements: FR-SET-66, FR-SET-67, FR-SET-68, FR-SET-69, FR-SET-70, FR-SET-76
    func testAssignedMenloProfileIgnoresGlobalVariableWeightAndKeepsItsExactTypography() throws {
        let view = view()
        var profile = TerminalSettings(); profile.fontName = "Menlo-Regular"; profile.fontSize = 21
        profile.appearance.lineSpacing = 1.3; profile.appearance.fallbackFontName = "AppleSDGothicNeo-Regular"
        var prefs = TerminalPreferences(); prefs.fontName = "Skia-Regular"; prefs.fontSize = 33
        prefs.fontStyle = "Helvetica-Bold"; prefs.fontWeight = 650; prefs.lineHeight = 1.8; prefs.fallbackFonts = ["Monaco"]
        prefs.cursorBlinkSpeed = .off
        let result = try apply(prefs, to: view, legacy: profile, profile: true)
        XCTAssertEqual(view.font.fontName, "Menlo-Regular")
        XCTAssertEqual(view.font.pointSize, 21)
        XCTAssertEqual(view.lineSpacing, 1.3, accuracy: 0.001)
        XCTAssertTrue(view.cursorBlinkingEnabled, "Assigned profile ignores global explicit Blink Off")
        XCTAssertNil(result.fontWeight)
        XCTAssertNil(result.fontStyle)
        let cascade = try XCTUnwrap(view.font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor])
        XCTAssertEqual(cascade.map(\.postscriptName), ["AppleSDGothicNeo-Regular"])
    }

    // Implements: FR-SET-80, FR-SET-81, FR-SET-82, FR-SET-83
    func testUnrelatedCopyToggleDoesNotOverwriteProgramCursorStyleOrBlinkPolicy() throws {
        let view = view()
        var prefs = TerminalPreferences(); prefs.cursorStyle = .block; prefs.cursorBlinkSpeed = .off
        let before = try apply(prefs, to: view)
        view.feed(text: "\u{1b}[5 q")
        view.frameTick()
        prefs.copyOnSelection.toggle()
        let after = try apply(prefs, to: view, previous: before)
        XCTAssertEqual(view.terminalStateSnapshot().cursorStyle.tagName, "blinkBar")
        XCTAssertNil(view.forcedCursorStyle)
        XCTAssertFalse(view.cursorBlinkingEnabled)
        prefs.forceCursorStyle = true; prefs.cursorStyle = .underline
        _ = try apply(prefs, to: view, previous: after)
        XCTAssertEqual(view.forcedCursorStyle?.tagName, "steadyUnderline")
        XCTAssertEqual(view.terminalStateSnapshot().cursorStyle.tagName, "blinkBar")
    }

    // Implements: FR-SET-80, FR-SET-81
    func testReduceMotionDisablesBothNativeAndMetalBlinkPermissionWithoutChangingProgramShape() throws {
        let view = view()
        var prefs = TerminalPreferences(); prefs.cursorBlinkSpeed = .fast
        let first = try apply(prefs, to: view)
        XCTAssertTrue(view.cursorBlinkingEnabled)
        XCTAssertEqual(view.cursorBlinkInterval, 0.35, accuracy: 0.001)
        view.feed(text: "\u{1b}[3 q")
        _ = try apply(prefs, to: view, previous: first, reduceMotion: true)
        XCTAssertFalse(view.cursorBlinkingEnabled)
        XCTAssertEqual(view.terminalStateSnapshot().cursorStyle.tagName, "blinkUnderline")
    }

    // Implements: FR-SET-77, FR-SET-78, FR-SET-79, FR-SET-90, FR-SET-91
    func testThemeOptionalRolesAndProgramOscPaletteSurviveUnrelatedPreferenceChanges() throws {
        let view = view()
        var theme = ThemePreferences().application(for: .dark, legacy: TerminalSettings())
        theme.cursorText = "#654321"; theme.selectionForeground = "#123456"
        var prefs = TerminalPreferences()
        let first = try apply(prefs, to: view, legacy: theme.settings, theme: theme)
        XCTAssertEqual(try rgb(view.selectedTextForegroundColor), [0x12, 0x34, 0x56])
        XCTAssertEqual(try rgb(try XCTUnwrap(view.caretTextColor)), [0x65, 0x43, 0x21])
        view.feed(text: "\u{1b}]4;1;#010203\u{1b}\\")
        let palette = view.withTerminal { $0.ansiColors }
        prefs.copyOnSelection = true
        _ = try apply(prefs, to: view, legacy: theme.settings, theme: theme, previous: first)
        XCTAssertEqual(view.withTerminal { $0.ansiColors }, palette)
        XCTAssertEqual(try rgb(view.selectedTextForegroundColor), [0x12, 0x34, 0x56])
        XCTAssertEqual(try rgb(try XCTUnwrap(view.caretTextColor)), [0x65, 0x43, 0x21])
    }


    // Implements: FR-SET-80, FR-SET-81, FR-SET-82
    func testInheritedSteadyDefaultAllowsProgramBlinkingAndOffToNormalPreservesProgramBar() throws {
        let view = view()
        var prefs = TerminalPreferences()
        let initial = try apply(prefs, to: view)
        XCTAssertTrue(view.cursorBlinkingEnabled)
        view.feed(text: "\u{1b}[5 q")
        view.frameTick()
        XCTAssertEqual(view.terminalStateSnapshot().cursorStyle.tagName, "blinkBar")
        prefs.cursorBlinkSpeed = .off
        let off = try apply(prefs, to: view, previous: initial)
        XCTAssertFalse(view.cursorBlinkingEnabled)
        XCTAssertEqual(view.terminalStateSnapshot().cursorStyle.tagName, "blinkBar")
        prefs.cursorBlinkSpeed = .normal
        _ = try apply(prefs, to: view, previous: off)
        XCTAssertTrue(view.cursorBlinkingEnabled)
        XCTAssertEqual(view.terminalStateSnapshot().cursorStyle.tagName, "blinkBar")
        let caret = try XCTUnwrap(view.caretView)
        caret.updateCursorStyle()
        XCTAssertNotNil(caret.layer?.animation(forKey: "opacity"))
    }

    // Implements: FR-SET-69
    func testRealVariableWeightIsAppliedAndAnOutOfAxisValueIsAtomic() throws {
        let candidate = ["Skia-Regular", "Skia", "SFPro-Regular", "SFCompact-Regular"].compactMap {
            NSFont(name: $0, size: 20)
        }.first { TerminalFontAdapter.weightAxis(for: $0) != nil }
        let variable = try XCTUnwrap(candidate, "Native qualification requires an installed font with a real wght axis")
        let axis = try XCTUnwrap(TerminalFontAdapter.weightAxis(for: variable))
        let view = view()
        var prefs = TerminalPreferences(); prefs.fontName = variable.fontName; prefs.fontWeight = axis.maximum
        let resolved = try apply(prefs, to: view)
        let values = try XCTUnwrap(CTFontCopyVariation(view.font as CTFont) as? [NSNumber: NSNumber])
        XCTAssertEqual(try XCTUnwrap(values[NSNumber(value: axis.identifier)]).doubleValue, axis.maximum, accuracy: 0.001)
        let before = view.font
        prefs.fontWeight = axis.maximum + 1000
        XCTAssertThrowsError(try apply(prefs, to: view, previous: resolved))
        XCTAssertEqual(view.font, before)
    }

    private final class ScaleWindow: NSWindow {
        let fixtureScale: CGFloat
        init(scale: CGFloat) {
            fixtureScale = scale
            _ = NSApplication.shared
            super.init(contentRect: CGRect(x: 0, y: 0, width: 360, height: 160), styleMask: .borderless,
                       backing: .buffered, defer: true)
            isReleasedWhenClosed = false
        }
        override var backingScaleFactor: CGFloat { fixtureScale }
    }

    // Implements: FR-SET-67, FR-SET-70, FR-SET-71
    func testActualNativeFontLineGridAndPixelPercentSpacingAtOneAndTwoTimesBackingScale() throws {
        for scale: CGFloat in [1, 2] {
            let window = ScaleWindow(scale: scale)
            let view = view()
            window.contentView = view
            defer { window.contentView = nil }
            var prefs = TerminalPreferences(); prefs.fontName = "Menlo-Regular"; prefs.fontSize = 18; prefs.lineHeight = 1.5
            let original = try apply(prefs, to: view)
            let plainWidth = view.cellDimension.width
            let font = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 18))
            let expectedHeight = ceil((CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) * 1.5)
            XCTAssertEqual(view.font.pointSize, 18)
            XCTAssertEqual(view.cellDimension.height, expectedHeight)
            prefs.characterSpacing = TerminalCharacterSpacing(value: 2, unit: .pixels)
            let pixels = try apply(prefs, to: view, previous: original)
            XCTAssertEqual(view.characterSpacing, 2 / scale, accuracy: 0.001)
            XCTAssertEqual((view.cellDimension.width - plainWidth) * scale, 2, accuracy: 0.001)
            prefs.characterSpacing = TerminalCharacterSpacing(value: 20, unit: .percent)
            _ = try apply(prefs, to: view, previous: pixels)
            XCTAssertEqual(view.characterSpacing, plainWidth * 0.2, accuracy: 0.001)
            XCTAssertEqual((view.cellDimension.width * scale).rounded(), view.cellDimension.width * scale)
            XCTAssertFalse(window.isVisible)
        }
    }


    // Implements: FR-SET-67, FR-SET-71
    func testAcceptedLargeFontPercentSpacingIsNotSilentlyClamped() throws {
        let view = view()
        view.setFrameSize(CGSize(width: 2000, height: 500))
        var prefs = TerminalPreferences(); prefs.fontName = "Menlo-Regular"; prefs.fontSize = 128
        let previous = try apply(prefs, to: view)
        let base = view.cellDimension.width
        prefs.characterSpacing = TerminalCharacterSpacing(value: 500, unit: .percent)
        try prefs.validate()
        _ = try apply(prefs, to: view, previous: previous)
        XCTAssertGreaterThan(base * 5, 256, "Fixture must exceed the former native point clamp")
        XCTAssertEqual(view.characterSpacing, base * 5, accuracy: 0.001)
    }

    private func rgb(_ color: NSColor) throws -> [Int] {
        let color = try XCTUnwrap(color.usingColorSpace(.sRGB))
        return [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
    }
}
#endif
