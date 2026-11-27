#if os(macOS)
import AppKit
import CoreText
import MetalKit
import QuartzCore
import XCTest
@testable import SwiftTerm

@MainActor
final class TerminalFontSynthesisTests: XCTestCase {
    private struct MissingFaceFixture {
        let font: NSFont
        let character: Character
        let glyph: CGGlyph
    }

    // Implements: FR-SET-74
    func testForceDefaultPreservesNativeSameFamilyBoldFace() throws {
        let view = makeView()
        XCTAssertFalse(view.forceFontStyles)
        let native = try XCTUnwrap(NSFont(name: "Menlo-Bold", size: 24)) as CTFont
        XCTAssertTrue(CTFontGetSymbolicTraits(native).contains(.traitBold))
        let result = FontSynthesisRenderer.resolve(font: native, requested: .traitBold,
                                                   enabled: true)
        XCTAssertTrue(CFEqual(result.font, native))
        XCTAssertTrue(result.synthesis.isEmpty)
    }

    // Implements: FR-SET-74
    func testMissingItalicUsesExplicitMatrixAndKeepsFamilyAndSize() throws {
        let fixture = try missingFaceFixture()
        let original = fixture.font as CTFont
        let result = FontSynthesisRenderer.resolve(font: original, requested: .traitItalic,
                                                   enabled: true)
        XCTAssertEqual(result.synthesis, .italic)
        XCTAssertEqual(CTFontCopyFamilyName(result.font) as String,
                       CTFontCopyFamilyName(original) as String)
        XCTAssertEqual(CTFontGetSize(result.font), CTFontGetSize(original))
        XCTAssertNotEqual(CTFontGetMatrix(result.font).c, CTFontGetMatrix(original).c)
        let disabled = FontSynthesisRenderer.resolve(font: original, requested: .traitItalic,
                                                     enabled: false)
        XCTAssertTrue(CFEqual(disabled.font, original))
        XCTAssertTrue(disabled.synthesis.isEmpty)
    }

    // Implements: FR-SET-74
    func testMissingBoldHasExpandedInkAndRealRasterizationCoverage() throws {
        let fixture = try missingFaceFixture()
        let rasterizer = CoreTextGlyphRasterizer()
        let plain = try bitmap(rasterizer.rasterize(font: fixture.font as CTFont, glyph: fixture.glyph))
        let bold = try bitmap(rasterizer.rasterize(font: fixture.font as CTFont, glyph: fixture.glyph,
                                                   synthesis: .bold))
        let plainBounds = FontSynthesisRenderer.inkBounds(font: fixture.font as CTFont,
                                                         glyph: fixture.glyph, synthesis: [])
        let boldBounds = FontSynthesisRenderer.inkBounds(font: fixture.font as CTFont,
                                                        glyph: fixture.glyph, synthesis: .bold)
        XCTAssertTrue(boldBounds.contains(plainBounds))
        XCTAssertGreaterThan(boldBounds.width, plainBounds.width)
        XCTAssertGreaterThan(boldBounds.height, plainBounds.height)
        XCTAssertGreaterThan(alphaMass(bold), alphaMass(plain))
        XCTAssertGreaterThanOrEqual(bold.width, plain.width)
        XCTAssertGreaterThanOrEqual(bold.height, plain.height)
    }

    // Implements: FR-SET-74
    func testSharedDrawingPrimitiveProducesRealSyntheticInk() throws {
        let fixture = try missingFaceFixture()
        func rendered(_ synthesis: FontSynthesis) throws -> [UInt8] {
            try pixels(width: 96, height: 96) { context in
                context.setFillColor(NSColor.white.cgColor)
                context.setStrokeColor(NSColor.white.cgColor)
                FontSynthesisRenderer.draw(font: fixture.font as CTFont, glyphs: [fixture.glyph],
                                            positions: [CGPoint(x: 24, y: 32)],
                                            synthesis: synthesis, in: context)
            }
        }
        let plain = try rendered([])
        XCTAssertGreaterThan(luminanceMass(try rendered(.bold)), luminanceMass(plain))
        XCTAssertNotEqual(try rendered(.italic), plain)
    }

