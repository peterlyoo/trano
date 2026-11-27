#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import CoreGraphics
import CoreText

let SwiftTermFontSynthesisKey = NSAttributedString.Key("SwiftTermFontSynthesis")
let SwiftTermRequestedFontStylesKey = NSAttributedString.Key("SwiftTermRequestedFontStyles")
let SwiftTermFontSynthesisMatrixKey = NSAttributedString.Key("SwiftTermFontSynthesisMatrix")

struct FontSynthesisMatrix: Hashable, Sendable {
    let a: CGFloat
    let b: CGFloat
    let c: CGFloat
    let d: CGFloat
    let tx: CGFloat
    let ty: CGFloat

    init(_ matrix: CGAffineTransform) {
        a = matrix.a
        b = matrix.b
        c = matrix.c
        d = matrix.d
        tx = matrix.tx
        ty = matrix.ty
    }

    var value: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
}

struct FontSynthesis: OptionSet, Sendable, Hashable {
    let rawValue: UInt8
    static let bold = FontSynthesis(rawValue: 1)
    static let italic = FontSynthesis(rawValue: 2)

    var traits: CTFontSymbolicTraits {
        var result: CTFontSymbolicTraits = []
        if contains(.bold) { result.insert(.traitBold) }
        if contains(.italic) { result.insert(.traitItalic) }
        return result
    }

    static func requested(face: Int) -> FontSynthesis {
        var result: FontSynthesis = []
        if face & 1 != 0 { result.insert(.bold) }
        if face & 2 != 0 { result.insert(.italic) }
        return result
    }
}

struct FontSynthesisResolution {
    let font: CTFont
    let synthesis: FontSynthesis
}

enum FontSynthesisRenderer {
    static func nativeFont(font: CTFont, requested: CTFontSymbolicTraits) -> CTFont {
        let mask: CTFontSymbolicTraits = [.traitBold, .traitItalic]
        let desired = CTFontGetSymbolicTraits(font).intersection(mask).union(requested.intersection(mask))
        if CTFontGetSymbolicTraits(font).isSuperset(of: desired) { return font }
        func candidate(_ traits: CTFontSymbolicTraits, from source: CTFont) -> CTFont? {
            guard let result = CTFontCreateCopyWithSymbolicTraits(source, 0, nil, traits, mask),
                  CFEqual(CTFontCopyFamilyName(font), CTFontCopyFamilyName(result)),
                  CTFontGetSymbolicTraits(result).isSuperset(of: traits) else { return nil }
            return result
        }
        if let result = candidate(desired, from: font) { return result }
        var result = font
        for trait: CTFontSymbolicTraits in [.traitBold, .traitItalic] where desired.contains(trait) {
            let preserving = CTFontGetSymbolicTraits(result).intersection(mask).union(trait)
            if let next = candidate(preserving, from: result) { result = next }
        }
        return result
    }

    static func resolve(font: CTFont, requested: CTFontSymbolicTraits,
                        enabled: Bool) -> FontSynthesisResolution {
        guard enabled else { return FontSynthesisResolution(font: font, synthesis: []) }
        let native = nativeFont(font: font, requested: requested)
        let traits = CTFontGetSymbolicTraits(native)
        var synthesis: FontSynthesis = []
        if requested.contains(.traitBold), !traits.contains(.traitBold) { synthesis.insert(.bold) }
        if requested.contains(.traitItalic), !traits.contains(.traitItalic) { synthesis.insert(.italic) }
        return FontSynthesisResolution(font: drawingFont(native, synthesis: synthesis), synthesis: synthesis)
    }

