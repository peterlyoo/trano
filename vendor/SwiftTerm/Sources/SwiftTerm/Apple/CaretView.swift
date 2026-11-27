//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 4/16/23.
//

#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import CoreText

extension CaretView {
    func drawCursor (in context: CGContext, hasFocus: Bool) {
#if os(macOS)
        let multiplier = renderContentMultiplier
#else
        let multiplier: CGFloat = 1
#endif
        beginTerminalContentDimming(in: context, multiplier: multiplier)
        drawCursorContents(in: context, hasFocus: hasFocus)
        endTerminalContentDimming(in: context, rect: bounds, multiplier: multiplier)
    }

    private func drawCursorContents(in context: CGContext, hasFocus: Bool) {
        guard let ctline else {
            return
        }
        guard let terminal else {
            return
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: [bounds])
        context.setFillColor(TTColor.clear.cgColor)
        context.fill ([bounds])
        let cursorColor = renderCursorColor
        
        if !hasFocus {
            context.setStrokeColor(cursorColor.cgColor)
            context.setLineWidth(3)
            context.stroke(bounds)
            return
        }
        context.setFillColor(cursorColor.cgColor)
        let region: CGRect
        switch style {
        case .blinkBar, .steadyBar:
            region = CGRect (x: 0, y: 0, width: 2, height: bounds.height)
        case .blinkBlock, .steadyBlock:
            region = bounds
        case .blinkUnderline, .steadyUnderline:
            region = CGRect (x: 0, y: 0, width: bounds.width, height: 2)
        }
        context.fill([region])

        let normalFont = renderNormalFont ?? terminal.fontSet.normal
        // Must be the offset the text renderers use, or the glyph drawn inside
        // the caret lands on a different baseline than the row under it.
        let terminalCell: TerminalView.CellDimension? = terminal.cellDimension
        let yOffset = CellGeometry.baselineOffset(
            normalFont: normalFont, cellHeight: terminalCell?.height ?? bounds.height)
        
        guard style == .steadyBlock || style  == .blinkBlock else {
            return
        }
        let caretFG = renderTextColor
        context.setFillColor(caretFG.cgColor)
        context.setStrokeColor(caretFG.cgColor)
        if let powerlineCodePoint,
           PowerlineRenderer.shouldRender(codePoint: powerlineCodePoint,
                                          customGlyphsEnabled: renderCustomBlockGlyphs) {
            PowerlineRenderer.draw(codePoint: powerlineCodePoint,
                                   in: context,
                                   cellRect: bounds,
                                   scaleX: terminal.backingScaleFactor(),
                                   scaleY: terminal.backingScaleFactor(),
                                   color: caretFG.cgColor)
            return
        }
        for run in CTLineGetGlyphRuns(ctline) as? [CTRun] ?? [] {
            let runGlyphsCount = CTRunGetGlyphCount(run)
            let runAttributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any] ?? [:]
            let runFont = (runAttributes[.font] as? TTFont) ?? normalFont
            let ctRunFont = runFont as CTFont
            let synthesis = runAttributes[SwiftTermFontSynthesisKey] as? FontSynthesis ?? []

            let runGlyphs = [CGGlyph](unsafeUninitializedCapacity: runGlyphsCount) { (bufferPointer, count) in
                CTRunGetGlyphs(run, CFRange(), bufferPointer.baseAddress!)
                count = runGlyphsCount
            }

            // Center full-width (CJK) glyphs within the caret the same way as the
            // surrounding text so the character doesn't shift under the cursor,
            // and scale an oversized glyph down to match (drawTerminalContents
            // does the same via CTFontCreateCopyWithAttributes). The caret bounds
            // span `glyphColumnWidth` cells, so the centered glyph isn't clipped.
            let glyphPolicy = runAttributes[SwiftTermGlyphPolicyKey] as? TerminalGlyphPlacementPolicy
            // A lone fallback glyph in a single cell is fitted like the row
            // renderers do; see `fallbackGlyphFit`.
            let fitsFallbackGlyph = glyphPolicy == nil && glyphColumnWidth == 1
                && CTLineGetGlyphCount(ctline) == 1 && !terminal.isPrimaryFont(ctRunFont)
            let fits = runGlyphs.map { glyph in
                if let glyphPolicy {
                    return terminal.glyphSlotFit(font: ctRunFont, glyph: glyph,
                                                 columnWidth: glyphColumnWidth,
                                                 policy: glyphPolicy, synthesis: synthesis)
                }
                if fitsFallbackGlyph {
                    return terminal.fallbackGlyphFit(font: ctRunFont, glyph: glyph, synthesis: synthesis)
                }
                return terminal.glyphSlotFit(font: ctRunFont, glyph: glyph, columnWidth: glyphColumnWidth, synthesis: synthesis)
            }
            let positions = fits.map { CGPoint(x: $0.dx, y: yOffset + $0.dy) }
            if fits.contains(where: { $0.scaleX != 1 || $0.scaleY != 1 }) {
                for i in 0..<runGlyphsCount {
                    let fit = fits[i]
                    let g = runGlyphs[i]
                    let p = positions[i]
                    if fit.isUniform {
                        let s = fit.scale
                        let drawFont: CTFont = s == 1
                            ? ctRunFont
                            : CTFontCreateCopyWithAttributes(ctRunFont, CTFontGetSize(ctRunFont) * s, nil, nil)
                        FontSynthesisRenderer.draw(font: drawFont, glyphs: [g], positions: [p], synthesis: synthesis, italicAlreadyApplied: true, in: context)
                    } else {
                        context.saveGState()
                        context.translateBy(x: p.x, y: p.y)
                        context.scaleBy(x: fit.scaleX, y: fit.scaleY)
                        let origin = CGPoint.zero
                        FontSynthesisRenderer.draw(font: ctRunFont, glyphs: [g], positions: [origin], synthesis: synthesis, italicAlreadyApplied: true, in: context)
                        context.restoreGState()
                    }
                }
            } else {
                FontSynthesisRenderer.draw(font: ctRunFont, glyphs: runGlyphs, positions: positions, synthesis: synthesis, italicAlreadyApplied: true, in: context)
            }
        }
    }
}

#endif
#endif // !SWIFTTERM_EMBEDDED