    // Implements: FR-SET-74
    func testNativeRasterizerKeepsSeparateAtlasKeysForSynthesis() {
        let plain = GlyphKey(rasterFontToken: 7, glyph: 9, synthesis: [])
        let bold = GlyphKey(rasterFontToken: 7, glyph: 9, synthesis: .bold)
        let italic = GlyphKey(rasterFontToken: 7, glyph: 9, synthesis: .italic)
        XCTAssertNotEqual(plain, bold)
        XCTAssertNotEqual(plain, italic)
        XCTAssertNotEqual(bold, italic)
    }

    // Implements: FR-SET-74
    func testCaretRendersTheSameSynthesisMetadataAsText() throws {
        let fixture = try missingFaceFixture()
        let view = makeView(font: fixture.font)
        let caret = try XCTUnwrap(view.caretView)
        caret.frame = NSRect(x: 0, y: 0, width: 64, height: 64)
        caret.style = .steadyBlock
        let scalar = try XCTUnwrap(fixture.character.unicodeScalars.first)
        let code = try XCTUnwrap(Int32(exactly: scalar.value))
        func rendered(_ synthesis: FontSynthesis) throws -> [UInt8] {
            caret.setText(CaretRenderData(
                code: code, width: 1,
                cellAttribute: Attribute(fg: .defaultColor, bg: .defaultColor, style: .bold),
                character: fixture.character,
                attributes: [.font: fixture.font, .foregroundColor: NSColor.white,
                             SwiftTermFontSynthesisKey: synthesis],
                cursorColor: .black, textColor: .white, textBlinkVisible: true,
                customBlockGlyphs: false, normalFont: fixture.font))
            return try pixels(width: 64, height: 64) { context in
                caret.drawCursor(in: context, hasFocus: true)
            }
        }
        let plain = try rendered([])
        XCTAssertGreaterThan(luminanceMass(try rendered(.bold)), luminanceMass(plain))
    }

    // Implements: FR-SET-74
    func testCoreGraphicsRendererChangesInkWithoutChangingTerminalAttributes() throws {
        let fixture = try missingFaceFixture()
        let view = makeView(font: fixture.font)
        view.feed(text: "\u{1b}[1m\(fixture.character)")
        view.frameTick()
        let before = view.withTerminal { $0.bufferLine(atRow: 0)?[0].attribute }
        func rendered() throws -> [UInt8] {
            try pixels(width: 240, height: 120) { context in
                view.drawTerminalContents(dirtyRect: view.bounds, context: context, bufferOffset: 0)
            }
        }
        let plain = try rendered()
        view.forceFontStyles = true
        view.frameTick()
        XCTAssertGreaterThan(luminanceMass(try rendered()), luminanceMass(plain))
        XCTAssertEqual(view.withTerminal { $0.bufferLine(atRow: 0)?[0].attribute }, before)
        view.forceFontStyles = false
        view.frameTick()
        XCTAssertEqual(try rendered(), plain)
    }


