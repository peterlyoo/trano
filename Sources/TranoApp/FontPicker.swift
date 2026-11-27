import AppKit
import SwiftUI
import TerminalCore

struct InstalledFontChoice: Identifiable, Equatable {
    let id: String
    let label: String
}

@MainActor final class InstalledFontCatalog {
    static let shared = InstalledFontCatalog()
    static let systemMonospacedChoice = InstalledFontChoice(id: "system-monospace", label: "System Monospaced (macOS)")
    private(set) var monospaced: [InstalledFontChoice] = []
    private(set) var all: [InstalledFontChoice] = []
    private(set) var revision = 0
    private let availableFontNames: () -> [String]
    private let resolveFont: (String) -> NSFont?
    private var installedNames: Set<String>?

    init(availableFontNames: @escaping () -> [String] = { NSFontManager.shared.availableFonts },
         resolveFont: @escaping (String) -> NSFont? = { NSFont(name: $0, size: 14) }) {
        self.availableFontNames = availableFontNames
        self.resolveFont = resolveFont
        refreshIfNeeded()
    }

    func refreshIfNeeded() {
        let names = Set(availableFontNames())
        guard names != installedNames else { return }
        installedNames = names
        var fonts: [String: InstalledFontChoice] = [:]
        var fixed: [String: InstalledFontChoice] = [:]
        for name in names where !name.hasPrefix(".") {
            guard let font = resolveFont(name) else { continue }
            let choice = InstalledFontChoice(id: font.fontName, label: font.displayName ?? font.familyName ?? font.fontName)
            fonts[choice.id] = choice
            if font.isFixedPitch { fixed[choice.id] = choice }
        }
        all = fonts.values.sorted(by: Self.ordered)
        monospaced = fixed.values.sorted(by: Self.ordered)
        revision += 1
    }

    func choices(monospacedOnly: Bool, selected: String, includeSystemMonospaced: Bool = false) -> [InstalledFontChoice] {
        var choices = monospacedOnly ? monospaced : all
        if includeSystemMonospaced {
            choices.removeAll { $0.id == Self.systemMonospacedChoice.id }
            choices.append(Self.systemMonospacedChoice)
            choices.sort(by: Self.ordered)
        }
        guard !selected.isEmpty, !choices.contains(where: { $0.id == selected }) else { return choices }
        let font = NSFont(name: selected, size: 14)
        let label = selected == Self.systemMonospacedChoice.id ? Self.systemMonospacedChoice.label
            : font?.displayName ?? (selected == "SFMono-Regular" ? "System Monospaced" : selected + " (Unavailable)")
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
    var allFonts = false

    var body: some View {
        NativeFontChoicePicker(title: title, selection: $selection, fallback: fallback, allFonts: allFonts)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NativeFontChoicePicker: NSViewRepresentable {
    let title: String
    @Binding var selection: String
    let fallback: Bool
    var allFonts = false

    func makeNSView(context: Context) -> FontChoicePopUpButton {
        let button = FontChoicePopUpButton(frame: .zero, pullsDown: false)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: FontChoicePopUpButton, context: Context) {
        button.setAccessibilityLabel(title)
        button.appearance = context.environment.toolPanelTheme.appearance
        button.font = .systemFont(ofSize: ToolPanelMetrics.bodySize)
        button.controlSize = .small
        button.isEnabled = context.environment.isEnabled
        button.configure(selection: selection, fallback: fallback, allFonts: allFonts) { self.selection = $0 }
    }

    static func dismantleNSView(_ button: FontChoicePopUpButton, coordinator: ()) {
        button.onChange = nil
        button.menu?.delegate = nil
    }
}

@MainActor final class FontChoicePopUpButton: NSPopUpButton, NSMenuDelegate {
    var onChange: ((String) -> Void)?
    var fontCatalog: InstalledFontCatalog?
    private var value: String?
    private var fallback = false
    private var allFonts = false
    private var loadedRevision: Int?

    func configure(selection: String, fallback: Bool, allFonts: Bool = false, onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        let changedMode = self.fallback != fallback || self.allFonts != allFonts
        let changedSelection = value != selection
        self.fallback = fallback
        self.allFonts = allFonts
        value = selection
        if menu == nil { menu = NSMenu() }
        menu?.delegate = self
        menu?.autoenablesItems = false
        if changedMode { loadedRevision = nil }
        guard changedMode || changedSelection || numberOfItems == 0 else { return }
        if loadedRevision == nil {
            removeAllItems()
            if fallback { append(id: "", label: "Automatic") }
        }
        selectModelValue()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let catalog = fontCatalog ?? InstalledFontCatalog.shared
        catalog.refreshIfNeeded()
        guard loadedRevision != catalog.revision else { return }
        loadedRevision = catalog.revision
        let choices = catalog.choices(monospacedOnly: !fallback && !allFonts, selected: value ?? "", includeSystemMonospaced: !fallback)
        menu.removeAllItems()
        if fallback { append(id: "", label: "Automatic") }
        for choice in choices { append(id: choice.id, label: displayLabel(choice)) }
        selectModelValue()
    }

    private func selectModelValue() {
        guard let value else { return }
        if let index = itemArray.firstIndex(where: { $0.representedObject as? String == value }) {
            selectItem(at: index)
            return
        }
        if value.isEmpty { append(id: value, label: fallback ? "Automatic" : "Choose Font") }
        else {
            let font = NSFont(name: value, size: 14)
            let label = value == InstalledFontCatalog.systemMonospacedChoice.id ? InstalledFontCatalog.systemMonospacedChoice.label
                : font?.displayName ?? (value == "SFMono-Regular" ? "System Monospaced" : value + " (Unavailable)")
            append(id: value, label: displayLabel(InstalledFontChoice(id: value, label: label)))
        }
        selectItem(at: numberOfItems - 1)
    }

    private func displayLabel(_ choice: InstalledFontChoice) -> String {
        choice.id == "Menlo-Regular" && !fallback ? choice.label + " · Default" : choice.label
    }

    private func append(id: String, label: String) {
        let item = NSMenuItem(title: label, action: #selector(choose(_:)), keyEquivalent: "")
        item.representedObject = id
        item.target = self
        menu?.addItem(item)
    }

    @objc private func choose(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String else { return }
        self.value = value
        if let index = itemArray.firstIndex(where: { $0 === item }) { selectItem(at: index) }
        onChange?(value)
    }
}