    static func drawingFont(_ font: CTFont, synthesis: FontSynthesis) -> CTFont {
        guard synthesis.contains(.italic),
              !CTFontGetSymbolicTraits(font).contains(.traitItalic) else { return font }
        var matrix = CTFontGetMatrix(font).concatenating(CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0))
        return CTFontCreateCopyWithAttributes(font, 0, &matrix, nil)
    }

    static func matches(_ font: CTFont, base: CTFont) -> Bool {
        if CFEqual(font, base) { return true }
        let shear = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
        guard !CTFontGetSymbolicTraits(base).contains(.traitItalic),
              CTFontGetMatrix(font) == CTFontGetMatrix(base).concatenating(shear) else { return false }
        return CFEqual(font, drawingFont(base, synthesis: .italic))
    }

    static func strokeWidth(font: CTFont) -> CGFloat { CTFontGetSize(font) / 24 }

    static func inkBounds(font: CTFont, glyph: CGGlyph,
                          synthesis: FontSynthesis, italicAlreadyApplied: Bool = false) -> CGRect {
        var glyph = glyph
        let drawFont = italicAlreadyApplied ? font : drawingFont(font, synthesis: synthesis)
        let bounds = CTFontGetBoundingRectsForGlyphs(drawFont, .horizontal, &glyph, nil, 1)
        guard synthesis.contains(.bold), !bounds.isEmpty else { return bounds }
        let radius = strokeWidth(font: drawFont) / 2
        return bounds.insetBy(dx: -radius, dy: -radius)
    }

    static func draw(font: CTFont, glyphs: [CGGlyph], positions: [CGPoint],
                     synthesis: FontSynthesis, italicAlreadyApplied: Bool = false, in context: CGContext) {
        guard glyphs.count == positions.count, !glyphs.isEmpty else { return }
        context.saveGState()
        if synthesis.contains(.bold) {
            context.setTextDrawingMode(.fillStroke)
            context.setLineWidth(strokeWidth(font: font))
            context.setLineJoin(.round)
        }
        let drawFont = italicAlreadyApplied ? font : drawingFont(font, synthesis: synthesis)
        CTFontDrawGlyphs(drawFont, glyphs, positions, glyphs.count, context)
        context.restoreGState()
    }

    static func apply(to attributes: inout [NSAttributedString.Key: Any],
                      requested: FontSynthesis, enabled: Bool) {
        guard enabled, !requested.isEmpty,
              let font = attributes[.font] as? TTFont else { return }
        let result = resolve(font: font as CTFont, requested: requested.traits, enabled: true)
        attributes[.font] = result.font as TTFont
        attributes[SwiftTermRequestedFontStylesKey] = requested
        attributes[SwiftTermFontSynthesisKey] = result.synthesis
        attributes[SwiftTermFontSynthesisMatrixKey] = result.synthesis.contains(.italic)
            ? FontSynthesisMatrix(CTFontGetMatrix(font)) : nil
    }

    static func line(for text: NSAttributedString) -> CTLine {
        let initial = CTLineCreateWithAttributedString(text)
        guard let runs = CTLineGetGlyphRuns(initial) as? [CTRun] else { return initial }
        var replacement: NSMutableAttributedString?
        for run in runs {
            let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any] ?? [:]
            guard let requested = attributes[SwiftTermRequestedFontStylesKey] as? FontSynthesis,
                  !requested.isEmpty, let font = attributes[.font] as? TTFont else { continue }
            let previousMatrix = attributes[SwiftTermFontSynthesisMatrixKey] as? FontSynthesisMatrix
            let base: CTFont
            if var matrix = previousMatrix?.value {
                base = CTFontCreateCopyWithAttributes(font as CTFont, 0, &matrix, nil)
            } else {
                base = font as CTFont
            }
            let result = resolve(font: base, requested: requested.traits, enabled: true)
            let originalMatrix = result.synthesis.contains(.italic)
                ? FontSynthesisMatrix(CTFontGetMatrix(base)) : nil
            let previous = attributes[SwiftTermFontSynthesisKey] as? FontSynthesis ?? []
            guard !CFEqual(result.font, font) || result.synthesis != previous
                    || originalMatrix != previousMatrix else { continue }
            if replacement == nil { replacement = NSMutableAttributedString(attributedString: text) }
            let range = CTRunGetStringRange(run)
            let nsRange = NSRange(location: range.location, length: range.length)
            replacement?.addAttributes([.font: result.font as TTFont,
                                        SwiftTermFontSynthesisKey: result.synthesis], range: nsRange)
            if let originalMatrix {
                replacement?.addAttribute(SwiftTermFontSynthesisMatrixKey, value: originalMatrix, range: nsRange)
            } else {
                replacement?.removeAttribute(SwiftTermFontSynthesisMatrixKey, range: nsRange)
            }
        }
        // A different native face has its own glyph IDs, so resolve fallback
        // faces before the final shaping pass rather than swapping draw fonts.
        return replacement.map(CTLineCreateWithAttributedString) ?? initial
    }
}
#endif
#endif
