#if os(macOS)
import AppKit
import Metal
import XCTest
@testable import SwiftTerm

@MainActor
final class TerminalInactiveFadeTests: XCTestCase {
    private func makeView() -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 240, height: 100),
                                font: NSFont.monospacedSystemFont(ofSize: 18, weight: .regular),
                                options: TerminalOptions(cols: 12, rows: 3, scrollback: 5))
        view.frameDriver.invalidate()
        view.nativeForegroundColor = .white
        view.nativeBackgroundColor = .white
        return view
    }

    private func context(_ view: TerminalView) -> SnapshotRenderContext {
        SnapshotRenderContext(viewState: FrameViewState(view: view), style: .empty,
                              ansiColors: view.withTerminal { $0.ansiColors }, cols: 12)
    }

    private func rgb(_ color: NSColor) throws -> [CGFloat] {
        let value = try XCTUnwrap(color.usingColorSpace(.sRGB))
        return [value.redComponent, value.greenComponent, value.blueComponent, value.alphaComponent]
    }

    // Implements: FR-SET-53, FR-SET-54
    func testDefaultsAndInvalidMultipliersAreSafe() {
        let view = makeView()
        XCTAssertEqual(view.inactiveBackgroundMultiplier, 1)
        XCTAssertEqual(view.inactiveContentMultiplier, 1)
        view.inactiveBackgroundMultiplier = -1
        XCTAssertEqual(view.inactiveBackgroundMultiplier, 0)
        view.inactiveContentMultiplier = 2
        XCTAssertEqual(view.inactiveContentMultiplier, 1)
        view.inactiveBackgroundMultiplier = .nan
        XCTAssertEqual(view.inactiveBackgroundMultiplier, 1)
    }

    // Implements: FR-SET-53, FR-SET-54
    func testCapturedContentSurfaceSelectionAndCaretRolesAreIndependent() throws {
        let view = makeView()
        view.selectedTextBackgroundColor = .white
        view.selectedTextForegroundColor = .white
        view.caretColor = .white
        view.caretTextColor = .white
        let sourcePalette = view.withTerminal { $0.ansiColors }
        let before = context(view)
        view.inactiveBackgroundMultiplier = 0.82
        view.inactiveContentMultiplier = 0.65
        let faded = context(view)
        XCTAssertEqual(try rgb(faded.effectiveForegroundColor)[0], 0.65, accuracy: 0.001)
        XCTAssertEqual(try rgb(faded.effectiveBackgroundColor)[0], 0.82, accuracy: 0.001)
        XCTAssertEqual(try rgb(faded.selectedTextForegroundColor)[0], 0.65, accuracy: 0.001)
        XCTAssertEqual(try rgb(faded.selectedTextBackgroundColor)[0], 0.82, accuracy: 0.001)
        XCTAssertEqual(try rgb(faded.caretColor)[0], 0.65, accuracy: 0.001)
        XCTAssertEqual(try rgb(faded.caretTextColor)[0], 0.65, accuracy: 0.001)
        XCTAssertNotEqual(faded.identity, before.identity)
        XCTAssertEqual(view.withTerminal { $0.ansiColors }, sourcePalette)
        XCTAssertEqual(try rgb(view.nativeForegroundColor)[0], 1)
        XCTAssertEqual(try rgb(view.nativeBackgroundColor)[0], 1)
    }

    // Implements: FR-SET-53, FR-SET-54
    func testExplicitForegroundAndBackgroundWithSameRgbDoNotShareWrongCachedRole() throws {
        let view = makeView()
        view.inactiveBackgroundMultiplier = 0.25
        view.inactiveContentMultiplier = 0.5
        let attribute = Attribute(fg: .trueColor(red: 255, green: 255, blue: 255),
                                  bg: .trueColor(red: 255, green: 255, blue: 255), style: .underline)
        let builder = SnapshotTextBuilder()
        let attributes = try XCTUnwrap(builder.getAttributes(attribute, withUrl: false,
                                                             context: context(view)))
        let foreground = try XCTUnwrap(attributes[.foregroundColor] as? NSColor)
        let background = try XCTUnwrap(attributes[.backgroundColor] as? NSColor)
        XCTAssertEqual(try rgb(foreground)[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(try rgb(background)[0], 0.25, accuracy: 0.001)
        view.inactiveBackgroundMultiplier = 1
        view.inactiveContentMultiplier = 1
        let restored = try XCTUnwrap(builder.getAttributes(attribute, withUrl: false,
                                                           context: context(view)))
        XCTAssertEqual(try rgb(try XCTUnwrap(restored[.foregroundColor] as? NSColor))[0], 1)
    }

    // Implements: FR-SET-53, FR-SET-54
    func testNativeBackingLayerPreservesAlphaAndSourceBackground() throws {
        let view = makeView()
        view.nativeBackgroundColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5)
        view.inactiveBackgroundMultiplier = 0.25
        let color = try XCTUnwrap(view.layer?.backgroundColor)
        let native = try XCTUnwrap(NSColor(cgColor: color))
        XCTAssertEqual(try rgb(native)[0], 0.25, accuracy: 0.001)
        XCTAssertEqual(try rgb(native)[3], 0.5, accuracy: 0.001)
        XCTAssertEqual(try rgb(view.nativeBackgroundColor)[0], 1)
        XCTAssertEqual(view.backgroundOpacity, 0.5, accuracy: 0.001)
    }

    // Implements: FR-SET-53, FR-SET-54
    func testCoreGraphicsGlyphShapeAndCellBackgroundActuallyFadeSeparately() throws {
        let view = makeView()
        view.feed(text: "\u{1b}[38;2;255;0;0;48;2;0;0;255m█ ")
        view.frameTick()
        let original = try pixels(width: 240, height: 100) {
            view.drawTerminalContents(dirtyRect: view.bounds, context: $0, bufferOffset: 0)
        }
        view.inactiveContentMultiplier = 0.5
        view.inactiveBackgroundMultiplier = 0.25
        view.frameTick()
        let faded = try pixels(width: 240, height: 100) {
            view.drawTerminalContents(dirtyRect: view.bounds, context: $0, bufferOffset: 0)
        }
        XCTAssertGreaterThan(channelMax(original, offset: 2), 200)
        XCTAssertEqual(channelMax(faded, offset: 2), 128, accuracy: 2)
        XCTAssertEqual(channelMax(faded, offset: 0), 64, accuracy: 2)
    }

    // Implements: FR-SET-53, FR-SET-54
    func testImageContentDimmingPreservesTransparentPixelsAndAlpha() throws {
        let view = makeView()
        view.inactiveContentMultiplier = 0.5
        let current = context(view)
        let output = try pixels(width: 4, height: 4) { drawing in
            current.drawContent(in: drawing, rect: CGRect(x: 0, y: 0, width: 4, height: 4)) {
                drawing.setFillColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5).cgColor)
                drawing.fill(CGRect(x: 0, y: 0, width: 2, height: 4))
            }
        }
        guard output.count == 64 else { return XCTFail("Expected 4×4 RGBA image") }
        XCTAssertEqual(output[2], 64, accuracy: 2)
        XCTAssertEqual(output[3], 128, accuracy: 2)
        XCTAssertEqual(output[15], 0)
    }

    // Implements: FR-SET-53, FR-SET-54
    func testActualMetalPlainRowsAndImageVerticesUseContentMultiplier() throws {
        let view = makeView()
        view.inactiveContentMultiplier = 0.5
        view.inactiveBackgroundMultiplier = 0.25
        view.feed(text: "\u{1b}[38;2;255;0;0;48;2;0;0;255mA")
        let encoded = Data([UInt8](repeating: 255, count: 16)).base64EncodedString()
        view.feed(text: "\u{1b}_Ga=T,f=32,s=2,v=2,i=1,C=1;\(encoded)\u{1b}\\")
        let target = TerminalMetalLayerView(frame: view.bounds)
        target.renderDevice = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try MetalTerminalRenderer(target: target)
        let snapshot = TerminalSnapshot()
        let state = FrameViewState(view: view)
        view.withTerminal { terminal in
            _ = snapshot.refresh(terminal: terminal, viewState: state,
                                 selection: SnapshotSelectionState(selection: view.selection))
        }
        let data = renderer.buildDrawDataForTesting(snapshot: snapshot,
                                                    context: SnapshotRenderContext(viewState: state,
                                                                                   snapshot: snapshot))
        let backgrounds = data.rows.flatMap { cells($0.backgroundBuffer, count: $0.backgroundCount,
                                                    type: ColorCell.self) }
        let glyphs = data.rows.flatMap { cells($0.glyphGrayBuffer, count: $0.glyphGrayCount,
                                               type: TextCell.self) }
        XCTAssertTrue(backgrounds.contains { abs($0.color.z - 0.25) < 0.001 })
        XCTAssertTrue(glyphs.contains { abs($0.color.x - 0.5) < 0.001 })
        let images = data.rows.flatMap {
            $0.belowBackgroundImageBuffers + $0.underImageBuffers + $0.placeholderImageBuffers
                + $0.overImageBuffers + $0.otherImageBuffers
        }
        let firstImage = try XCTUnwrap(images.first)
        let vertices = cells(firstImage.buffer, count: firstImage.vertexCount, type: GlyphVertex.self)
        let vertex = try XCTUnwrap(vertices.first)
        XCTAssertEqual(vertex.color.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(vertex.color.w, 1, accuracy: 0.001)
        XCTAssertTrue(snapshot.kitty.renderSnapshot.imagesById[1]?.rgba.allSatisfy { $0 == 255 } == true)
    }

    private func cells<T>(_ buffer: MTLBuffer?, count: Int, type: T.Type) -> [T] {
        guard let buffer, count > 0, count <= buffer.length / MemoryLayout<T>.stride else { return [] }
        return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: T.self),
                                         count: count))
    }

    // Implements: FR-SET-53, FR-SET-54
    func testNativeCaretColorGlyphIsDimmedWithoutChangingSourceCaretColors() throws {
        let view = makeView()
        view.caretColor = .black
        view.caretTextColor = .white
        view.feed(text: "😀\u{1b}[2D")
        let caret = try XCTUnwrap(view.caretView)
        caret.style = .steadyBlock
        func rendered() throws -> [UInt8] {
            let snapshot = TerminalSnapshot()
            view.withTerminal { terminal in
                _ = snapshot.refresh(terminal: terminal, viewState: FrameViewState(view: view),
                                     selection: SnapshotSelectionState(selection: view.selection))
            }
            let cursor = try XCTUnwrap(snapshot.cursor)
            XCTAssertEqual(cursor.renderData.character, "😀")
            caret.setText(cursor.renderData)
            caret.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
            return try pixels(width: 64, height: 64) { caret.drawCursor(in: $0, hasFocus: true) }
        }
        let original = try rendered()
        view.inactiveContentMultiplier = 0.5
        let faded = try rendered()
        func mass(_ values: [UInt8]) -> Double {
            guard values.count.isMultiple(of: 4) else { return 0 }
            return stride(from: 0, to: values.count, by: 4).reduce(0) {
                $0 + Double(values[$1]) + Double(values[$1 + 1]) + Double(values[$1 + 2])
            }
        }
        let originalMass = mass(original)
        XCTAssertGreaterThan(originalMass, 0)
        guard originalMass > 0 else { return }
        XCTAssertEqual(mass(faded) / originalMass, 0.5, accuracy: 0.03)
        XCTAssertEqual(try rgb(try XCTUnwrap(view.caretTextColor))[0], 1)
    }

    // Implements: FR-SET-53, FR-SET-54
    func testMetalLiteralColorGlyphAndCaretVerticesUseContentFactor() throws {
        let view = makeView()
        view.caretViewTracksFocus = false
        view.inactiveContentMultiplier = 0.5
        view.feed(text: "😀\u{1b}[2D")
        let target = TerminalMetalLayerView(frame: view.bounds)
        target.renderDevice = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try MetalTerminalRenderer(target: target)
        let snapshot = TerminalSnapshot()
        let state = FrameViewState(view: view)
        view.withTerminal { terminal in
            _ = snapshot.refresh(terminal: terminal, viewState: state,
                                 selection: SnapshotSelectionState(selection: view.selection))
        }
        let data = renderer.buildDrawDataForTesting(snapshot: snapshot,
                                                    context: SnapshotRenderContext(viewState: state,
                                                                                   snapshot: snapshot))
        let glyphs = data.rows.flatMap { cells($0.glyphColorBuffer, count: $0.glyphColorCount,
                                               type: TextCell.self) }
        let glyph = try XCTUnwrap(glyphs.first, "Fixture must produce an actual color glyph")
        XCTAssertEqual(glyph.color.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(glyph.color.w, 1, accuracy: 0.001)
        let cursor = try XCTUnwrap(data.cursorGlyphVerticesColor.first,
                                   "Fixture must produce an actual color glyph under the block cursor")
        XCTAssertEqual(cursor.color.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(cursor.color.w, 1, accuracy: 0.001)
    }

    private func channelMax(_ pixels: [UInt8], offset: Int) -> Double {
        guard pixels.count.isMultiple(of: 4), (0..<4).contains(offset) else { return 0 }
        return Double(stride(from: offset, to: pixels.count, by: 4).map { pixels[$0] }.max() ?? 0)
    }

    private func pixels(width: Int, height: Int, draw: (CGContext) -> Void) throws -> [UInt8] {
        guard width > 0, height > 0, width <= 4096, height <= 4096 else {
            throw NSError(domain: "TerminalInactiveFadeTests", code: 1)
        }
        var output = [UInt8](repeating: 0, count: width * height * 4)
        try output.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: width, height: height,
                                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                                                    | CGImageAlphaInfo.premultipliedFirst.rawValue))
            draw(context)
        }
        return output
    }
}
#endif
