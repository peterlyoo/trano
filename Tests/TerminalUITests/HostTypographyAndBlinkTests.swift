#if os(macOS)
import AppKit
import CoreText
import MetalKit
import QuartzCore
import XCTest
@testable import SwiftTerm

@MainActor
final class HostTypographyAndBlinkTests: XCTestCase {
    private func view() -> TerminalView {
        _ = NSApplication.shared
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 240, height: 120),
            font: NSFont(name: "Menlo-Regular", size: 14), options: TerminalOptions(cols: 20, rows: 6, scrollback: 20))
        view.frameDriver.invalidate()
        view.metalScaleFactorOverride = 1
        view.caretViewTracksFocus = false
        return view
    }

    // Implements: FR-SET-80, FR-SET-81
    func testBlinkOffRejectsProgramBlinkingStyleAndInputResetWithoutChangingItsShapeOrMetadata() throws {
        let view = view()
        XCTAssertTrue(view.cursorBlinkingEnabled)
        view.feed(text: "\u{1b}[5 q")
        view.frameTick()
        let caret = try XCTUnwrap(view.caretView)
        caret.style = .blinkBar
        XCTAssertNotNil(caret.layer?.animation(forKey: #keyPath(CALayer.opacity)))
        view.cursorBlinkingEnabled = false
        caret.updateCursorStyle()
        caret.resetBlinkAfterInput()
        XCTAssertNil(caret.layer?.animation(forKey: #keyPath(CALayer.opacity)))
        XCTAssertEqual(caret.layer?.opacity, 1)
        XCTAssertEqual(caret.style.tagName, "blinkBar")
        XCTAssertEqual(view.terminalStateSnapshot().cursorStyle.tagName, "blinkBar")
        view.feed(text: "\u{1b}[3 q")
        view.frameTick()
        caret.style = .blinkUnderline
        caret.resetBlinkAfterInput()
        XCTAssertNil(caret.layer?.animation(forKey: #keyPath(CALayer.opacity)))
        XCTAssertEqual(view.terminalStateSnapshot().cursorStyle.tagName, "blinkUnderline")
        view.cursorBlinkingEnabled = true
        caret.updateCursorStyle()
        XCTAssertNotNil(caret.layer?.animation(forKey: #keyPath(CALayer.opacity)))
    }

    // Implements: FR-SET-80, FR-SET-81
    func testMetalBlinkOffKeepsRealCursorPixelsVisibleDuringAnOffPhaseAndStopsBlinkRequests() throws {
        let view = view()
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .black
        view.caretColor = .white
        view.feed(text: "\u{1b}[5 q")
        let target = TerminalMetalLayerView(frame: view.bounds)
        target.renderDevice = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        target.metalLayer.framebufferOnly = false
        target.renderContentsScale = 1
        target.renderDrawableSize = view.bounds.size
        let renderer = try MetalTerminalRenderer(target: target)
        renderer.waitForCompletionAfterCommit = true
        renderer.capturesRenderedTexture = true
        let state = try XCTUnwrap(Mirror(reflecting: renderer).children.first { $0.label == "redrawState" }?.value as? MetalRedrawState)
        let visible = try pixels(view, renderer: renderer, target: target)
        XCTAssertTrue(state.cursorBlinkWanted)
        XCTAssertGreaterThan(mass(visible), 0)
        if state.cursorBlinkOn { state.toggleCursorBlink() }
        XCTAssertLessThan(mass(try pixels(view, renderer: renderer, target: target)), mass(visible))
        view.cursorBlinkingEnabled = false
        let disabled = try pixels(view, renderer: renderer, target: target)
        XCTAssertFalse(state.cursorBlinkWanted)
        XCTAssertTrue(disabled == visible)
        if state.cursorBlinkOn { state.toggleCursorBlink() }
        XCTAssertTrue(try pixels(view, renderer: renderer, target: target) == visible)
        XCTAssertEqual(view.terminalStateSnapshot().cursorStyle.tagName, "blinkBar")
    }

    // Implements: FR-SET-66, FR-SET-67, FR-SET-70
    func testTypographyUpdateReflowsWithoutClearingProgramInputModesSelectionOrMarkedText() throws {
        let view = view()
        view.feed(text: "abcdef\u{1b}[?2004h\u{1b}[?1000h\u{1b}[?1h\u{1b}[4h")
        view.selection.setSelection(start: Position(col: 1, row: 0), end: Position(col: 3, row: 0))
        view.setMarkedText("한", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        let before = view.terminalInputStateSnapshot()
        let dimensions = view.terminalStateSnapshot().dimensions
        let start = view.selection.start
        let end = view.selection.end
        XCTAssertTrue(view.hasMarkedText())
        view.updateTypography(font: try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 21)), lineSpacing: 1.35)
        view.frameTick()
        let after = view.terminalInputStateSnapshot()
        XCTAssertEqual(after?.bracketedPasteMode, before?.bracketedPasteMode)
        XCTAssertEqual(after?.applicationCursor, before?.applicationCursor)
        XCTAssertEqual(after?.mouseMode, before?.mouseMode)
        XCTAssertTrue(view.withTerminal { $0.insertMode })
        XCTAssertTrue(view.selection.active)
        XCTAssertEqual(view.selection.start, start)
        XCTAssertEqual(view.selection.end, end)
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.font.pointSize, 21)
        XCTAssertEqual(view.lineSpacing, 1.35, accuracy: 0.001)
        XCTAssertLessThan(view.terminalStateSnapshot().dimensions.cols, dimensions.cols)
        XCTAssertGreaterThan(view.cellDimension.height, 21)
    }


    // Implements: FR-SET-66, FR-SET-67, FR-SET-70
    func testTypographyClearsSelectionWhenReflowWouldChangeItsSelectedText() throws {
        let view = view()
        view.feed(text: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\r\nnext\u{1b}[?2004h\u{1b}[?1h")
        view.selection.setSelection(start: Position(col: 0, row: 1), end: Position(col: 5, row: 1))
        let original = try XCTUnwrap(view.getSelection())
        XCTAssertFalse(original.isEmpty)
        view.setMarkedText("한", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.updateTypography(font: try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 28)), lineSpacing: 1)
        XCTAssertNotEqual(view.getSelection(), original, "Fixture must change the content beneath the old wrapped range")
        XCTAssertFalse(view.selection.active, "A retained range must not silently select different wrapped text")
        XCTAssertNil(view.getSelection())
        XCTAssertTrue(view.terminalInputStateSnapshot()?.bracketedPasteMode == true)
        XCTAssertTrue(view.terminalInputStateSnapshot()?.applicationCursor == true)
        XCTAssertTrue(view.hasMarkedText())
    }

    // Implements: FR-SET-75
    func testSmoothingChangeRerasterizesWarmPlainAndDictionaryAtlasGlyphs() throws {
        let view = view()
        view.feed(text: "Wé")
        view.metalBufferingMode = .perFrameAggregated
        let target = TerminalMetalLayerView(frame: view.bounds)
        target.renderDevice = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        target.metalLayer.framebufferOnly = false
        target.renderContentsScale = 1
        target.renderDrawableSize = view.bounds.size
        let renderer = try MetalTerminalRenderer(target: target)
        renderer.waitForCompletionAfterCommit = true
        renderer.capturesRenderedTexture = true
        renderer.capturesDrawData = true
        view.fontSmoothing = false
        _ = try pixels(view, renderer: renderer, target: target)
        let before = try XCTUnwrap(renderer.lastDrawData?.frame).glyphCellsGray.map(\.texOrigin)
        XCTAssertGreaterThanOrEqual(before.count, 2)
        _ = try pixels(view, renderer: renderer, target: target)
        XCTAssertEqual(try XCTUnwrap(renderer.lastDrawData?.frame).glyphCellsGray.map(\.texOrigin), before)
        view.fontSmoothing = true
        _ = try pixels(view, renderer: renderer, target: target)
        let after = try XCTUnwrap(renderer.lastDrawData?.frame).glyphCellsGray.map(\.texOrigin)
        XCTAssertEqual(after.count, before.count)
        for index in before.indices {
            XCTAssertNotEqual(after[index], before[index], "A changed raster option must replace each warm atlas entry")
        }
    }

    private func pixels(_ view: TerminalView, renderer: MetalTerminalRenderer,
                        target: TerminalMetalLayerView) throws -> [UInt8] {
        let snapshot = TerminalSnapshot()
        let state = FrameViewState(view: view)
        view.withTerminal { _ = snapshot.refresh(terminal: $0, viewState: state, selection: .empty) }
        renderer.prepareSnapshotForImmediateDraw(snapshot: snapshot, context: SnapshotRenderContext(viewState: state, snapshot: snapshot))
        renderer.render(frame: try XCTUnwrap(target.acquireDrawableFrame()))
        let texture = try XCTUnwrap(renderer.lastRenderedTexture)
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return bytes
    }
    private func mass(_ bytes: [UInt8]) -> UInt64 {
        stride(from: 0, to: bytes.count, by: 4).reduce(0) { $0 + UInt64(bytes[$1]) + UInt64(bytes[$1 + 1]) + UInt64(bytes[$1 + 2]) }
    }
}
#endif
