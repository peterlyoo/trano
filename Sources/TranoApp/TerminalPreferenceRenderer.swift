import AppKit
import CoreText
import SwiftTerm
import TerminalCore

@MainActor
enum TerminalPreferenceRenderer {
    private struct Colors: Equatable {
        let background: String
        let backgroundAlpha: Double
        let foreground: String
        let cursor: String
        let cursorText: String?
        let selectionForeground: String
        let selectionBackground: String
        let palette: [String]
        let extended: Bool
        let indexed: [Int: String]
    }

    private final class Applied: NSObject {
        let colors: Colors
        let resolved: ResolvedTerminalPreferences
        let hostCursorTemplate: CursorStyle?
        init(colors: Colors, resolved: ResolvedTerminalPreferences, hostCursorTemplate: CursorStyle?) {
            self.colors = colors
            self.resolved = resolved
            self.hostCursorTemplate = hostCursorTemplate
        }
    }

    private static let applied = NSMapTable<SwiftTerm.TerminalView, Applied>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    static func apply(_ preferences: TerminalPreferences, legacy: TerminalSettings,
                      themeApplication: ThemeApplication? = nil, profileAssigned: Bool,
                      previousResolved: ResolvedTerminalPreferences? = nil,
                      reduceMotion: Bool, to view: SwiftTerm.TerminalView) throws -> ResolvedTerminalPreferences {
        try preferences.validate()
        try legacy.appearance.validate()
        var resolved = preferences.resolved(legacy: legacy, profileAssigned: profileAssigned)
        guard resolved.fontSize.isFinite, (3...256).contains(resolved.fontSize),
              resolved.lineHeight.isFinite, (0.5...3).contains(resolved.lineHeight),
              !profileAssigned || (9...40).contains(legacy.fontSize) else {
            throw TerminalError.invalid("Invalid resolved profile typography")
        }
        let font = try TerminalFontAdapter.font(for: resolved)
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        guard scale.isFinite, scale > 0 else { throw TerminalError.invalid("Invalid display scale") }
        var character: UniChar = 0x57
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else {
            throw TerminalError.invalid("Selected font cannot measure the terminal grid")
        }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        guard advance.width.isFinite, advance.width >= 0 else { throw TerminalError.invalid("Invalid native font metrics") }
        let baseWidth = max(1, (advance.width * scale).rounded() / scale)
        let spacing = TerminalFontAdapter.spacingPoints(resolved.characterSpacing, cellWidth: baseWidth, backingScale: scale)
        guard spacing.isFinite, (-8192...8192).contains(spacing) else {
            throw TerminalError.invalid("Resolved character spacing exceeds the native grid limit")
        }

        let source = themeApplication?.settings ?? legacy
        try source.appearance.validate()
        guard AppearancePreferences.isHexColor(source.background),
              themeApplication?.cursorText.map(AppearancePreferences.isHexColor) ?? true,
              themeApplication?.selectionForeground.map(AppearancePreferences.isHexColor) ?? true else {
            throw TerminalError.invalid("Invalid theme color")
        }
        let indexed = themeApplication?.indexedColors ?? [:]
        guard indexed.count <= 240, indexed.allSatisfy({ (16...255).contains($0.key) && AppearancePreferences.isHexColor($0.value) }) else {
            throw TerminalError.invalid("Invalid indexed theme palette")
        }
        if profileAssigned || preferences.selectionForeground == nil {
            resolved.selectionForeground = themeApplication?.selectionForeground ?? source.appearance.foreground
        }
        if profileAssigned || preferences.selectionBackground == nil {
            resolved.selectionBackground = source.appearance.selection
        }
        let colors = Colors(background: source.background.lowercased(),
            backgroundAlpha: source.appearance.backgroundImagePath == nil ? source.appearance.opacity : 0,
            foreground: source.appearance.foreground.lowercased(), cursor: source.appearance.cursor.lowercased(),
            cursorText: themeApplication?.cursorText?.lowercased(),
            selectionForeground: resolved.selectionForeground.lowercased(), selectionBackground: resolved.selectionBackground.lowercased(),
            palette: source.appearance.ansiColors.map { $0.lowercased() },
            extended: themeApplication?.useExtendedPalette ?? false,
            indexed: (themeApplication?.useExtendedPalette ?? false) ? indexed.mapValues { $0.lowercased() } : [:])
        let state = applied.object(forKey: view)
        let previous = previousResolved ?? state?.resolved
        let oldColors = state?.colors
        let allowedBlink = !reduceMotion && (profileAssigned || preferences.cursorBlinkSpeed != .off)
        let template = cursorStyle(resolved.cursorStyle, blinking: resolved.cursorBlinkInterval != nil && !reduceMotion)
        let interval = resolved.cursorBlinkInterval ?? 0.7
        let oldTemplate = state?.hostCursorTemplate ?? previous.map { cursorStyle($0.cursorStyle, blinking: $0.cursorBlinkInterval != nil) }
        var nextHostTemplate = state?.hostCursorTemplate
        let changedShape = previous?.cursorStyle != resolved.cursorStyle
        let changedCursorTiming = previous?.cursorBlinkInterval != resolved.cursorBlinkInterval
            || oldTemplate?.tagName != template.tagName
        let shouldSetParserStyle = !resolved.forceCursorStyle &&
            (previous == nil || changedShape ||
             (previous?.forceCursorStyle == false && changedCursorTiming &&
              view.terminalStateSnapshot().cursorStyle.tagName == oldTemplate?.tagName))

        // Every throwing operation above completes before a native setter or parser mutation.
        let styles: SwiftTerm.TerminalView.TextStyleOptions
        switch resolved.fontStyles {
        case .both: styles = .all
        case .boldOnly: styles = .bold
        case .italicOnly: styles = .italic
        case .neither: styles = []
        }
        if view.textStyleOptions != styles { view.textStyleOptions = styles }
        view.updateTypography(font: font, lineSpacing: CGFloat(resolved.lineHeight))
        if view.characterSpacing != spacing { view.characterSpacing = spacing }
        if view.ligaturesEnabled != resolved.ligatures { view.ligaturesEnabled = resolved.ligatures }
        if view.forceFontStyles != resolved.forceFontStyles { view.forceFontStyles = resolved.forceFontStyles }
        if view.fontSmoothing != resolved.fontSmoothing {
            view.fontSmoothing = resolved.fontSmoothing
            view.needsDisplay = true
            view.requestRedraw()
        }
        if view.minimumContrastRatio != CGFloat(resolved.minimumContrastRatio) { view.minimumContrastRatio = CGFloat(resolved.minimumContrastRatio) }
        if view.forceThemePaletteForText != resolved.forceThemePaletteForText { view.forceThemePaletteForText = resolved.forceThemePaletteForText }
        if view.useDisplayP3 != resolved.useDisplayP3 { view.useDisplayP3 = resolved.useDisplayP3 }
        if view.optionAsMetaKey != resolved.optionAsMeta { view.optionAsMetaKey = resolved.optionAsMeta }
        if view.smoothScrolling != resolved.smoothScrolling { view.smoothScrolling = resolved.smoothScrolling }
        if view.smoothResizing != resolved.smoothResizing { view.smoothResizing = resolved.smoothResizing }
        if view.selectionCornerRadius != CGFloat(resolved.selectionCornerRadius) { view.selectionCornerRadius = CGFloat(resolved.selectionCornerRadius) }
        if view.cursorBlinkingEnabled != allowedBlink { view.cursorBlinkingEnabled = allowedBlink }
        if view.cursorBlinkInterval != interval { view.cursorBlinkInterval = interval }
        let forced = resolved.forceCursorStyle ? template : nil
        if view.forcedCursorStyle?.tagName != forced?.tagName { view.forcedCursorStyle = forced }
        if shouldSetParserStyle {
            view.setCursorStyle(template)
            nextHostTemplate = template
        }
        if oldColors?.background != colors.background || oldColors?.backgroundAlpha != colors.backgroundAlpha {
            view.nativeBackgroundColor = NSColor(hex: colors.background).withAlphaComponent(CGFloat(colors.backgroundAlpha))
        }
        if oldColors?.foreground != colors.foreground { view.nativeForegroundColor = NSColor(hex: colors.foreground) }
        if oldColors?.cursor != colors.cursor { view.caretColor = NSColor(hex: colors.cursor) }
        if oldColors == nil || oldColors?.cursorText != colors.cursorText { view.caretTextColor = colors.cursorText.map { NSColor(hex: $0) } }
        if oldColors?.selectionForeground != colors.selectionForeground { view.selectedTextForegroundColor = NSColor(hex: colors.selectionForeground) }
        if oldColors?.selectionBackground != colors.selectionBackground { view.selectedTextBackgroundColor = NSColor(hex: colors.selectionBackground) }
        if oldColors?.palette != colors.palette || oldColors?.extended != colors.extended || oldColors?.indexed != colors.indexed {
            view.ansi256PaletteStrategy = colors.extended ? .base16Lab : .xterm
            view.installColors(colors.palette.map { hex in
                let value = UInt32(hex.dropFirst(), radix: 16)!
                return SwiftTerm.Color(red8: UInt16((value >> 16) & 255), green8: UInt16((value >> 8) & 255), blue8: UInt16(value & 255))
            })
            if !colors.indexed.isEmpty {
                let entries = colors.indexed.keys.sorted().map { "\($0);\(colors.indexed[$0]!)" }.joined(separator: ";")
                view.feed(text: "\u{1b}]4;" + entries + "\u{1b}\\")
            }
        }
        applied.setObject(Applied(colors: colors, resolved: resolved, hostCursorTemplate: nextHostTemplate), forKey: view)
        return resolved
    }

    private static func cursorStyle(_ shape: TerminalCursorStyle, blinking: Bool) -> CursorStyle {
        switch shape {
        case .block: return blinking ? .blinkBlock : .steadyBlock
        case .beam: return blinking ? .blinkBar : .steadyBar
        case .underline: return blinking ? .blinkUnderline : .steadyUnderline
        }
    }
}
