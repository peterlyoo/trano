import AppKit
import SwiftUI
import TerminalCore

struct InstalledFontChoice: Identifiable, Equatable {
    let id: String
    let label: String
}

@MainActor final class InstalledFontCatalog {
    static let shared = InstalledFontCatalog()
    let monospaced: [InstalledFontChoice]
    let all: [InstalledFontChoice]

    init() {
        var fonts: [String: InstalledFontChoice] = [:]
        var fixed: [String: InstalledFontChoice] = [:]
        for name in Set(NSFontManager.shared.availableFonts) where !name.hasPrefix(".") {
            guard let font = NSFont(name: name, size: 14) else { continue }
            let choice = InstalledFontChoice(id: font.fontName, label: font.displayName ?? font.familyName ?? font.fontName)
            fonts[choice.id] = choice
            if font.isFixedPitch { fixed[choice.id] = choice }
        }
        all = fonts.values.sorted(by: Self.ordered)
        monospaced = fixed.values.sorted(by: Self.ordered)
    }

    func choices(monospacedOnly: Bool, selected: String) -> [InstalledFontChoice] {
        let choices = monospacedOnly ? monospaced : all
        guard !selected.isEmpty, !choices.contains(where: { $0.id == selected }) else { return choices }
        let font = NSFont(name: selected, size: 14)
        let label = font?.displayName ?? (selected == "SFMono-Regular" ? "System Monospaced" : selected + " (Unavailable)")
        return [InstalledFontChoice(id: selected, label: label)] + choices
    }

    static func previewFont(_ settings: TerminalSettings) -> NSFont {
        let font = SettingsDraft.font(named: settings.fontName, size: settings.fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
        guard !settings.appearance.fallbackFontName.isEmpty,
              let fallback = NSFont(name: settings.appearance.fallbackFontName, size: settings.fontSize) else { return font }
        return NSFont(descriptor: font.fontDescriptor.addingAttributes([.cascadeList: [fallback.fontDescriptor]]), size: settings.fontSize) ?? font
    }

    private static func ordered(_ first: InstalledFontChoice, _ second: InstalledFontChoice) -> Bool {
        if first.id == "Menlo-Regular" { return second.id != first.id }
        if second.id == "Menlo-Regular" { return false }
        let comparison = first.label.localizedStandardCompare(second.label)
        return comparison == .orderedSame ? first.id < second.id : comparison == .orderedAscending
    }
}

struct FontChoicePicker: View {
    let title: String
    @Binding var selection: String
    var fallback = false

    var body: some View {
        Picker(title, selection: $selection) {
            if fallback { Text("Automatic").tag("") }
            else if selection.isEmpty { Text("Choose Font").tag("") }
            ForEach(InstalledFontCatalog.shared.choices(monospacedOnly: !fallback, selected: selection)) { choice in
                Text(choice.id == "Menlo-Regular" && !fallback ? choice.label + " · Default" : choice.label).tag(choice.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel(title)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
