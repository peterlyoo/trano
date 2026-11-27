#if os(macOS)
import AppKit
import XCTest
@testable import SwiftTerm

@MainActor
final class TranoRendererOptionsTests: XCTestCase {
    private func makeView() -> TerminalView {
        TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320),
                     font: NSFont(name: "Menlo-Regular", size: 14),
                     options: TerminalOptions(cols: 20, rows: 4, scrollback: 20))
    }

    private func context(_ view: TerminalView) -> SnapshotRenderContext {
        SnapshotRenderContext(viewState: FrameViewState(view: view), style: .empty,
                              ansiColors: view.withTerminal { $0.ansiColors }, cols: 20)
    }

    private func attributes(_ view: TerminalView, _ attribute: Attribute,
                            builder: SnapshotTextBuilder = SnapshotTextBuilder()) throws -> SnapshotTextAttributes {
        try XCTUnwrap(builder.getAttributes(attribute, withUrl: false, context: context(view)))
    }

    private func components(_ color: NSColor?) throws -> [Int] {
        let value = try XCTUnwrap(color?.usingColorSpace(.sRGB))
        return [value.redComponent, value.greenComponent, value.blueComponent]
            .map { Int(($0 * 255).rounded()) }
    }

    // Implements: FR-SET-71, FR-SET-72, FR-SET-73, FR-SET-78, FR-SET-79
    func testNewOptionsKeepCurrentRendererDefaults() {
        let view = makeView()
        XCTAssertEqual(view.textStyleOptions, .all)
        XCTAssertEqual(view.characterSpacing, 0)
        XCTAssertTrue(view.ligaturesEnabled)
        XCTAssertFalse(view.forceThemePaletteForText)
        XCTAssertFalse(view.useDisplayP3)
        let fonts = FrameViewState(view: view).fonts
        XCTAssertTrue(CFEqual(fonts.normal, view.font))
        XCTAssertFalse(CFEqual(fonts.normal, fonts.bold))
        XCTAssertFalse(CFEqual(fonts.normal, fonts.italic))
    }

    // Implements: FR-SET-73
    func testStylePolicyRebuildsSnapshotFontsAndRestoresNativeFaces() {
        let view = makeView()
        let original = FrameViewState(view: view).fonts
        view.textStyleOptions = []
        let plain = FrameViewState(view: view).fonts
        XCTAssertTrue(CFEqual(plain.bold, plain.normal))
        XCTAssertTrue(CFEqual(plain.italic, plain.normal))
        XCTAssertTrue(CFEqual(plain.boldItalic, plain.normal))
        view.textStyleOptions = .bold
        let bold = FrameViewState(view: view).fonts
        XCTAssertTrue(CFEqual(bold.italic, bold.normal))
        XCTAssertTrue(CFEqual(bold.boldItalic, bold.bold))
        XCTAssertTrue(CFEqual(bold.bold, original.bold))
        view.textStyleOptions = .italic
        let italic = FrameViewState(view: view).fonts
        XCTAssertTrue(CFEqual(italic.bold, italic.normal))
        XCTAssertTrue(CFEqual(italic.boldItalic, italic.italic))
        XCTAssertTrue(CFEqual(italic.italic, original.italic))
        view.textStyleOptions = .all
        XCTAssertTrue(CFEqual(FrameViewState(view: view).fonts.boldItalic, original.boldItalic))
    }

    // Implements: FR-SET-71
    func testSpacingChangesActualCellGeometryAndRestoresIt() {
        let view = makeView()
        let original = FrameViewState(view: view).cellDimension
        view.characterSpacing = 4
        let spaced = FrameViewState(view: view).cellDimension
        XCTAssertEqual(spaced.width - original.width, 4, accuracy: 0.01)
        XCTAssertEqual(spaced.height, original.height, accuracy: 0.01)
        view.characterSpacing = 0
        XCTAssertEqual(FrameViewState(view: view).cellDimension.width, original.width, accuracy: 0.01)
    }

    // Implements: FR-SET-72
    func testLigatureToggleReachesShapingAttributesAndInvalidatesCaches() throws {
        let view = makeView()
        let builder = SnapshotTextBuilder()
        let attribute = Attribute(fg: .defaultColor, bg: .defaultColor, style: .none)
        let originalContext = context(view)
        view.ligaturesEnabled = false
        let disabled = try attributes(view, attribute, builder: builder)
        XCTAssertEqual((disabled[.ligature] as? NSNumber)?.intValue, 0)
        XCTAssertNotEqual(context(view).identity, originalContext.identity)
        view.ligaturesEnabled = true
        let enabled = try attributes(view, attribute, builder: builder)
        XCTAssertNotEqual((enabled[.ligature] as? NSNumber)?.intValue, 0)
    }

    // Implements: FR-SET-78
    func testForcedPaletteAffectsTruecolorTextOnlyAndKeepsStoredCellAttributes() throws {
        let view = makeView()
        let palette = (0..<16).map { index in
            index == 1 ? Color(red8: 255, green8: 0, blue8: 0)
                : Color(red8: 0, green8: 0, blue8: 0)
        }
        view.installColors(palette)
        let attribute = Attribute(fg: .trueColor(red: 250, green: 2, blue: 1),
                                  bg: .trueColor(red: 3, green: 7, blue: 11), style: .none)
        let builder = SnapshotTextBuilder()
        let original = try attributes(view, attribute, builder: builder)
        XCTAssertEqual(try components(original[.foregroundColor] as? NSColor), [250, 2, 1])
        let originalContext = context(view)
        view.forceThemePaletteForText = true
        let forced = try attributes(view, attribute, builder: builder)
        XCTAssertEqual(try components(forced[.foregroundColor] as? NSColor), [255, 0, 0])
        XCTAssertEqual(try components(forced[.backgroundColor] as? NSColor), [3, 7, 11])
        XCTAssertNotEqual(context(view).identity, originalContext.identity)
        view.forceThemePaletteForText = false
        XCTAssertEqual(try components(try attributes(view, attribute, builder: builder)[.foregroundColor] as? NSColor), [250, 2, 1])
        view.feed(text: "\u{1b}[38;2;250;2;1mA한글")
        view.forceThemePaletteForText = true
        view.withTerminal { terminal in
            XCTAssertEqual(terminal.bufferLine(atRow: 0)?[0].attribute.fg, attribute.fg)
        }
    }

    // Implements: FR-SET-78
    func testForcedPaletteReachesOptimizedPlainAsciiPathAndExtendedAnsiColors() throws {
        let view = makeView()
        view.installColors((0..<16).map { index in
            index == 1 ? Color(red8: 255, green8: 0, blue8: 0) : Color(red8: 0, green8: 0, blue8: 0)
        })
        view.feed(text: "\u{1b}[38;2;250;2;1mA")
        view.forceThemePaletteForText = true
        let snapshot = TerminalSnapshot()
        view.withTerminal { terminal in
            _ = snapshot.refresh(terminal: terminal, viewState: FrameViewState(view: view),
                                 selection: SnapshotSelectionState(selection: view.selection))
        }
        let current = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: snapshot)
        let row = try XCTUnwrap(snapshot.rows.first)
        let builder = SnapshotTextBuilder()
        let plain = try XCTUnwrap(builder.plainRow(row: row, absoluteRow: snapshot.firstRow, context: current))
        let run = try XCTUnwrap(plain.runs.first)
        XCTAssertEqual(try components(builder.platformColor(run.style.foreground, context: current)), [255, 0, 0])
        let extended = try attributes(view, Attribute(fg: .ansi256(code: 196), bg: .defaultColor, style: .none))
        XCTAssertEqual(try components(extended[.foregroundColor] as? NSColor), [255, 0, 0])
    }

    // Implements: FR-SET-79
    func testP3CaptureCarriesItsColorSpaceAndInvalidatesAppearanceCache() throws {
        let view = makeView()
        let p3 = NSColor(displayP3Red: 1, green: 0.2, blue: 0, alpha: 1)
        view.nativeForegroundColor = p3
        let original = FrameViewState(view: view).appearance.effectiveForegroundColor
        XCTAssertEqual(original.nativeColor.colorSpace.cgColorSpace?.name, CGColorSpace.sRGB)
        view.useDisplayP3 = true
        let wide = FrameViewState(view: view).appearance.effectiveForegroundColor
        XCTAssertNotEqual(wide, original)
        let reconstructed = try XCTUnwrap(wide.nativeColor.usingColorSpace(.displayP3))
        XCTAssertEqual(wide.nativeColor.colorSpace.cgColorSpace?.name, CGColorSpace.displayP3)
        XCTAssertEqual(reconstructed.redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(reconstructed.greenComponent, 0.2, accuracy: 0.001)
        view.useDisplayP3 = false
        XCTAssertEqual(FrameViewState(view: view).appearance.effectiveForegroundColor, original)
    }
}
#endif
