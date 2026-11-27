import AppKit
import SwiftTerm
import TerminalCore

@MainActor enum TerminalThemeRenderer {
    static func apply(_ application: ThemeApplication, to view: SwiftTerm.TerminalView) {
        let settings = application.settings
        let appearance = (try? settings.appearance.validate()) != nil ? settings.appearance : AppearancePreferences()
        view.nativeBackgroundColor = NSColor(hex: settings.background).withAlphaComponent(appearance.backgroundImagePath == nil ? appearance.opacity : 0)
        view.nativeForegroundColor = NSColor(hex: appearance.foreground)
        view.caretColor = NSColor(hex: appearance.cursor)
        view.caretTextColor = application.cursorText.map { NSColor(hex: $0) }
        view.selectedTextBackgroundColor = NSColor(hex: appearance.selection)
        view.selectedTextForegroundColor = NSColor(hex: application.selectionForeground ?? appearance.foreground)
        view.ansi256PaletteStrategy = application.useExtendedPalette ? .base16Lab : .xterm
        view.installColors(appearance.ansiColors.map { hex in
            let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
            return SwiftTerm.Color(red8: UInt16((value >> 16) & 255), green8: UInt16((value >> 8) & 255), blue8: UInt16(value & 255))
        })
        let overrides = application.paletteOSC()
        if !overrides.isEmpty { view.feed(text: overrides) }
    }
}
