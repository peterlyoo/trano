#if os(macOS)
import AppKit
import XCTest
import MetalKit
import QuartzCore
@testable import SwiftTerm

@MainActor
final class PixelViewportTests: XCTestCase {
    // Implements: FR-INPUT-1
    func testMetalOmitsOrdinaryCursorPixelsWhileHangulIsMarkedAndRestoresThemAfterward() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 240, height: 120),
            font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular))
        view.metalScaleFactorOverride = 1
        view.nativeForegroundColor = .white; view.nativeBackgroundColor = .black
        view.caretViewTracksFocus = false; view.caretColor = .magenta; view.forcedCursorStyle = .steadyBar
        view.feed(text: "prompt> ")
        let target = Target(), renderer = try renderer(target)
        func cursorPixels(_ bytes: [UInt8]) -> Int {
            stride(from: 0, to: bytes.count, by: 4).filter {
                bytes[$0] > 200 && bytes[$0 + 1] < 80 && bytes[$0 + 2] > 200
            }.count
        }
        XCTAssertGreaterThan(cursorPixels(try metal(view, renderer: renderer, target: target)), 0)
        view.setMarkedText("한글", selectedRange: NSRange(location: 2, length: 0), replacementRange: .empty)
        XCTAssertEqual(cursorPixels(try metal(view, renderer: renderer, target: target)), 0)
        let draw = try XCTUnwrap(renderer.lastDrawData)
        XCTAssertTrue(draw.cursorColorVertices.isEmpty)
        XCTAssertTrue(draw.cursorGlyphVerticesGray.isEmpty)
        XCTAssertTrue(draw.cursorGlyphVerticesColor.isEmpty)
        view.unmarkText()
        XCTAssertGreaterThan(cursorPixels(try metal(view, renderer: renderer, target: target)), 0)
    }

    private func view(asciiOnly: Bool = false, systemFont: Bool = false) -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 240, height: 120),
                                font: systemFont ? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular) : NSFont(name: "Menlo-Regular", size: 14),
                                options: TerminalOptions(cols: 20, rows: 6, scrollback: 100))
        view.nativeForegroundColor = .white
        view.nativeBackgroundColor = .black
        view.caretViewTracksFocus = false
        view.feed(text: (0..<40).map { "row-\($0) " + (asciiOnly ? "ABC" : "한글") + "\r\n" }.joined())
        view.scrollUp(lines: 3)
        view.frameTick()
        return view
    }

    private func wheel(_ pixels: Int32) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                      wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0))
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        XCTAssertTrue(event.hasPreciseScrollingDeltas)
        return event
    }

    private func pixels(_ view: TerminalView) throws -> [UInt8] {
        let width = Int(view.bounds.width), height = Int(view.bounds.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            view.drawTerminalContents(dirtyRect: view.bounds, context: context, bufferOffset: 0)
        }
        return bytes
    }

    private final class Target: MetalRenderTarget {
        let layer = CAMetalLayer()
        var renderDevice: MTLDevice? { get { layer.device } set { layer.device = newValue } }
        var renderPixelFormat: MTLPixelFormat { .bgra8Unorm }
        var renderDrawableSize: CGSize { get { layer.drawableSize } set { layer.drawableSize = newValue } }
        var renderBounds = CGRect(x: 0, y: 0, width: 240, height: 120)
        var renderContentsScale: CGFloat = 1
        var renderGeometry: MetalSurfaceGeometry { MetalSurfaceGeometry(bounds: renderBounds, drawableSize: renderDrawableSize, contentsScale: 1) }
        var detachedRenderSurface: (any MetalRenderSurface)? { nil }
        var needsExternalDrawCall: Bool { true }
        init() {
            layer.device = MTLCreateSystemDefaultDevice()
            layer.pixelFormat = .bgra8Unorm
            layer.framebufferOnly = false
            layer.drawableSize = CGSize(width: 240, height: 120)
        }
        func requestDisplay() {}
        func acquireDrawableFrame() -> MetalDrawableFrame? {
            guard let drawable = layer.nextDrawable() else { return nil }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].storeAction = .store
            return MetalDrawableFrame(drawable: drawable, renderPassDescriptor: pass, geometry: renderGeometry)
        }
    }
    private func metal(_ view: TerminalView, renderer: MetalTerminalRenderer, target: Target) throws -> [UInt8] {
        let state = FrameViewState(view: view)
        let snapshot = TerminalSnapshot()
        view.withTerminal { terminal in
            _ = snapshot.refresh(terminal: terminal, viewState: state, selection: SnapshotSelectionState(selection: view.selection))
        }
        let context = SnapshotRenderContext(viewState: state, snapshot: snapshot)
        renderer.prepareSnapshotForImmediateDraw(snapshot: snapshot, context: context)
        renderer.render(frame: try XCTUnwrap(target.acquireDrawableFrame(), "Native offscreen CAMetalLayer must produce a drawable"))
        let texture = try XCTUnwrap(renderer.lastRenderedTexture)
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return bytes
    }
    private func renderer(_ target: Target) throws -> MetalTerminalRenderer {
        let renderer = try MetalTerminalRenderer(target: target)
        renderer.waitForCompletionAfterCommit = true
        renderer.capturesRenderedTexture = true
        renderer.capturesDrawData = true
        return renderer
    }
    // Implements: FR-SET-86
    func testFractionalPlacementKeepsTextAttributeContextWarm() throws {
        let view = view(asciiOnly: true, systemFont: true)
        func identity() -> UInt64 {
            SnapshotRenderContext(viewState: FrameViewState(view: view), style: .empty,
                ansiColors: view.withTerminal { $0.ansiColors }, cols: view.terminalStateSnapshot().dimensions.cols).identity
        }
        let original = identity()
        view.smoothScrolling = true
        view.scrollWheel(with: try wheel(3))
        XCTAssertEqual(identity(), original, "Moving the viewport must not invalidate font/color attribute caches")
    }

    // Implements: FR-SET-86
    func testNativeMetalActuallyMovesAndRestoresBothRenderingPaths() throws {
        for plain in [false, true] {
            let view = view(asciiOnly: true, systemFont: true)
            view.metalScaleFactorOverride = 1
            let target = Target()
            let renderer = try renderer(target)
            renderer.plainTextEnabled = plain
            let original = try metal(view, renderer: renderer, target: target)
            XCTAssertGreaterThan(original.reduce(0, { $0 + Int($1) }), 0)
            if plain { XCTAssertGreaterThan(renderer.debugPlainRowCount, 0) }
            view.smoothScrolling = true
            view.scrollWheel(with: try wheel(3))
            let shifted = try metal(view, renderer: renderer, target: target)
            XCTAssertFalse(shifted == original, "Fractional movement must affect actual native Metal pixels")
            view.smoothScrolling = false
            XCTAssertTrue(try metal(view, renderer: renderer, target: target) == original)
        }
    }

    // Implements: FR-SET-86
    func testPixelScrollMovesViewportBeforeAWholeLineAndToggleRestoresTheGrid() throws {
        let view = view()
        XCTAssertFalse(view.smoothScrolling)
        view.smoothScrolling = true
        let row = view.terminalStateSnapshot().viewportRow
        view.scrollWheel(with: try wheel(3))
        XCTAssertEqual(view.terminalStateSnapshot().viewportRow, row)
        XCTAssertEqual(view.scrollPixelOffset, 3, accuracy: 0.001)
        view.smoothScrolling = false
        XCTAssertEqual(view.scrollPixelOffset, 0)
    }

    // Implements: FR-SET-86
    func testCoreGraphicsPixelsActuallyMoveAndReturnExactlyWhenDisabled() throws {
        let view = view()
        let original = try pixels(view)
        XCTAssertGreaterThan(original.reduce(0, { $0 + Int($1) }), 0)
        view.smoothScrolling = true
        view.scrollWheel(with: try wheel(3))
        view.frameTick()
        XCTAssertFalse(try pixels(view) == original)
        view.smoothScrolling = false
        view.frameTick()
        XCTAssertTrue(try pixels(view) == original)
    }

    // Implements: FR-SET-86
    func testSelectionHitTestingTracksThePixelViewportAcrossRowEdges() throws {
        let view = view()
        let point = CGPoint(x: 4, y: view.bounds.height - 1)
        let original = view.calculateMouseHit(at: point).grid.row
        view.smoothScrolling = true
        view.scrollWheel(with: try wheel(3))
        XCTAssertEqual(view.calculateMouseHit(at: point).grid.row, original - 1)
        view.smoothScrolling = false
        XCTAssertEqual(view.calculateMouseHit(at: point).grid.row, original)
    }

    // Implements: FR-SET-86
    func testPixelBoundariesDoNotBankDeniedMovementAndPartialHistoryStaysUserScrolled() throws {
        let view = view()
        view.smoothScrolling = true
        view.scrollTo(row: 0)
        view.scrollWheel(with: try wheel(3))
        XCTAssertEqual(view.scrollPixelOffset, 0)
        view.scrollWheel(with: try wheel(-3))
        XCTAssertEqual(view.scrollPixelOffset, -3)
        view.scrollTo(row: Int.max)
        view.scrollWheel(with: try wheel(-3))
        XCTAssertEqual(view.scrollPixelOffset, 0)
        view.scrollWheel(with: try wheel(3))
        XCTAssertEqual(view.scrollPixelOffset, 3)
        XCTAssertTrue(view.withTerminal { $0.userScrolling })
    }

    // Implements: FR-SET-86
    func testDirectionReversalAndLineCrossingKeepExactFractionalDistance() throws {
        let view = view()
        view.smoothScrolling = true
        let original = view.terminalStateSnapshot().viewportRow
        let height = Int32(FrameViewState(view: view).cellDimension.height)
        view.scrollWheel(with: try wheel(3))
        view.scrollWheel(with: try wheel(height + 2))
        XCTAssertEqual(view.terminalStateSnapshot().viewportRow, original - 1)
        XCTAssertEqual(view.scrollPixelOffset, 5)
        view.scrollWheel(with: try wheel(-8))
        XCTAssertEqual(view.terminalStateSnapshot().viewportRow, original - 1)
        XCTAssertEqual(view.scrollPixelOffset, -3)
    }

    // Implements: FR-SET-86
    func testAlternateBufferAndMouseReportingCannotInheritFractionalHistoryOffset() throws {
        let view = view()
        view.smoothScrolling = true
        view.scrollWheel(with: try wheel(3))
        XCTAssertEqual(view.scrollPixelOffset, 3)
        view.feed(text: "\u{1b}[?1049h")
        view.frameTick()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(view.scrollPixelOffset, 0)
        view.feed(text: "\u{1b}[?1049l")
        view.frameTick()
        view.scrollUp(lines: 3)
        view.scrollWheel(with: try wheel(3))
        XCTAssertEqual(view.scrollPixelOffset, 3)
        view.feed(text: "\u{1b}[?1000h")
        view.scrollWheel(with: try wheel(3))
        XCTAssertEqual(view.scrollPixelOffset, 0)
    }

    // Implements: FR-SET-86
    func testPixelScrollKeepsSelectedUnicodeAndOriginalCellAttributes() throws {
        let view = view()
        let row = view.terminalStateSnapshot().viewportRow
        view.selection.setSelection(start: Position(col: 0, row: row), end: Position(col: 10, row: row))
        let selected = view.withTerminal { _ in view.selection.getSelectedText() }
        let before = view.withTerminal { terminal in (0..<10).map { terminal.bufferLine(atRow: row)?[$0].attribute } }
        XCTAssertFalse(selected.isEmpty)
        view.smoothScrolling = true
        view.scrollWheel(with: try wheel(3))
        view.frameTick()
        XCTAssertEqual(view.withTerminal { _ in view.selection.getSelectedText() }, selected)
        XCTAssertEqual(view.withTerminal { terminal in (0..<10).map { terminal.bufferLine(atRow: row)?[$0].attribute } }, before)
    }

    // Implements: FR-SET-86
    func testFractionalMetalMovementReusesPreparedRows() throws {
        let view = view(asciiOnly: true, systemFont: true)
        view.metalScaleFactorOverride = 1
        let target = Target()
        let renderer = try renderer(target)
        _ = try metal(view, renderer: renderer, target: target)
        view.smoothScrolling = true
        view.scrollWheel(with: try wheel(3))
        _ = try metal(view, renderer: renderer, target: target)
        XCTAssertGreaterThan(renderer.debugRowCacheCounts.cached, 0)
        XCTAssertGreaterThan(renderer.debugRowCacheCounts.moved, 0)
        XCTAssertLessThanOrEqual(renderer.debugRowCacheCounts.rebuilt, 2)
    }

    // Implements: FR-SET-87
    func testDeferredPreviewStillPublishesTheRequestedBackendWindowSizeWithoutLaunchingAProcess() {
        let view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 240, height: 120),
            font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            options: TerminalOptions(cols: 20, rows: 6, scrollback: 20))
        XCTAssertFalse(view.process.running)
        view.feed(text: "\u{1b}[?2004h")
        let original = view.terminalStateSnapshot().dimensions
        view.smoothResizing = false
        view.setFrameSize(CGSize(width: 400, height: 120))
        XCTAssertEqual(view.terminalStateSnapshot().dimensions, original)
        XCTAssertGreaterThan(Int(view.getWindowSize().ws_col), original.cols,
                             "The backend must receive new dimensions before its response can reflow the client")
        view.feed(text: "server-response")
        XCTAssertEqual(Int(view.getWindowSize().ws_col), view.terminalStateSnapshot().dimensions.cols)
        XCTAssertTrue(view.terminalStateSnapshot().bracketedPasteMode)
        XCTAssertFalse(view.process.running)
    }

    // Implements: FR-SET-87
    func testSmoothResizeReflowsLocallyBeforeAnyServerOutput() {
        let view = view()
        view.smoothResizing = true
        let original = view.terminalStateSnapshot().dimensions
        view.setFrameSize(CGSize(width: 400, height: 120))
        XCTAssertGreaterThan(view.terminalStateSnapshot().dimensions.cols, original.cols)
    }

    // Implements: FR-SET-87
    func testDisablingLocalResizePreviewWaitsForTheServerOutputAndCanBeReenabled() {
        let view = view()
        view.smoothResizing = false
        let original = view.terminalStateSnapshot().dimensions
        view.setFrameSize(CGSize(width: 400, height: 120))
        XCTAssertEqual(view.terminalStateSnapshot().dimensions, original)
        view.feed(text: "server-response")
        XCTAssertGreaterThan(view.terminalStateSnapshot().dimensions.cols, original.cols)
        view.setFrameSize(CGSize(width: 500, height: 120))
        let beforeEnabling = view.terminalStateSnapshot().dimensions.cols
        view.smoothResizing = true
        XCTAssertGreaterThan(view.terminalStateSnapshot().dimensions.cols, beforeEnabling)
    }
}
#endif
