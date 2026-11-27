import AppKit
import SwiftUI
import TerminalCore

struct TerminalSettingsForm: View {
    @Binding var terminalPreferences: TerminalPreferences
    @Binding var legacy: TerminalSettings
    var clearRecentPaths: (() -> Void)? = nil
    @State private var advancedFonts = false
    @State private var allFonts = false
    @State private var fallbackToAdd = "AppleSDGothicNeo-Regular"
    @State private var retainedStartup: TerminalStartupCommand?

    private var resolved: ResolvedTerminalPreferences { terminalPreferences.resolved(legacy: legacy) }
    private var selectedFont: NSFont {
        NSFont(name: terminalPreferences.fontStyle ?? resolved.fontName, size: resolved.fontSize)
            ?? NSFont(name: resolved.fontName, size: resolved.fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: resolved.fontSize, weight: .regular)
    }
    private var fontFamily: String { NSFont(name: resolved.fontName, size: resolved.fontSize)?.familyName ?? selectedFont.familyName ?? "" }
    private var faces: [String] { TerminalFontAdapter.faces(inFamily: fontFamily) }
    private var missingNativeStyles: Bool {
        let manager = NSFontManager.shared
        return !manager.traits(of: manager.convert(selectedFont, toHaveTrait: .boldFontMask)).contains(.boldFontMask)
            || !manager.traits(of: manager.convert(selectedFont, toHaveTrait: .italicFontMask)).contains(.italicFontMask)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                typography
                section("Colors") {
                    number("Improve text contrast", id: "minimumContrastRatio", value: $terminalPreferences.minimumContrastRatio, range: 1...21, unit: ":1")
                    toggle("Force theme palette for text", id: "forceThemePaletteForText", value: $terminalPreferences.forceThemePaletteForText)
                    toggle("Use Display P3 color space", id: "useDisplayP3", value: $terminalPreferences.useDisplayP3)
                }
                cursor
                section("Keyboard & Scrolling") {
                    toggle("Show key sequence hints", id: "showKeySequenceHints", value: $terminalPreferences.showKeySequenceHints)
                    choice("Option key", id: "optionKey", value: optionKey,
                           options: [("meta", "Alt / Meta"), ("specialCharacters", "Special characters")])
                    toggle("Smooth scrolling", id: "smoothScrolling", value: $terminalPreferences.smoothScrolling)
                    toggle("Smooth terminal resizing", id: "smoothResizing", value: $terminalPreferences.smoothResizing)
                    number("Scrollback", id: "scrollbackLines", value: Binding(get: { Double(legacy.scrollbackLines) }, set: { legacy.scrollbackLines = Int($0) }), range: 1000...100000, unit: "lines", integer: true)
                }
                selection
                links
                section("Paths & Titles") {
                    toggle("Show recently used paths", id: "showRecentPaths", value: $terminalPreferences.showRecentPaths)
                    if let clearRecentPaths {
                        TerminalFormButton(title: "Clear Recent Paths", id: "terminal.clearRecentPaths", action: clearRecentPaths)
                            .frame(width: 154, height: 26)
                    }
                    toggle("Prefer generated titles", id: "preferGeneratedTitles", value: $terminalPreferences.preferGeneratedTitles)
                }
                startup
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var typography: some View {
        section("Typography") {
            row("Terminal font") {
                FontChoicePicker(title: "Terminal font", selection: fontName, allFonts: allFonts)
                    .frame(minWidth: 100, maxWidth: .infinity, minHeight: 26)
            }
            toggle("Browse all installed fonts", id: "allFonts", value: $allFonts)
            number("Font size", id: "fontSize", value: fontSize, range: 9...40, unit: "pt")
            choice("Font style", id: "fontStyle", value: Binding(get: { terminalPreferences.fontStyle ?? "" }, set: {
                terminalPreferences.fontStyle = $0.isEmpty ? nil : $0
                terminalPreferences.fontWeight = nil
            }), options: [("", "Default")] + faces.map { ($0, NSFont(name: $0, size: 14)?.displayName ?? $0) })
            if let axis = TerminalFontAdapter.weightAxis(for: selectedFont) {
                row("Font weight") {
                    TerminalFormSlider(id: "terminal.fontWeight", value: Binding(get: { terminalPreferences.fontWeight ?? axis.defaultValue }, set: { terminalPreferences.fontWeight = $0 }), range: axis.minimum...axis.maximum)
                        .frame(minWidth: 90, maxWidth: .infinity, minHeight: 24)
                    Text(terminalPreferences.fontWeight ?? axis.defaultValue, format: .number.precision(.fractionLength(0)))
                        .monospacedDigit().frame(width: 48, alignment: .trailing)
                }
            }
            number("Line height", id: "lineHeight", value: Binding(get: { resolved.lineHeight }, set: { terminalPreferences.lineHeight = $0 }), range: 0.5...3, unit: "×")
            TerminalFormFontPreview(preferences: resolved)
                .frame(maxWidth: .infinity, minHeight: max(54, resolved.fontSize * 2.8), maxHeight: max(54, resolved.fontSize * 2.8))
            TerminalFormButton(title: "Advanced Font Settings", id: "terminal.advancedFonts", state: advancedFonts ? .on : .off, kind: .disclosure) { advancedFonts.toggle() }
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            if advancedFonts {
                VStack(alignment: .leading, spacing: 10) {
                    row("Character spacing") {
                        TerminalFormNumber(id: "terminal.characterSpacing", value: $terminalPreferences.characterSpacing.value,
                                           range: terminalPreferences.characterSpacing.unit == .pixels ? -32...64 : -90...500)
                            .frame(width: 82, height: 24)
                        TerminalFormChoice(id: "terminal.characterSpacingUnit", value: Binding(get: { terminalPreferences.characterSpacing.unit.rawValue }, set: {
                            guard let unit = TerminalCharacterSpacingUnit(rawValue: $0) else { return }
                            let bounds: ClosedRange<Double> = unit == .pixels ? -32...64 : -90...500
                            var spacing = terminalPreferences.characterSpacing
                            spacing.unit = unit
                            spacing.value = min(bounds.upperBound, max(bounds.lowerBound, spacing.value))
                            terminalPreferences.characterSpacing = spacing
                        }), options: [("pixels", "Pixels"), ("percent", "Percent")])
                            .frame(minWidth: 80, maxWidth: .infinity, minHeight: 26)
                    }
                    toggle("Ligatures", id: "ligatures", value: $terminalPreferences.ligatures)
                    choice("Render bold and italic", id: "fontStyles", value: raw($terminalPreferences.fontStyles), options: [("both", "Both"), ("boldOnly", "Bold only"), ("italicOnly", "Italic only"), ("neither", "Neither")])
                    if missingNativeStyles {
                        toggle("Force bold and italic styles", id: "forceFontStyles", value: $terminalPreferences.forceFontStyles)
                    }
                    toggle("Font smoothing", id: "fontSmoothing", value: $terminalPreferences.fontSmoothing)
                    fallbackFonts
                }
            }
        }
    }

    private var fallbackFonts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fallback fonts").font(.callout)
            ForEach(Array(resolved.fallbackFonts.enumerated()), id: \.offset) { index, name in
                HStack(spacing: 6) {
                    Text("\(index + 1). \(NSFont(name: name, size: 14)?.displayName ?? name)")
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    TerminalFormButton(title: "Up", id: "terminal.fallback.\(index).up", enabled: index > 0) {
                        var fonts = resolved.fallbackFonts
                        guard fonts.indices.contains(index), index > 0 else { return }
                        fonts.swapAt(index, index - 1); terminalPreferences.fallbackFonts = fonts
                    }.frame(width: 44, height: 26)
                    TerminalFormButton(title: "Down", id: "terminal.fallback.\(index).down", enabled: index + 1 < resolved.fallbackFonts.count) {
                        var fonts = resolved.fallbackFonts
                        guard fonts.indices.contains(index + 1) else { return }
                        fonts.swapAt(index, index + 1); terminalPreferences.fallbackFonts = fonts
                    }.frame(width: 52, height: 26)
                    TerminalFormButton(title: "Remove", id: "terminal.fallback.\(index).remove") {
                        var fonts = resolved.fallbackFonts
                        guard fonts.indices.contains(index) else { return }
                        fonts.remove(at: index); terminalPreferences.fallbackFonts = fonts
                    }.frame(width: 68, height: 26)
                }
            }
            HStack(spacing: 8) {
                FontChoicePicker(title: "Add fallback font", selection: $fallbackToAdd, allFonts: true)
                    .frame(minWidth: 120, maxWidth: .infinity, minHeight: 26)
                TerminalFormButton(title: "Add Font", id: "terminal.fallback.add", enabled: !fallbackToAdd.isEmpty && !resolved.fallbackFonts.contains(fallbackToAdd) && resolved.fallbackFonts.count < 16) {
                    var fonts = resolved.fallbackFonts
                    guard !fallbackToAdd.isEmpty, !fonts.contains(fallbackToAdd), fonts.count < 16 else { return }
                    fonts.append(fallbackToAdd); terminalPreferences.fallbackFonts = fonts
                }.frame(width: 88, height: 26)
            }
        }
    }

    private var cursor: some View {
        section("Cursor") {
            choice("Blink speed", id: "cursorBlinkSpeed", value: Binding(get: {
                terminalPreferences.cursorBlinkSpeed?.rawValue ?? (legacy.appearance.cursorBlink ? "normal" : "off")
            }, set: { terminalPreferences.cursorBlinkSpeed = TerminalBlinkSpeed(rawValue: $0) }),
                   options: [("off", "Off"), ("slow", "Slow"), ("normal", "Normal"), ("fast", "Fast"), ("custom", "Custom")])
            if terminalPreferences.cursorBlinkSpeed == .custom {
                number("Blink interval", id: "cursorBlinkIntervalMS", value: $terminalPreferences.cursorBlinkIntervalMS, range: 50...10000, unit: "ms")
            }
            choice("Cursor style", id: "cursorStyle", value: Binding(get: { resolved.cursorStyle.rawValue }, set: { terminalPreferences.cursorStyle = TerminalCursorStyle(rawValue: $0) }), options: [("block", "Block"), ("beam", "Bar"), ("underline", "Underline")])
            toggle("Force style", id: "forceCursorStyle", value: $terminalPreferences.forceCursorStyle)
        }
    }

    private var selection: some View {
        section("Selection") {
            toggle("Copy on selection", id: "copyOnSelection", value: $terminalPreferences.copyOnSelection)
            toggle("Play animation on copy", id: "animateCopy", value: $terminalPreferences.animateCopy)
            color("Selection foreground", id: "selectionForeground", value: $terminalPreferences.selectionForeground, inherited: resolved.selectionForeground)
            color("Selection background", id: "selectionBackground", value: $terminalPreferences.selectionBackground, inherited: resolved.selectionBackground)
            number("Rounded corners", id: "selectionCornerRadius", value: $terminalPreferences.selectionCornerRadius, range: 0...32, unit: "pt")
        }
    }

    private var links: some View {
        section("Links") {
            choice("Links that open apps", id: "applicationLinks", value: raw($terminalPreferences.applicationLinks), options: [("ask", "Ask before opening"), ("always", "Always open"), ("never", "Never open")])
            Text("Trusted links").font(.callout)
            if terminalPreferences.trustedLinks.isEmpty {
                Text("No remembered links").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(terminalPreferences.trustedLinks.enumerated()), id: \.offset) { index, rule in
                HStack(spacing: 8) {
                    TerminalFormLabel(text: trustedLabel(rule))
                        .frame(minWidth: 100, maxWidth: .infinity, minHeight: 24)
                    TerminalFormButton(title: "Revoke", id: "terminal.trusted.\(index).revoke") {
                        guard terminalPreferences.trustedLinks.indices.contains(index), terminalPreferences.trustedLinks[index] == rule else { return }
                        terminalPreferences.trustedLinks.remove(at: index)
                    }.frame(width: 72, height: 26)
                }
            }
        }
    }

    private var startup: some View {
        section("Shell") {
            choice("Startup command", id: "startupMode", value: Binding(get: { terminalPreferences.startupCommand == nil ? "login" : "custom" }, set: { mode in
                if mode == "login" {
                    if let command = terminalPreferences.startupCommand {
                        retainedStartup = command
                        terminalPreferences.startupCommand = nil
                    }
                } else if terminalPreferences.startupCommand == nil {
                    terminalPreferences.startupCommand = retainedStartup ?? TerminalStartupCommand(executable: "/bin/zsh", arguments: [])
                }
            }), options: [("login", "Login shell"), ("custom", "Custom executable")])
            if terminalPreferences.startupCommand != nil {
                row("Executable") {
                    TerminalFormText(id: "terminal.executable", value: Binding(get: { terminalPreferences.startupCommand?.executable ?? "" }, set: { terminalPreferences.startupCommand?.executable = $0 }))
                        .frame(minWidth: 100, maxWidth: .infinity, minHeight: 24)
                }
                Text("Arguments").font(.callout)
                ForEach(Array((terminalPreferences.startupCommand?.arguments ?? []).indices), id: \.self) { index in
                    HStack(spacing: 8) {
                        Text("\(index + 1)").monospacedDigit().frame(width: 24, alignment: .trailing)
                        TerminalFormText(id: "terminal.argument.\(index)", value: Binding(get: {
                            guard let command = terminalPreferences.startupCommand, command.arguments.indices.contains(index) else { return "" }
                            return command.arguments[index]
                        }, set: {
                            guard terminalPreferences.startupCommand?.arguments.indices.contains(index) == true else { return }
                            terminalPreferences.startupCommand?.arguments[index] = $0
                        })).frame(minWidth: 80, maxWidth: .infinity, minHeight: 24)
                        TerminalFormButton(title: "Remove", id: "terminal.argument.\(index).remove") {
                            guard terminalPreferences.startupCommand?.arguments.indices.contains(index) == true else { return }
                            terminalPreferences.startupCommand?.arguments.remove(at: index)
                        }.frame(width: 72, height: 26)
                    }
                }
                TerminalFormButton(title: "Add Argument", id: "terminal.argument.add", enabled: (terminalPreferences.startupCommand?.arguments.count ?? 0) < 64) {
                    guard (terminalPreferences.startupCommand?.arguments.count ?? 64) < 64 else { return }
                    terminalPreferences.startupCommand?.arguments.append("")
                }.frame(width: 132, height: 26)
            }
        }
    }

    private var fontName: Binding<String> {
        Binding(get: { resolved.fontName }, set: { name in
            guard !name.isEmpty else { return }
            legacy.fontName = name
            terminalPreferences.fontName = nil
            terminalPreferences.fontStyle = nil
            terminalPreferences.fontWeight = nil
        })
    }
    private var fontSize: Binding<Double> {
        Binding(get: { resolved.fontSize }, set: { legacy.fontSize = $0; terminalPreferences.fontSize = nil })
    }
    private var optionKey: Binding<String> {
        Binding(get: { resolved.optionAsMeta ? "meta" : "specialCharacters" }, set: {
            legacy.optionAsMeta = $0 == "meta"; terminalPreferences.optionKey = nil
        })
    }
    private func raw<T: RawRepresentable>(_ value: Binding<T>) -> Binding<String> where T.RawValue == String {
        Binding(get: { value.wrappedValue.rawValue }, set: { if let selected = T(rawValue: $0) { value.wrappedValue = selected } })
    }
    private func trustedLabel(_ rule: TerminalTrustedLink) -> String {
        rule.scheme + "://" + (rule.host ?? "") + (rule.port.map { ":\($0)" } ?? "")
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 188, alignment: .leading)
            content()
        }.frame(minHeight: 26)
    }
    private func toggle(_ title: String, id: String, value: Binding<Bool>) -> some View {
        TerminalFormButton(title: title, id: "terminal." + id, state: value.wrappedValue ? .on : .off, kind: .toggle) {
            value.wrappedValue.toggle()
        }.frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
    }
    private func choice(_ title: String, id: String, value: Binding<String>, options: [(String, String)]) -> some View {
        row(title) {
            TerminalFormChoice(id: "terminal." + id, value: value, options: options)
                .frame(minWidth: 80, maxWidth: .infinity, minHeight: 26)
        }
    }
    private func number(_ title: String, id: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String, integer: Bool = false) -> some View {
        row(title) {
            TerminalFormNumber(id: "terminal." + id, value: value, range: range, integer: integer).frame(width: 88, height: 24)
            Text(unit).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
    private func color(_ title: String, id: String, value: Binding<String?>, inherited: String) -> some View {
        row(title) {
            TerminalFormColorWell(id: "terminal." + id, value: Binding(get: { value.wrappedValue ?? inherited }, set: { value.wrappedValue = $0 }))
                .frame(width: 48, height: 26)
            TerminalFormButton(title: "Use Theme", id: "terminal." + id + ".reset", enabled: value.wrappedValue != nil) { value.wrappedValue = nil }
                .frame(width: 100, height: 26)
            Spacer(minLength: 0)
        }
    }
}

private struct TerminalFormButton: NSViewRepresentable {
    enum Kind { case push, toggle, disclosure }
    let title: String
    let id: String
    var state: NSControl.StateValue = .off
    var enabled = true
    var kind: Kind = .push
    let action: () -> Void
    func makeNSView(context: Context) -> TerminalOwnedButton {
        let button = TerminalOwnedButton()
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }
    func updateNSView(_ button: TerminalOwnedButton, context: Context) {
        button.title = kind == .disclosure ? (state == .on ? "▾ " : "▸ ") + title : title
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.setAccessibilityLabel(title)
        button.setButtonType(kind == .toggle ? .switch : .momentaryPushIn)
        button.bezelStyle = kind == .disclosure ? .inline : (kind == .push ? .rounded : .regularSquare)
        button.state = state
        button.isEnabled = enabled && context.environment.isEnabled
        button.onAction = action
        button.target = button
        button.action = #selector(TerminalOwnedButton.invoke(_:))
    }
}

private final class TerminalOwnedButton: NSButton {
    var onAction: (() -> Void)?
    @objc func invoke(_ sender: Any?) { onAction?() }
}

private struct TerminalFormChoice: NSViewRepresentable {
    let id: String
    @Binding var value: String
    let options: [(String, String)]
    func makeNSView(context: Context) -> TerminalOwnedChoice {
        let button = TerminalOwnedChoice(frame: .zero, pullsDown: false)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }
    func updateNSView(_ button: TerminalOwnedChoice, context: Context) {
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.setAccessibilityLabel(terminalFormAccessibilityLabel(id))
        if button.itemArray.map({ $0.representedObject as? String }) != options.map({ Optional($0.0) }) {
            button.removeAllItems()
            for (key, title) in options { button.addItem(withTitle: title); button.lastItem?.representedObject = key }
        }
        if let selected = button.itemArray.first(where: { $0.representedObject as? String == value }) { button.select(selected) }
        button.isEnabled = context.environment.isEnabled
        button.onChange = { value = $0 }
        button.target = button
        button.action = #selector(TerminalOwnedChoice.choose(_:))
    }
}

private final class TerminalOwnedChoice: NSPopUpButton {
    var onChange: ((String) -> Void)?
    @objc func choose(_ sender: Any?) { if let value = selectedItem?.representedObject as? String { onChange?(value) } }
}

private struct TerminalFormText: NSViewRepresentable {
    let id: String
    @Binding var value: String
    func makeNSView(context: Context) -> TerminalOwnedText { TerminalOwnedText(frame: .zero) }
    func updateNSView(_ field: TerminalOwnedText, context: Context) {
        field.configure(id: id, value: value, enabled: context.environment.isEnabled) { text in value = text; return text }
    }
}

private struct TerminalFormNumber: NSViewRepresentable {
    let id: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var integer = false
    func makeNSView(context: Context) -> TerminalOwnedText { TerminalOwnedText(frame: .zero) }
    func updateNSView(_ field: TerminalOwnedText, context: Context) {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = integer ? 0 : 3
        func display(_ number: Double) -> String { formatter.string(from: NSNumber(value: number)) ?? String(number) }
        field.configure(id: id, value: display(value), enabled: context.environment.isEnabled) { text in
            guard let number = Double(text), number.isFinite, range.contains(number), !integer || number.rounded() == number else { return display(value) }
            value = number
            return display(number)
        }
        field.setAccessibilityValueDescription("\(range.lowerBound) to \(range.upperBound)")
    }
}

private final class TerminalOwnedText: NSTextField, NSTextFieldDelegate {
    var onEdit: ((String) -> String)?
    func configure(id: String, value: String, enabled: Bool, onEdit: @escaping (String) -> String) {
        identifier = NSUserInterfaceItemIdentifier(id)
        setAccessibilityLabel(terminalFormAccessibilityLabel(id))
        isEnabled = enabled
        isEditable = true
        isSelectable = true
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingMiddle
        bezelStyle = .roundedBezel
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if currentEditor() == nil { stringValue = value }
        self.onEdit = onEdit
        delegate = self
        target = self
        action = #selector(commit(_:))
    }
    @objc func commit(_ sender: Any?) {
        guard (currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if let updated = onEdit?(stringValue) { stringValue = updated }
    }
    func controlTextDidChange(_ obj: Notification) {
        guard (currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        _ = onEdit?(stringValue)
    }
    func controlTextDidEndEditing(_ obj: Notification) { commit(self) }
}

private struct TerminalFormSlider: NSViewRepresentable {
    let id: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    func makeNSView(context: Context) -> TerminalOwnedSlider { TerminalOwnedSlider() }
    func updateNSView(_ slider: TerminalOwnedSlider, context: Context) {
        slider.identifier = NSUserInterfaceItemIdentifier(id)
        slider.setAccessibilityLabel("Font weight")
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.isContinuous = true
        slider.isEnabled = context.environment.isEnabled
        slider.onChange = { value = $0 }
        slider.target = slider
        slider.action = #selector(TerminalOwnedSlider.changed(_:))
    }
}

private final class TerminalOwnedSlider: NSSlider {
    var onChange: ((Double) -> Void)?
    @objc func changed(_ sender: Any?) { onChange?(doubleValue) }
}

private struct TerminalFormColorWell: NSViewRepresentable {
    let id: String
    @Binding var value: String
    func makeNSView(context: Context) -> TerminalOwnedColorWell { TerminalOwnedColorWell() }
    func updateNSView(_ well: TerminalOwnedColorWell, context: Context) {
        well.identifier = NSUserInterfaceItemIdentifier(id)
        well.setAccessibilityLabel(terminalFormAccessibilityLabel(id))
        if let integer = UInt32(value.dropFirst(), radix: 16) {
            well.color = NSColor(srgbRed: CGFloat((integer >> 16) & 255) / 255, green: CGFloat((integer >> 8) & 255) / 255, blue: CGFloat(integer & 255) / 255, alpha: 1)
        }
        well.isEnabled = context.environment.isEnabled
        well.onChange = { color in
            guard let rgb = color.usingColorSpace(.sRGB) else { return }
            value = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
        }
        well.target = well
        well.action = #selector(TerminalOwnedColorWell.changed(_:))
    }
}

private final class TerminalOwnedColorWell: NSColorWell {
    var onChange: ((NSColor) -> Void)?
    @objc func changed(_ sender: Any?) { onChange?(color) }
}

private struct TerminalFormLabel: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.isSelectable = true
        field.lineBreakMode = .byTruncatingMiddle
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) { field.stringValue = text }
}

private struct TerminalFormFontPreview: NSViewRepresentable {
    let preferences: ResolvedTerminalPreferences
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "Aa Bb 0123456789 → !=\n한글 · 日本語 · Symbols")
        field.identifier = NSUserInterfaceItemIdentifier("terminal.fontPreview")
        field.setAccessibilityLabel("Terminal font preview")
        field.isSelectable = true
        field.maximumNumberOfLines = 2
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        field.font = (try? TerminalFontAdapter.font(for: preferences))
            ?? NSFont.monospacedSystemFont(ofSize: preferences.fontSize, weight: .regular)
    }
}

private func terminalFormAccessibilityLabel(_ id: String) -> String {
    let value = id.replacingOccurrences(of: "terminal.", with: "")
    if value.hasPrefix("argument.") { return "Startup argument " + String((Int(value.dropFirst(9)) ?? 0) + 1) }
    return value.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
}
