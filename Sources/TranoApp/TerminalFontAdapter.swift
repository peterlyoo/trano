import AppKit
import CoreText
import TerminalCore

struct TerminalVariableFontAxis: Equatable {
    let identifier: Int
    let minimum: Double
    let maximum: Double
    let defaultValue: Double
}

@MainActor
enum TerminalFontAdapter {
    static func font(for preferences: ResolvedTerminalPreferences) throws -> NSFont {
        guard preferences.fontSize.isFinite, (3...256).contains(preferences.fontSize) else {
            throw TerminalError.invalid("Selected font or size is unavailable")
        }
        let selected = preferences.fontName == "system-monospace"
            ? NSFont.monospacedSystemFont(ofSize: preferences.fontSize, weight: .regular)
            : NSFont(name: preferences.fontName, size: preferences.fontSize)
        guard let selected else {
            throw TerminalError.invalid("Selected font or size is unavailable")
        }
        var font = selected
        if let face = preferences.fontStyle {
            guard let selected = NSFont(name: face, size: preferences.fontSize),
                  selected.familyName == font.familyName else {
                throw TerminalError.invalid("Selected face does not belong to the font family")
            }
            font = selected
        }
        if let weight = preferences.fontWeight {
            guard let axis = weightAxis(for: font), weight.isFinite,
                  (axis.minimum...axis.maximum).contains(weight) else {
                throw TerminalError.invalid("Selected font does not support this variable weight")
            }
            let descriptor = font.fontDescriptor.addingAttributes([
                .variation: [NSNumber(value: axis.identifier): NSNumber(value: weight)]
            ])
            guard let weighted = NSFont(descriptor: descriptor, size: preferences.fontSize) else {
                throw TerminalError.invalid("Selected variable font weight is unavailable")
            }
            font = weighted
        }
        let cascade = try preferences.fallbackFonts.map { name -> NSFontDescriptor in
            guard let fallback = NSFont(name: name, size: preferences.fontSize) else {
                throw TerminalError.invalid("Selected fallback font is unavailable")
            }
            return fallback.fontDescriptor
        }
        let descriptor = font.fontDescriptor.addingAttributes([.cascadeList: cascade])
        guard let result = NSFont(descriptor: descriptor, size: preferences.fontSize) else {
            throw TerminalError.invalid("Selected font cascade is unavailable")
        }
        return result
    }

    static func weightAxis(for font: NSFont) -> TerminalVariableFontAxis? {
        guard let axes = CTFontCopyVariationAxes(font as CTFont) as? [[CFString: Any]],
              let axis = axes.first(where: { ($0[kCTFontVariationAxisIdentifierKey] as? NSNumber)?.intValue == 0x77676874 }),
              let minimum = (axis[kCTFontVariationAxisMinimumValueKey] as? NSNumber)?.doubleValue,
              let maximum = (axis[kCTFontVariationAxisMaximumValueKey] as? NSNumber)?.doubleValue,
              let standard = (axis[kCTFontVariationAxisDefaultValueKey] as? NSNumber)?.doubleValue,
              minimum.isFinite, maximum.isFinite, standard.isFinite, minimum < maximum else { return nil }
        return TerminalVariableFontAxis(identifier: 0x77676874, minimum: minimum,
                                        maximum: maximum, defaultValue: standard)
    }

    static func spacingPoints(_ spacing: TerminalCharacterSpacing,
                              cellWidth: CGFloat, backingScale: CGFloat) -> CGFloat {
        guard spacing.value.isFinite, cellWidth.isFinite, cellWidth > 0,
              backingScale.isFinite, backingScale > 0 else { return 0 }
        switch spacing.unit {
        case .pixels: return CGFloat(spacing.value) / backingScale
        case .percent: return cellWidth * CGFloat(spacing.value) / 100
        }
    }

    static func faces(inFamily family: String) -> [String] {
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        return Array(Set(members.prefix(256).compactMap { $0.first as? String })).sorted()
    }
}