    // Implements: FR-SET-74
    func testLineResolverReshapesNativeFaceBeforeUsingItsGlyphIDs() throws {
        let font = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 24))
        let line = FontSynthesisRenderer.line(for: NSAttributedString(string: "Ab", attributes: [
            .font: font, SwiftTermRequestedFontStylesKey: FontSynthesis.bold,
            SwiftTermFontSynthesisKey: FontSynthesis.bold]))
        let runs = try XCTUnwrap(CTLineGetGlyphRuns(line) as? [CTRun])
        let run = try XCTUnwrap(runs.first)
        let attrs = CTRunGetAttributes(run) as NSDictionary
        let result = try XCTUnwrap(attrs[NSAttributedString.Key.font] as? NSFont) as CTFont
        XCTAssertTrue(CTFontGetSymbolicTraits(result).contains(.traitBold))
        XCTAssertEqual(CTFontCopyFamilyName(result), CTFontCopyFamilyName(font as CTFont))
        XCTAssertEqual(attrs[SwiftTermFontSynthesisKey] as? FontSynthesis, [])
        var expected = [CGGlyph](repeating: 0, count: 2)
        XCTAssertTrue(CTFontGetGlyphsForCharacters(result, Array("Ab".utf16), &expected, 2))
        var actual = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
        CTRunGetGlyphs(run, CFRange(), &actual)
        XCTAssertEqual(actual, expected)
    }

    // Implements: FR-SET-74
    func testMetricsCacheKeepsSynthesisDistinctAcrossWarmLookupAndEviction() throws {
        let fixture = try missingFaceFixture()
        let cache = GlyphMetricsCache(maxEntries: 2, maxFonts: 2)
        var plain = cache.intern(font: fixture.font as CTFont)
        var bold = cache.intern(font: fixture.font as CTFont, synthesis: .bold)
        let plainBounds = cache.metrics(font: &plain, glyph: fixture.glyph).metrics.inkBounds
        let boldBounds = cache.metrics(font: &bold, glyph: fixture.glyph).metrics.inkBounds
        XCTAssertGreaterThan(boldBounds.width, plainBounds.width)
        XCTAssertGreaterThan(boldBounds.height, plainBounds.height)
        XCTAssertEqual(cache.metrics(font: &plain, glyph: fixture.glyph).metrics.inkBounds, plainBounds)
        XCTAssertTrue(cache.metrics(font: &bold, glyph: fixture.glyph).wasHit)
        var other = cache.intern(font: CTFontCreateCopyWithAttributes(fixture.font as CTFont, 18, nil, nil))
        _ = cache.metrics(font: &other, glyph: fixture.glyph)
        XCTAssertEqual(cache.metrics(font: &bold, glyph: fixture.glyph).metrics.inkBounds, boldBounds)
    }

    // Implements: FR-SET-74
    func testRequestedStylesReachRowAndCaretWithoutMutatingBuffer() throws {
        let fixture = try missingFaceFixture()
        let view = makeView(font: fixture.font)
        view.forceFontStyles = true
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view), style: .empty,
            ansiColors: view.withTerminal { $0.ansiColors }, cols: 8)
        let attribute = Attribute(fg: .defaultColor, bg: .defaultColor, style: [.bold, .italic])
        let values = try XCTUnwrap(SnapshotTextBuilder().getAttributes(attribute, withUrl: false,
                                                                      context: context)).values
        XCTAssertEqual(values[SwiftTermFontSynthesisKey] as? FontSynthesis, [.bold, .italic])
        XCTAssertEqual(values[SwiftTermRequestedFontStylesKey] as? FontSynthesis, [.bold, .italic])
        let caret = attributedValue(for: attribute, usingFg: .white, andBg: .black, context: context)
        XCTAssertEqual(caret[SwiftTermFontSynthesisKey] as? FontSynthesis, [.bold, .italic])
        XCTAssertEqual(caret[SwiftTermRequestedFontStylesKey] as? FontSynthesis, [.bold, .italic])
    }


    // Implements: FR-SET-74
    func testNativeMetalBothPlainAndDictionaryPathsApplySynthesisAndInvalidateWarmRows() throws {
        let font = try synthesisTestFont()
        XCTAssertNotNil(PlainTextFont.analyze(font as CTFont),
                        "Runtime fixture must qualify the optimized ASCII path")
        let view = makeView(font: font)
        view.feed(text: "\u{1b}[?25l\u{1b}[1mAH")
        let target = TerminalMetalLayerView(frame: view.bounds)
        target.renderDevice = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        target.metalLayer.framebufferOnly = false
        target.renderContentsScale = 1
        target.renderDrawableSize = view.bounds.size
        let renderer = try MetalTerminalRenderer(target: target)
        renderer.waitForCompletionAfterCommit = true
        renderer.capturesRenderedTexture = true
        for plain in [true, false] {
            renderer.plainTextEnabled = plain
            renderer.discardRowCache()
            view.forceFontStyles = false
            let original = try metalPixels(view, renderer: renderer, target: target)
            view.forceFontStyles = true
            let bold = try metalPixels(view, renderer: renderer, target: target)
            XCTAssertEqual(renderer.debugPlainRowCount, plain ? view.withTerminal { $0.rows } : 0,
                           "Every styled row must use the requested real renderer path")
            XCTAssertGreaterThan(Double(luminanceMass(bold)), Double(luminanceMass(original)) * 1.05,
                                 "A real synthetic stroke must add substantial ink, plain=\(plain)")
            XCTAssertTrue(try metalPixels(view, renderer: renderer, target: target) == bold,
                          "Warm rows must retain the same synthesis")
            if plain { XCTAssertGreaterThan(renderer.debugPlainRowCount + renderer.debugRowCacheCounts.cached, 0) }
            view.forceFontStyles = false
            XCTAssertTrue(try metalPixels(view, renderer: renderer, target: target) == original,
                          "Disabling synthesis restores the original atlas entries and pixels")
            view.forceFontStyles = true
            view.feed(text: "\r\u{1b}[0;3mAH")
            let italic = try metalPixels(view, renderer: renderer, target: target)
            view.forceFontStyles = false
            XCTAssertFalse(try metalPixels(view, renderer: renderer, target: target) == italic,
                           "Italic matrix must reach both shaping/ASCII and atlas rasterization")
            view.feed(text: "\r\u{1b}[0;1mAH")
        }
    }

    private func metalPixels(_ view: TerminalView, renderer: MetalTerminalRenderer,
                             target: TerminalMetalLayerView) throws -> [UInt8] {
        let state = FrameViewState(view: view)
        let snapshot = TerminalSnapshot()
        view.withTerminal { terminal in
            _ = snapshot.refresh(terminal: terminal, viewState: state, selection: .empty)
        }
        renderer.prepareSnapshotForImmediateDraw(snapshot: snapshot,
            context: SnapshotRenderContext(viewState: state, snapshot: snapshot))
        renderer.render(frame: try XCTUnwrap(target.acquireDrawableFrame(),
                                           "Native offscreen layer must produce its drawable"))
        let texture = try XCTUnwrap(renderer.lastRenderedTexture)
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&bytes, bytesPerRow: texture.width * 4,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return bytes
    }


    // Implements: FR-SET-74
    func testNativeFallbackFaceRemovesAnInheritedSyntheticItalicMatrix() throws {
        let regular = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 24)) as CTFont
        let native = try XCTUnwrap(NSFont(name: "Menlo-Italic", size: 24)) as CTFont
        let inherited = FontSynthesisRenderer.drawingFont(regular, synthesis: .italic)
        XCTAssertNotEqual(CTFontGetMatrix(inherited).c, CTFontGetMatrix(regular).c)
        let line = FontSynthesisRenderer.line(for: NSAttributedString(string: "AH", attributes: [
            .font: inherited as NSFont, SwiftTermRequestedFontStylesKey: FontSynthesis.italic,
            SwiftTermFontSynthesisKey: FontSynthesis.italic,
            SwiftTermFontSynthesisMatrixKey: FontSynthesisMatrix(CTFontGetMatrix(regular))]))
        let run = try XCTUnwrap((CTLineGetGlyphRuns(line) as? [CTRun])?.first)
        let attrs = CTRunGetAttributes(run) as NSDictionary
        let result = try XCTUnwrap(attrs[NSAttributedString.Key.font] as? NSFont) as CTFont
        XCTAssertTrue(CTFontGetSymbolicTraits(result).contains(.traitItalic))
        XCTAssertEqual(CTFontGetMatrix(result), CTFontGetMatrix(native),
                       "Native italic must not receive an additional inherited synthetic slant")
        XCTAssertEqual(attrs[SwiftTermFontSynthesisKey] as? FontSynthesis, [])
    }


    // Implements: FR-SET-74
    func testSyntheticRasterBoundsContainAllRealInkAtOneAndTwoTimesScale() throws {
        let fixture = try missingFaceFixture()
        let rasterizer = CoreTextGlyphRasterizer()
        rasterizer.fontSmoothing = false
        for scale: CGFloat in [1, 2] {
            let font = CTFontCreateCopyWithAttributes(fixture.font as CTFont,
                                                      fixture.font.pointSize * scale, nil, nil)
            for synthesis: FontSynthesis in [.bold, .italic, [.bold, .italic]] {
                let bitmap = try bitmap(rasterizer.rasterize(font: font, glyph: fixture.glyph,
                                                             synthesis: synthesis))
                let oracle = try pixels(width: 192, height: 192) { context in
                    context.setFillColor(NSColor.white.cgColor)
                    context.setStrokeColor(NSColor.white.cgColor)
                    FontSynthesisRenderer.draw(font: font, glyphs: [fixture.glyph],
                        positions: [CGPoint(x: 64, y: 64)], synthesis: synthesis, in: context)
                }
                let oracleMass = stride(from: 3, to: oracle.count, by: 4).reduce(UInt64(0)) {
                    $0 + UInt64(oracle[$1])
                }
                XCTAssertEqual(alphaMass(bitmap), oracleMass,
                               "Raster allocation must keep every actual ink pixel at scale \(scale), style \(synthesis)")
            }
        }
    }

    // Implements: FR-SET-74
    func testFallbackRunsRetainStyleIntentAndResolveActualNativeFaces() throws {
        let font = try synthesisTestFont()
        var attrs: [NSAttributedString.Key: Any] = [.font: font]
        FontSynthesisRenderer.apply(to: &attrs, requested: [.bold, .italic], enabled: true)
        let line = FontSynthesisRenderer.line(for: NSAttributedString(string: "A漢", attributes: attrs))
        let runs = try XCTUnwrap(CTLineGetGlyphRuns(line) as? [CTRun])
        var sawFallback = false
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let actual = try XCTUnwrap(attrs[NSAttributedString.Key.font] as? NSFont) as CTFont
            let synthesis = try XCTUnwrap(attrs[SwiftTermFontSynthesisKey] as? FontSynthesis)
            XCTAssertEqual(attrs[SwiftTermRequestedFontStylesKey] as? FontSynthesis, [.bold, .italic])
            let traits = CTFontGetSymbolicTraits(actual)
            XCTAssertEqual(synthesis.contains(.bold), !traits.contains(.traitBold))
            XCTAssertEqual(synthesis.contains(.italic), !traits.contains(.traitItalic))
            XCTAssertEqual(CTFontGetMatrix(actual).c, synthesis.contains(.italic) ? 0.2 : 0, accuracy: 0.0001)
            if CTFontCopyFamilyName(actual) as String != "Trano Synthesis Fixture" { sawFallback = true }
        }
        XCTAssertTrue(sawFallback, "Fixture must exercise a real Core Text fallback font")
    }

    // Implements: FR-SET-74
    func testNativeStylePixelsRemainUnchangedWhenForceIsEnabled() throws {
        let view = makeView()
        view.feed(text: "\u{1b}[?25l\u{1b}[1mA\u{1b}[0;3mH\u{1b}[1mW")
        view.frameTick()
        func rendered() throws -> [UInt8] {
            try pixels(width: 240, height: 120) { context in
                view.drawTerminalContents(dirtyRect: view.bounds, context: context, bufferOffset: 0)
            }
        }
        let original = try rendered()
        view.forceFontStyles = true
        view.frameTick()
        XCTAssertTrue(try rendered() == original, "Real native faces must retain their exact pixels")
    }


    // Implements: FR-SET-74
    func testNativeMetalBlockCursorUsesTheSameSyntheticGlyphInk() throws {
        let font = try synthesisTestFont()
        let view = makeView(font: font)
        view.nativeForegroundColor = .black
        view.caretColor = .black
        view.caretTextColor = .white
        view.forcedCursorStyle = .steadyBlock
        view.feed(text: "\u{1b}[1mA\r")
        let target = TerminalMetalLayerView(frame: view.bounds)
        target.renderDevice = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        target.metalLayer.framebufferOnly = false
        target.renderContentsScale = 1
        target.renderDrawableSize = view.bounds.size
        let renderer = try MetalTerminalRenderer(target: target)
        renderer.waitForCompletionAfterCommit = true
        renderer.capturesRenderedTexture = true
        let original = try metalPixels(view, renderer: renderer, target: target)
        XCTAssertGreaterThan(luminanceMass(original), 0, "Only the white caret glyph is visible")
        view.forceFontStyles = true
        let bold = try metalPixels(view, renderer: renderer, target: target)
        XCTAssertGreaterThan(Double(luminanceMass(bold)), Double(luminanceMass(original)) * 1.05)
        view.forceFontStyles = false
        XCTAssertTrue(try metalPixels(view, renderer: renderer, target: target) == original)
    }

    private func makeView(font: NSFont? = nil) -> TerminalView {
        _ = NSApplication.shared
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 240, height: 120),
                                font: font ?? NSFont(name: "Menlo-Regular", size: 24),
                                options: TerminalOptions(cols: 8, rows: 3, scrollback: 5))
        view.metalScaleFactorOverride = 1
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        view.caretViewTracksFocus = false
        return view
    }

    private func missingFaceFixture() throws -> MissingFaceFixture {
        let font = try XCTUnwrap(NSFont(name: "Apple Symbols", size: 24),
                                 "Native qualification requires Apple's Apple Symbols font")
        let traits = CTFontGetSymbolicTraits(font as CTFont)
        XCTAssertFalse(traits.contains(.traitBold))
        XCTAssertFalse(traits.contains(.traitItalic))
        XCTAssertNil(CTFontCreateCopyWithSymbolicTraits(font as CTFont, 0, nil, .traitBold, .traitBold),
                     "Fixture must have no same-family native bold face")
        XCTAssertNil(CTFontCreateCopyWithSymbolicTraits(font as CTFont, 0, nil, .traitItalic, .traitItalic),
                     "Fixture must have no same-family native italic face")
        let candidates: [Character] = ["A", "H", "☀", "◆", "▲"]
        for candidate in candidates {
            let codeUnits = Array(String(candidate).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: codeUnits.count)
            if CTFontGetGlyphsForCharacters(font as CTFont, codeUnits, &glyphs, codeUnits.count),
               let glyph = glyphs.first, glyph != 0,
               let outline = CTFontCreatePathForGlyph(font as CTFont, glyph, nil),
               !outline.boundingBoxOfPath.isEmpty {
                return MissingFaceFixture(font: font, character: candidate, glyph: glyph)
            }
        }
        throw NSError(domain: "TerminalFontSynthesisTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Fixture requires an outlined Apple Symbols glyph"])
    }

    private func bitmap(_ result: GlyphRasterizationResult) throws -> GlyphBitmap {
        guard case .bitmap(let bitmap) = result else {
            throw NSError(domain: "TerminalFontSynthesisTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Expected real native glyph rasterization"])
        }
        let (area, areaOverflow) = bitmap.width.multipliedReportingOverflow(by: bitmap.height)
        let (expectedCount, countOverflow) = area.multipliedReportingOverflow(by: 4)
        guard bitmap.width > 0, bitmap.height > 0, !areaOverflow, !countOverflow,
              bitmap.pixels.count == expectedCount else {
            throw NSError(domain: "TerminalFontSynthesisTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Native bitmap dimensions must match its RGBA byte count"])
        }
        return bitmap
    }

    private func alphaMass(_ bitmap: GlyphBitmap) -> UInt64 {
        stride(from: 3, to: bitmap.pixels.count, by: 4).reduce(0) { $0 + UInt64(bitmap.pixels[$1]) }
    }

    private func luminanceMass(_ pixels: [UInt8]) -> UInt64 {
        guard pixels.count.isMultiple(of: 4) else {
            XCTFail("Expected complete RGBA pixels")
            return 0
        }
        return stride(from: 0, to: pixels.count, by: 4).reduce(0) {
            $0 + UInt64(pixels[$1]) + UInt64(pixels[$1 + 1]) + UInt64(pixels[$1 + 2])
        }
    }

    private func pixels(width: Int, height: Int,
                        draw: (CGContext) -> Void) throws -> [UInt8] {
        guard width > 0, height > 0, width <= 4096, height <= 4096 else {
            throw NSError(domain: "TerminalFontSynthesisTests", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Test bitmap dimensions must be positive and bounded"])
        }
        var values = [UInt8](repeating: 0, count: width * height * 4)
        try values.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue))
            context.setAllowsFontSmoothing(false)
            context.setShouldSmoothFonts(false)
            draw(context)
        }
        return values
    }
}
#endif
