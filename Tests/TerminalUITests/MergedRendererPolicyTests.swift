#if os(macOS)
import AppKit
import CoreText
import MetalKit
import XCTest
@testable import SwiftTerm

@MainActor
final class MergedRendererPolicyTests: XCTestCase {
    private func view(_ text: String, font: NSFont) -> TerminalView {
        _ = NSApplication.shared
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 240, height: 120), font: font,
                                options: TerminalOptions(cols: 8, rows: 3, scrollback: 5))
        view.frameDriver.invalidate()
        view.metalScaleFactorOverride = 1
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        view.caretViewTracksFocus = false
        view.feed(text: "\u{1b}[?25l\u{1b}[?2004h" + text)
        return view
    }

    // Implements: FR-SET-73, FR-SET-74
    func testForceSynthesisHonorsDisabledAndPartiallyEnabledStylePoliciesInActualRenderers() throws {
        let font = try synthesisTestFont()
        let view = view("\u{1b}[1;3mAH", font: font)
        let before = view.withTerminal { $0.bufferLine(atRow: 0)?[0].attribute }
        view.textStyleOptions = []
        let plain = try cg(view)
        view.forceFontStyles = true
        XCTAssertTrue(try cg(view) == plain, "Disabled native styles must suppress faux styles too")
        view.textStyleOptions = .bold
        let bold = try cg(view)
        XCTAssertGreaterThan(mass(bold), mass(plain) * 1.05)
        view.textStyleOptions = .italic
        let italic = try cg(view)
        XCTAssertFalse(italic == plain)
        XCTAssertFalse(italic == bold)
        for plainPath in [true, false] {
            let (target, renderer) = try metalRenderer(view)
            renderer.plainTextEnabled = plainPath
            view.textStyleOptions = []
            view.forceFontStyles = false
            let plain = try metal(view, target: target, renderer: renderer)
            view.forceFontStyles = true
            XCTAssertTrue(try metal(view, target: target, renderer: renderer) == plain)
            view.textStyleOptions = .bold
            let bold = try metal(view, target: target, renderer: renderer)
            XCTAssertGreaterThan(mass(bold), mass(plain) * 1.05)
            XCTAssertEqual(renderer.debugPlainRowCount, plainPath ? view.withTerminal { $0.rows } : 0)
            view.textStyleOptions = .italic
            let italic = try metal(view, target: target, renderer: renderer)
            XCTAssertFalse(italic == plain)
            XCTAssertFalse(italic == bold)
        }
        XCTAssertEqual(view.withTerminal { $0.bufferLine(atRow: 0)?[0].attribute }, before)
        XCTAssertTrue(view.terminalStateSnapshot().bracketedPasteMode)
    }

    // Implements: FR-SET-53, FR-SET-54, FR-SET-92
    func testRoundedSelectionAndExplicitBaseBackgroundStayOutsideContentDimmingGroup() throws {
        let view = view("\u{1b}[48;2;0;255;0m      ", font: NSFont.monospacedSystemFont(ofSize: 24, weight: .regular))
        view.selectedTextBackgroundColor = .red
        view.selectedTextForegroundColor = .white
        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 6, row: 0))
        view.inactiveBackgroundMultiplier = 0.8
        let before = view.withTerminal { $0.bufferLine(atRow: 0)?[0].attribute }
        let square = try cg(view)
        view.selectionCornerRadius = 8
        let rounded = try cg(view)
        XCTAssertFalse(rounded == square)
        try assertBaseAndSelection(rounded, square: square, redIndex: 0)
        view.inactiveContentMultiplier = 0.25
        XCTAssertTrue(try cg(view) == rounded, "Content factor cannot darken either background role")
        for plainPath in [true, false] {
            let (target, renderer) = try metalRenderer(view)
            renderer.plainTextEnabled = plainPath
            view.inactiveContentMultiplier = 1
            view.selectionCornerRadius = 0
            let square = try metal(view, target: target, renderer: renderer)
            view.selectionCornerRadius = 8
            let rounded = try metal(view, target: target, renderer: renderer)
            XCTAssertFalse(rounded == square)
            try assertBaseAndSelection(rounded, square: square, redIndex: 2)
            view.inactiveContentMultiplier = 0.25
            XCTAssertTrue(try metal(view, target: target, renderer: renderer) == rounded)
        }
        XCTAssertEqual(view.withTerminal { $0.bufferLine(atRow: 0)?[0].attribute }, before)
    }

    // Implements: FR-SET-54, FR-SET-74, FR-SET-79
    func testP3LiteralColorGlyphAndFauxTextFadeOnceWithoutChangingSourceAttributes() throws {
        let view = view("\u{1b}[1mAH😀", font: try synthesisTestFont())
        view.useDisplayP3 = true
        let before = view.withTerminal { $0.bufferLine(atRow: 0)?[0].attribute }
        let unforced = try cg(view)
        view.forceFontStyles = true
        let original = try cg(view)
        XCTAssertFalse(original == unforced, "Fixture must render actual faux glyphs beside its literal color glyph")
        XCTAssertTrue(hasColor(original))
        view.inactiveContentMultiplier = 0.5
        let faded = try cg(view)
        XCTAssertEqual(mass(faded) / mass(original), 0.5, accuracy: 0.035)
        XCTAssertEqual(alphaMass(faded), alphaMass(original))
        let (target, renderer) = try metalRenderer(view)
        target.metalLayer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        view.inactiveContentMultiplier = 1
        let metalOriginal = try metal(view, target: target, renderer: renderer)
        XCTAssertTrue(hasColor(metalOriginal))
        view.inactiveContentMultiplier = 0.5
        let metalFaded = try metal(view, target: target, renderer: renderer)
        XCTAssertEqual(mass(metalFaded) / mass(metalOriginal), 0.5, accuracy: 0.035)
        XCTAssertEqual(alphaMass(metalFaded), alphaMass(metalOriginal))
        XCTAssertEqual(view.withTerminal { $0.bufferLine(atRow: 0)?[0].attribute }, before)
        XCTAssertTrue(view.terminalStateSnapshot().bracketedPasteMode)
    }


    // Implements: FR-SET-73, FR-SET-74
    func testBlockCaretHonorsDisabledStylesBeforeSynthesisInCoreGraphicsAndMetal() throws {
        let view = view("\u{1b}[1;3mAH\r\u{1b}[?25h", font: try synthesisTestFont())
        view.nativeForegroundColor = .black
        view.caretColor = .black
        view.caretTextColor = .white
        view.forcedCursorStyle = .steadyBlock
        let before = view.withTerminal { $0.bufferLine(atRow: 0)?[0].attribute }
        view.textStyleOptions = []
        let plain = try caret(view)
        view.forceFontStyles = true
        XCTAssertTrue(try caret(view) == plain)
        view.textStyleOptions = .bold
        XCTAssertGreaterThan(mass(try caret(view)), mass(plain) * 1.05)
        view.textStyleOptions = .italic
        XCTAssertFalse(try caret(view) == plain)
        let (target, renderer) = try metalRenderer(view)
        view.textStyleOptions = []
        view.forceFontStyles = false
        let metalPlain = try metal(view, target: target, renderer: renderer)
        view.forceFontStyles = true
        XCTAssertTrue(try metal(view, target: target, renderer: renderer) == metalPlain)
        view.textStyleOptions = .bold
        XCTAssertGreaterThan(mass(try metal(view, target: target, renderer: renderer)), mass(metalPlain) * 1.05)
        view.textStyleOptions = .italic
        XCTAssertFalse(try metal(view, target: target, renderer: renderer) == metalPlain)
        XCTAssertEqual(view.withTerminal { $0.bufferLine(atRow: 0)?[0].attribute }, before)
        XCTAssertTrue(view.terminalStateSnapshot().bracketedPasteMode)
    }

    private func caret(_ view: TerminalView) throws -> [UInt8] {
        let state = FrameViewState(view: view)
        let snapshot = TerminalSnapshot()
        view.withTerminal { _ = snapshot.refresh(terminal: $0, viewState: state, selection: .empty) }
        let caret = try XCTUnwrap(view.caretView)
        caret.setText(try XCTUnwrap(snapshot.cursor).renderData)
        caret.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: 64, height: 64,
                bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            defer { NSGraphicsContext.restoreGraphicsState() }
            caret.drawCursor(in: context, hasFocus: true)
        }
        return bytes
    }

    private func cg(_ view: TerminalView) throws -> [UInt8] {
        view.frameTick()
        var bytes = [UInt8](repeating: 0, count: 240 * 120 * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let space = try XCTUnwrap(CGColorSpace(name: view.useDisplayP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: 240, height: 120,
                bitsPerComponent: 8, bytesPerRow: 960, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setAllowsFontSmoothing(false)
            context.setShouldSmoothFonts(false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            defer { NSGraphicsContext.restoreGraphicsState() }
            view.drawTerminalContents(dirtyRect: view.bounds, context: context, bufferOffset: 0)
        }
        return bytes
    }

    private func metalRenderer(_ view: TerminalView) throws -> (TerminalMetalLayerView, MetalTerminalRenderer) {
        let target = TerminalMetalLayerView(frame: view.bounds)
        target.renderDevice = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        target.metalLayer.framebufferOnly = false
        target.renderContentsScale = 1
        target.renderDrawableSize = view.bounds.size
        let renderer = try MetalTerminalRenderer(target: target)
        renderer.waitForCompletionAfterCommit = true
        renderer.capturesRenderedTexture = true
        return (target, renderer)
    }

    private func metal(_ view: TerminalView, target: TerminalMetalLayerView,
                       renderer: MetalTerminalRenderer) throws -> [UInt8] {
        let state = FrameViewState(view: view)
        let snapshot = TerminalSnapshot()
        view.withTerminal { _ = snapshot.refresh(terminal: $0, viewState: state,
            selection: SnapshotSelectionState(selection: view.selection)) }
        renderer.prepareSnapshotForImmediateDraw(snapshot: snapshot,
            context: SnapshotRenderContext(viewState: state, snapshot: snapshot))
        renderer.render(frame: try XCTUnwrap(target.acquireDrawableFrame()))
        let texture = try XCTUnwrap(renderer.lastRenderedTexture)
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&bytes, bytesPerRow: texture.width * 4,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return bytes
    }

    private func assertBaseAndSelection(_ bytes: [UInt8], square: [UInt8], redIndex: Int,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let locations = stride(from: 0, to: square.count, by: 4).filter {
            square[$0 + redIndex] > 190 && square[$0 + 1] < 10 && square[$0 + 3] > 250
        }.map { ($0 / 4 % 240, $0 / 4 / 240) }
        let minX = try XCTUnwrap(locations.map { $0.0 }.min())
        let minY = try XCTUnwrap(locations.map { $0.1 }.min())
        let maxX = try XCTUnwrap(locations.map { $0.0 }.max())
        let maxY = try XCTUnwrap(locations.map { $0.1 }.max())
        let corner = (minY * 240 + minX) * 4
        let center = (((minY + maxY) / 2) * 240 + (minX + maxX) / 2) * 4
        XCTAssertGreaterThan(bytes[corner + 1], 190, file: file, line: line)
        XCTAssertLessThan(bytes[corner + redIndex], 20, file: file, line: line)
        XCTAssertGreaterThan(bytes[center + redIndex], 190, file: file, line: line)
        XCTAssertLessThan(bytes[center + 1], 20, file: file, line: line)
    }

    private func mass(_ bytes: [UInt8]) -> Double {
        stride(from: 0, to: bytes.count, by: 4).reduce(0) {
            $0 + Double(bytes[$1]) + Double(bytes[$1 + 1]) + Double(bytes[$1 + 2])
        }
    }
    private func alphaMass(_ bytes: [UInt8]) -> UInt64 {
        stride(from: 3, to: bytes.count, by: 4).reduce(0) { $0 + UInt64(bytes[$1]) }
    }
    private func hasColor(_ bytes: [UInt8]) -> Bool {
        stride(from: 0, to: bytes.count, by: 4).contains {
            Int(max(bytes[$0], bytes[$0 + 1], bytes[$0 + 2])) - Int(min(bytes[$0], bytes[$0 + 1], bytes[$0 + 2])) > 20
        }
    }
}
#endif
