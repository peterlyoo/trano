#if os(macOS)
import AppKit
import XCTest
import MetalKit
import QuartzCore
@testable import SwiftTerm

@MainActor
final class RoundedSelectionTests: XCTestCase {
    private func view(_ text: String = "      ", font: NSFont? = nil) -> TerminalView {
        _ = NSApplication.shared
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 240, height: 120), font: font ?? NSFont(name: "Menlo-Regular", size: 24), options: TerminalOptions(cols: 12, rows: 3, scrollback: 5))
        view.metalScaleFactorOverride = 1
        view.nativeBackgroundColor = .clear
        view.nativeForegroundColor = .white
        view.selectedTextBackgroundColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        view.feed(text: "\u{1b}[?25l" + text)
        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 6, row: 0))
        return view
    }
    private func pixels(_ view: TerminalView) throws -> [UInt8] {
        view.frameTick()
        var bytes = [UInt8](repeating: 0, count: 240 * 120 * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: 240, height: 120, bitsPerComponent: 8, bytesPerRow: 960, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
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
    private func selectionBounds(_ bytes: [UInt8], redIndex: Int = 0) throws -> CGRect {
        let locations = stride(from: 0, to: bytes.count, by: 4).filter {
            bytes[$0 + redIndex] > 250 && bytes[$0 + 1] < 4 && bytes[$0 + (2 - redIndex)] < 4 && bytes[$0 + 3] > 250
        }.map { ($0 / 4 % 240, $0 / 4 / 240) }
        let minX = try XCTUnwrap(locations.map { $0.0 }.min())
        let maxX = try XCTUnwrap(locations.map { $0.0 }.max())
        let minY = try XCTUnwrap(locations.map { $0.1 }.min())
        let maxY = try XCTUnwrap(locations.map { $0.1 }.max())
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
    private func index(_ bounds: CGRect, center: Bool = false) -> Int {
        let x = center ? Int(bounds.midX) : Int(bounds.minX)
        let y = center ? Int(bounds.midY) : Int(bounds.minY)
        return (y * 240 + x) * 4
    }
    private func assertCornersAndCenter(_ rounded: [UInt8], square: [UInt8], redIndex: Int = 0, file: StaticString = #filePath, line: UInt = #line) throws {
        let bounds = try selectionBounds(square, redIndex: redIndex)
        XCTAssertLessThan(rounded[index(bounds) + 3], 30, "Rounded outer corner must expose underlying transparency", file: file, line: line)
        XCTAssertEqual(rounded[index(bounds, center: true) + 3], 255, "Selection center stays opaque", file: file, line: line)
        XCTAssertEqual(rounded[index(bounds, center: true) + redIndex], 255, file: file, line: line)
    }
    private func snapshot(_ view: TerminalView) -> (TerminalSnapshot, SnapshotRenderContext) {
        let state = FrameViewState(view: view)
        let snapshot = TerminalSnapshot()
        view.withTerminal { terminal in
            _ = snapshot.refresh(terminal: terminal, viewState: state, selection: SnapshotSelectionState(selection: view.selection))
        }
        return (snapshot, SnapshotRenderContext(viewState: state, snapshot: snapshot))
    }
    // Implements: FR-SET-92
    func testStyledRunsCoalesceInCoreGraphicsAndBothNativeMetalPaths() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 24, weight: .regular)
        let plainView = view(font: font)
        let styledView = view("\u{1b}[1m  \u{1b}[3;38;2;1;2;3m  \u{1b}[0m  ", font: font)
        plainView.selectionCornerRadius = 8
        styledView.selectionCornerRadius = 8
        XCTAssertTrue(try pixels(plainView) == pixels(styledView), "Changing font/color within selected spaces cannot add corner seams")
        let before = styledView.withTerminal { terminal in (0..<6).map { terminal.bufferLine(atRow: 0)?[$0].attribute } }
        for plain in [true, false] {
            let target = Target()
            let renderer = try renderer(target)
            renderer.plainTextEnabled = plain
            styledView.metalBufferingMode = .perFrameAggregated
            plainView.metalBufferingMode = .perFrameAggregated
            let baseline = try metal(plainView, renderer: renderer, target: target)
            renderer.discardRowCache()
            let styled = try metal(styledView, renderer: renderer, target: target)
            if plain { XCTAssertGreaterThan(renderer.debugPlainRowCount, 0) }
            XCTAssertTrue(styled == baseline, "Native selected background stays continuous across style runs")
            let cells = try XCTUnwrap(renderer.lastDrawData?.frame).backgroundCells.filter { $0.cornerRadii.x > 0 }
            XCTAssertEqual(cells.count, 1)
        }
        XCTAssertEqual(styledView.withTerminal { terminal in (0..<6).map { terminal.bufferLine(atRow: 0)?[$0].attribute } }, before)
    }
    // Implements: FR-SET-92
    func testRoundedCornersRevealExplicitBaseBackgroundInBothRenderers() throws {
        let view = view("\u{1b}[48;2;0;255;0m      ", font: NSFont.monospacedSystemFont(ofSize: 24, weight: .regular))
        let before = view.withTerminal { $0.bufferLine(atRow: 0)?[0].attribute }
        let square = try pixels(view)
        view.selectionCornerRadius = 8
        let rounded = try pixels(view)
        let bounds = try selectionBounds(square)
        XCTAssertGreaterThan(rounded[index(bounds) + 1], 240)
        XCTAssertLessThan(rounded[index(bounds)], 20)
        XCTAssertEqual(rounded[index(bounds, center: true)], 255)
        let target = Target()
        let renderer = try renderer(target)
        for plain in [true, false] {
            renderer.plainTextEnabled = plain
            renderer.discardRowCache()
            view.selectionCornerRadius = 0
            let square = try metal(view, renderer: renderer, target: target)
            view.selectionCornerRadius = 8
            let rounded = try metal(view, renderer: renderer, target: target)
            let bounds = try selectionBounds(square, redIndex: 2)
            XCTAssertGreaterThan(rounded[index(bounds) + 1], 240)
            XCTAssertLessThan(rounded[index(bounds) + 2], 20)
            XCTAssertEqual(rounded[index(bounds, center: true) + 2], 255)
        }
        XCTAssertEqual(view.withTerminal { $0.bufferLine(atRow: 0)?[0].attribute }, before)
    }
    // Implements: FR-SET-92
    func testBidirectionalAndWideSelectionFollowVisualBuilderCells() throws {
        XCTAssertEqual(SelectionBackgroundGeometry.coalesced([4..<6, 1..<3, 2..<5, 9..<10, 0..<0]), [1..<6, 9..<10])
        for (text, start, end, expected) in [("abאבcd", 1, 3, [1..<2, 3..<4]), ("a한b", 2, 3, [1..<3])] {
            let view = view(text)
            view.selection.setSelection(start: Position(col: start, row: 0), end: Position(col: end, row: 0))
            view.selectionCornerRadius = 8
            view.metalBufferingMode = .perFrameAggregated
            let (snapshot, context) = snapshot(view)
            let row = try XCTUnwrap(snapshot.rows.first)
            if text.contains("א") { XCTAssertNotNil(row.bidiLayout) }
            let info = SnapshotTextBuilder().buildAttributedString(row: row, absoluteRow: snapshot.firstRow, context: context)
            XCTAssertEqual(SelectionBackgroundGeometry.spans(in: info.segments), expected)
            let target = Target()
            let renderer = try renderer(target)
            _ = try metal(view, renderer: renderer, target: target)
            let cells = try XCTUnwrap(renderer.lastDrawData?.frame).backgroundCells.filter { $0.cornerRadii.x > 0 }
            XCTAssertEqual(cells.count, expected.count)
            for (cell, span) in zip(cells, expected) {
                XCTAssertEqual(CGFloat(cell.shapeOrigin.x), CGFloat(span.lowerBound) * context.cellDimension.width * context.renderingScale, accuracy: 0.01)
                XCTAssertEqual(CGFloat(cell.shapeSize.x), CGFloat(span.count) * context.cellDimension.width * context.renderingScale, accuracy: 0.01)
            }
            view.selectionCornerRadius = 0
            let square = try pixels(view)
            view.selectionCornerRadius = 8
            XCTAssertFalse(try pixels(view) == square, "Native CG must round actual BiDi/wide selected cells")
        }
    }
    // Implements: FR-SET-92
    func testClippedDoubleHeightSelectionKeepsOriginalShapeBounds() throws {
        let view = view("\u{1b}#3      ")
        view.metalBufferingMode = .perFrameAggregated
        view.selectionCornerRadius = 8
        let target = Target()
        let renderer = try renderer(target)
        _ = try metal(view, renderer: renderer, target: target)
        let cell = try XCTUnwrap(renderer.lastDrawData?.frame?.backgroundCells.first { $0.cornerRadii.x > 0 })
        XCTAssertGreaterThan(cell.shapeSize.y, cell.size.y, "Clipping cannot invent a corner at the clipped row edge")
        XCTAssertTrue(cell.shapeOrigin.y < cell.position.y || cell.shapeOrigin.y + cell.shapeSize.y > cell.position.y + cell.size.y)
        let shapeCenterX = min(239, max(0, Int(cell.position.x + cell.size.x / 2)))
        let shapeRow = min(119, max(0, Int(120 - cell.position.y - cell.size.y / 2)))
        let bytes = try metal(view, renderer: renderer, target: target)
        XCTAssertEqual(bytes[(shapeRow * 240 + shapeCenterX) * 4 + 3], 255)
        let clipEdgeX = min(239, max(0, Int(cell.position.x)))
        let clipEdgeY = min(119, max(0, Int(120 - cell.position.y - 0.5)))
        XCTAssertGreaterThan(bytes[(clipEdgeY * 240 + clipEdgeX) * 4 + 3], 240,
                             "The clipped internal row edge stays straight rather than gaining a false corner")
        view.selectionCornerRadius = 0
        let square = try pixels(view)
        view.selectionCornerRadius = 8
        let rounded = try pixels(view)
        let bounds = try selectionBounds(square)
        let lowerClipCorner = ((Int(bounds.maxY) - 1) * 240 + Int(bounds.minX)) * 4
        XCTAssertGreaterThan(rounded[lowerClipCorner + 3], 240,
                             "CoreGraphics clips the full rounded shape and preserves the internal straight edge")
        XCTAssertLessThan(rounded[index(bounds) + 3], 30)
    }
    // Implements: FR-SET-92
    func testCapturedRadiusInvalidatesContextAndDefaultIsStable() {
        let view = view()
        let original = snapshot(view).1
        let captured = FrameViewState(view: view)
        view.selectionCornerRadius = 8
        XCTAssertEqual(captured.selectionCornerRadius, 0)
        XCTAssertEqual(snapshot(view).1.selectionCornerRadius, 8)
        XCTAssertNotEqual(original.identity, snapshot(view).1.identity)
        view.selectionCornerRadius = 0
        XCTAssertEqual(original.identity, snapshot(view).1.identity)
        view.selectionCornerRadius = .nan
        XCTAssertEqual(snapshot(view).1.selectionCornerRadius, 0)
        view.selectionCornerRadius = -2
        XCTAssertEqual(snapshot(view).1.selectionCornerRadius, 0)
    }
    // Implements: FR-SET-92
    func testNativeMetalRoundsBothPlainAndDictionaryPathsAndRestoresExactPixels() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 24, weight: .regular)
        XCTAssertNotNil(PlainTextFont.analyze(font as CTFont), "Fixture must qualify the real optimized ASCII branch")
        let view = view(font: font)
        let target = Target()
        let renderer = try MetalTerminalRenderer(target: target)
        renderer.waitForCompletionAfterCommit = true
        renderer.capturesRenderedTexture = true
        renderer.capturesDrawData = true
        for plain in [true, false] {
            renderer.plainTextEnabled = plain
            renderer.discardRowCache()
            view.selectionCornerRadius = 0
            let square = try metal(view, renderer: renderer, target: target)
            if plain { XCTAssertGreaterThan(renderer.debugPlainRowCount, 0) }
            else { XCTAssertEqual(renderer.debugPlainRowCount, 0) }
            view.selectionCornerRadius = 8
            let rounded = try metal(view, renderer: renderer, target: target)
            XCTAssertFalse(rounded == square, "Radius must change actual rendered selection pixels")
            try assertCornersAndCenter(rounded, square: square, redIndex: 2)
            XCTAssertLessThan(stride(from: 3, to: rounded.count, by: 4).reduce(0) { $0 + Int(rounded[$1]) }, stride(from: 3, to: square.count, by: 4).reduce(0) { $0 + Int(square[$1]) })
            view.selectionCornerRadius = 0
            XCTAssertTrue(try metal(view, renderer: renderer, target: target) == square, "Radius zero restores exact original Metal pixels")
        }
    }
    // Implements: FR-SET-92
    func testCoreGraphicsRoundsSelectionAndToggleRestoresExactPixels() throws {
        let view = view()
        XCTAssertEqual(view.selectionCornerRadius, 0)
        let square = try pixels(view)
        XCTAssertGreaterThan(square.filter { $0 != 0 }.count, 0)
        view.selectionCornerRadius = 8
        let rounded = try pixels(view)
        XCTAssertFalse(rounded == square, "Radius must change actual rendered selection pixels")
        try assertCornersAndCenter(rounded, square: square)
        XCTAssertLessThan(stride(from: 3, to: rounded.count, by: 4).reduce(0) { $0 + Int(rounded[$1]) }, stride(from: 3, to: square.count, by: 4).reduce(0) { $0 + Int(square[$1]) })
        view.selectionCornerRadius = 0
        XCTAssertTrue(try pixels(view) == square, "Radius zero restores exact original pixels")
    }
}
#endif
