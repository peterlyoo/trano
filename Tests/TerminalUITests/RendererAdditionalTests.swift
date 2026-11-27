#if os(macOS)
import AppKit
import CoreText
import QuartzCore
import XCTest
@testable import SwiftTerm

@MainActor
final class RendererAdditionalTests: XCTestCase {
    private func view() -> TerminalView {
        TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 160),
                     font: NSFont(name: "Menlo-Regular", size: 16),
                     options: TerminalOptions(cols: 20, rows: 4, scrollback: 10))
    }

    private func context(_ view: TerminalView) -> SnapshotRenderContext {
        SnapshotRenderContext(viewState: FrameViewState(view: view), style: .empty,
                              ansiColors: view.withTerminal { $0.ansiColors }, cols: 20)
    }

    // Implements: FR-SET-71
    func testSpacingPreservesProgramModesAndCellAttributes() {
        let view = view()
        view.feed(text: "\u{1b}[?2004h\u{1b}[31mA")
        let before = view.withTerminal { $0.bufferLine(atRow: 0)?[0].attribute }
        XCTAssertTrue(view.terminalStateSnapshot().bracketedPasteMode)
        view.characterSpacing = 3
        XCTAssertTrue(view.terminalStateSnapshot().bracketedPasteMode)
        XCTAssertEqual(view.withTerminal { $0.bufferLine(atRow: 0)?[0].attribute }, before)
        view.characterSpacing = .nan
        XCTAssertEqual(view.characterSpacing, 0)
        XCTAssertTrue(view.cellDimension.width.isFinite)
    }

    // Implements: FR-SET-72
    func testLigatureToggleChangesActualCoreTextShapingAndCaretAttributes() throws {
        let view = view()
        view.font = try XCTUnwrap(NSFont(name: "AvenirNext-Regular", size: 18))
        let attribute = Attribute(fg: .defaultColor, bg: .defaultColor, style: .none)
        let builder = SnapshotTextBuilder()
        func count() throws -> Int {
            let values = try XCTUnwrap(builder.getAttributes(attribute, withUrl: false,
                                                              context: context(view))).values
            return CTLineGetGlyphCount(CTLineCreateWithAttributedString(
                NSAttributedString(string: "ffi", attributes: values)))
        }
        let ligated = try count()
        XCTAssertLessThan(ligated, 3, "Fixture font must actually ligate ffi")
        view.ligaturesEnabled = false
        XCTAssertEqual(try count(), 3)
        let caret = attributedValue(for: attribute, usingFg: .white, andBg: .black,
                                    context: context(view))
        XCTAssertEqual((caret[.ligature] as? NSNumber)?.intValue, 0)
        view.ligaturesEnabled = true
        XCTAssertEqual(try count(), ligated)
    }

    // Implements: FR-SET-78
    func testForcedThemeMapsUnderlineAndCaretWithoutChangingBackground() throws {
        let view = view()
        view.installColors((0..<16).map {
            $0 == 1 ? Color(red8: 255, green8: 0, blue8: 0)
                : Color(red8: 0, green8: 0, blue8: 0)
        })
        let attribute = Attribute(fg: .trueColor(red: 250, green: 2, blue: 1),
                                  bg: .trueColor(red: 3, green: 7, blue: 11), style: .underline,
                                  underlineStyle: .single,
                                  underlineColor: .trueColor(red: 250, green: 2, blue: 1))
        view.forceThemePaletteForText = true
        let values = try XCTUnwrap(SnapshotTextBuilder().getAttributes(
            attribute, withUrl: false, context: context(view)))
        let underline = try XCTUnwrap((values[.underlineColor] as? NSColor)?.usingColorSpace(.sRGB))
        XCTAssertEqual(underline.redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(underline.greenComponent, 0, accuracy: 0.001)
        let background = try XCTUnwrap((values[.backgroundColor] as? NSColor)?.usingColorSpace(.sRGB))
        XCTAssertEqual(background.redComponent, 3.0 / 255, accuracy: 0.001)
        let caret = attributedValue(for: attribute, usingFg: .white, andBg: .black,
                                    context: context(view))
        let caretUnderline = try XCTUnwrap((caret[.underlineColor] as? NSColor)?.usingColorSpace(.sRGB))
        XCTAssertEqual(caretUnderline.redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(caretUnderline.greenComponent, 0, accuracy: 0.001)
    }

    // Implements: FR-SET-79
    func testP3TargetInvalidatesMetalColorCachesForNativeAndPlainColors() throws {
        let cache = MetalColorSIMDCache()
        let p3 = NSColor(displayP3Red: 1, green: 0.2, blue: 0, alpha: 1)
        let narrow = cache.value(for: p3)
        let plainNarrow = cache.value(rgb: 0xff)
        cache.useDisplayP3 = true
        let wide = cache.value(for: p3)
        XCTAssertEqual(wide.x, 1, accuracy: 0.001)
        XCTAssertEqual(wide.y, 0.2, accuracy: 0.001)
        XCTAssertNotEqual(wide, narrow)
        let expected = try XCTUnwrap(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
            .usingColorSpace(.displayP3))
        let plainWide = cache.value(rgb: 0xff)
        XCTAssertEqual(plainWide.x, Float(expected.redComponent), accuracy: 0.001)
        XCTAssertEqual(plainWide.y, Float(expected.greenComponent), accuracy: 0.001)
        XCTAssertNotEqual(plainWide, plainNarrow)
        cache.useDisplayP3 = false
        XCTAssertEqual(cache.value(for: p3), narrow)
        XCTAssertEqual(cache.value(rgb: 0xff), plainNarrow)
    }

    // Implements: FR-SET-79
    func testP3NativeAnsiReconstructionAndMetalSurfaceSwitchTogether() throws {
        let view = view()
        view.useDisplayP3 = true
        let captured = context(view)
        let ansi = try XCTUnwrap(captured.ansiColors.first)
        XCTAssertEqual(ansi.colorSpace.cgColorSpace?.name, CGColorSpace.displayP3)
        try view.setUseMetal(true)
        defer { try? view.setUseMetal(false) }
        let layer = try XCTUnwrap(view.metalView?.layer as? CAMetalLayer)
        XCTAssertEqual(layer.colorspace?.name, CGColorSpace.displayP3)
        view.useDisplayP3 = false
        XCTAssertEqual(layer.colorspace?.name, CGColorSpace.sRGB)
        view.useDisplayP3 = true
        XCTAssertEqual(layer.colorspace?.name, CGColorSpace.displayP3)
    }

    // Implements: FR-SET-79
    func testP3DerivedColorsAndBackgroundLayerKeepTargetSpace() throws {
        let foreground = NSColor(displayP3Red: 1, green: 0.2, blue: 0, alpha: 1)
        let background = NSColor(displayP3Red: 0, green: 0, blue: 0, alpha: 1)
        let dimmed = foreground.dimmedColor(towards: background)
        XCTAssertEqual(dimmed.colorSpace.cgColorSpace?.name, CGColorSpace.displayP3)
        let inverse = foreground.inverseColor()
        XCTAssertEqual(inverse.colorSpace.cgColorSpace?.name, CGColorSpace.displayP3)
        let view = view()
        view.nativeBackgroundColor = foreground
        view.useDisplayP3 = true
        view.updateBackingLayerBackground()
        let layer = try XCTUnwrap(view.layer)
        XCTAssertEqual(layer.backgroundColor?.colorSpace?.name, CGColorSpace.displayP3)
        view.useDisplayP3 = false
        XCTAssertEqual(layer.backgroundColor?.colorSpace?.name, CGColorSpace.sRGB)
    }

    // Implements: FR-SET-73
    func testStylePolicySurvivesResetAndNativeFontReplacement() throws {
        let view = view()
        view.textStyleOptions = []
        view.font = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 20))
        var fonts = FrameViewState(view: view).fonts
        XCTAssertTrue(CFEqual(fonts.normal, fonts.boldItalic))
        view.resetFontSize()
        fonts = FrameViewState(view: view).fonts
        XCTAssertTrue(CFEqual(fonts.normal, fonts.boldItalic))
    }
}
#endif
