import AppKit
import SwiftUI
import TerminalCore

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @State private var settings = TerminalSettings()
    @State private var baseline = TerminalSettings()
    @State private var query = ""
    @State private var error: String?
    @State private var section = "appearance"
    @ObservedObject private var updater = UpdateController.shared
    init(store: AppStore, initialSection: String = "appearance") {
        self.store = store; _section = State(initialValue: initialSection)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings").font(.title2.weight(.semibold))
            TabView(selection: $section) {
                appearance.tabItem { Label("Appearance", systemImage: "paintpalette") }.tag("appearance")
                keyboard.tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag("shortcuts")
                ProfileAppearanceView(store: store, embedded: true).tabItem { Label("Profiles", systemImage: "rectangle.stack") }.tag("profiles")
                Form {
                    Toggle("Option key sends Meta", isOn: Binding(get: { settings.optionAsMeta ?? false }, set: { settings.optionAsMeta = $0 }))
                    Stepper("Scrollback: \(settings.scrollbackLines.formatted()) lines", value: $settings.scrollbackLines, in: 1000...100_000, step: 1000)
                    Toggle("Completion notifications", isOn: $settings.notifications)
                    Toggle("Restore sessions after restart", isOn: $settings.automaticRestore)
                    Toggle("Save scrollback for recovery", isOn: $settings.persistScrollback)
                    Text("Saves up to 10,000 lines or 4 MiB per pane locally as plain text. Turning this off removes saved copies.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Allow Notifications…", action: store.authorizeNotifications)
                }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }.tag("general")
                Form {
                    Toggle("Automatically check for updates", isOn: Binding(get: { updater.automaticallyChecksForUpdates }, set: { updater.automaticallyChecksForUpdates = $0 })).disabled(!updater.canCheckForUpdates)
                    Toggle("Download updates automatically", isOn: Binding(get: { updater.automaticallyDownloadsUpdates }, set: { updater.automaticallyDownloadsUpdates = $0 })).disabled(!updater.canCheckForUpdates)
                    Text(updater.status).font(.callout).foregroundStyle(.secondary)
                    Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates)
                }.formStyle(.grouped).tabItem { Label("Updates", systemImage: "arrow.down.circle") }.tag("updates")
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Restore Defaults") { settings = TerminalSettings(); error = nil }
                Spacer()
                Button("Cancel") { store.showSettings = false }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 680, height: 570).preferredColorScheme(.dark)
            .onAppear { settings = store.state.settings; baseline = settings }
    }

    private var appearance: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Theme").frame(width: 100, alignment: .leading)
                    ForEach(TerminalTheme.all) { theme in
                        Button(theme.title) { settings.background = theme.background; settings.appearance = theme.appearance }
                    }
                }
                HStack {
                    Text("Font").frame(width: 100, alignment: .leading)
                    TextField("Font name", text: $settings.fontName).textFieldStyle(.roundedBorder)
                    Menu {
                        ForEach(["SFMono-Regular", "Menlo-Regular", "Monaco"].filter { NSFont(name: $0, size: 14) != nil }, id: \.self) { name in
                            Button(name) { settings.fontName = name }
                        }
                    } label: { Image(systemName: "textformat") }.menuStyle(.borderlessButton).frame(width: 24).help("Choose font")
                    Stepper("\(Int(settings.fontSize)) pt", value: $settings.fontSize, in: 9...40).frame(width: 112)
                }
                Text("Trano  ~/projects\n한글 입력 · English · 0123456789\n❯ claude --resume")
                    .font(Font(NSFont(name: settings.fontName, size: settings.fontSize) ?? NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)))
                    .foregroundStyle(Color(NSColor(hex: settings.appearance.foreground)))
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor(hex: settings.background))).clipShape(RoundedRectangle(cornerRadius: 6))
                HStack {
                    colorPicker("Background", $settings.background)
                    colorPicker("Text", $settings.appearance.foreground)
                    colorPicker("Cursor", $settings.appearance.cursor)
                    colorPicker("Selection", $settings.appearance.selection)
                }
                HStack {
                    Text("Opacity").frame(width: 100, alignment: .leading)
                    Slider(value: $settings.appearance.opacity, in: 0.3...1)
                    Text(settings.appearance.opacity, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 42)
                }
                HStack {
                    Picker("Cursor", selection: $settings.appearance.cursorStyle) {
                        ForEach(TerminalCursorStyle.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }.pickerStyle(.segmented)
                    Toggle("Blink", isOn: $settings.appearance.cursorBlink).toggleStyle(.checkbox)
                }
                ExtendedAppearanceControls(settings: $settings, root: store.runtime.root)
                Text("ANSI palette").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(0..<16, id: \.self) { index in
                        ColorPicker("Color \(index)", selection: colorBinding($settings.appearance.ansiColors[index]), supportsOpacity: false)
                            .labelsHidden().help("ANSI color \(index)")
                    }
                }
            }.padding(18)
        }
    }

    private var keyboard: some View {
        VStack(spacing: 12) {
            TextField("Search shortcuts…", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(ActionCatalog.all.filter { query.isEmpty || ($0.title + " " + $0.category).localizedCaseInsensitiveContains(query) }) { action in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) { Text(action.title).font(.callout); Text(action.category).font(.caption2).foregroundStyle(.secondary) }
                            Spacer()
                            KeyboardShortcutRecorder(value: (settings.keyBindings[action.id] ?? action.bindings).first) { shortcut in
                                var proposed = settings.keyBindings; proposed[action.id] = [shortcut]
                                do { _ = try KeyBindingMap(overrides: proposed); settings.keyBindings = proposed; error = nil }
                                catch { self.error = error.localizedDescription }
                            }.frame(width: 142, height: 26)
                            Button { settings.keyBindings[action.id] = []; error = nil } label: { Image(systemName: "xmark") }.help("Remove shortcut").accessibilityLabel("Remove \(action.title) shortcut")
                            Button { settings.keyBindings.removeValue(forKey: action.id); error = nil } label: { Image(systemName: "arrow.counterclockwise") }.help("Restore default").accessibilityLabel("Restore \(action.title) shortcut")
                        }.padding(.vertical, 9)
                        Divider()
                    }
                }
            }
        }.padding(18)
    }

    private func colorPicker(_ title: String, _ value: Binding<String>) -> some View {
        ColorPicker(title, selection: colorBinding(value), supportsOpacity: false).font(.caption)
    }
    private func colorBinding(_ value: Binding<String>) -> Binding<Color> {
        Binding(get: { Color(NSColor(hex: value.wrappedValue)) }, set: { color in
            guard let native = NSColor(color).usingColorSpace(.sRGB) else { return }
            value.wrappedValue = String(format: "#%02X%02X%02X", Int((native.redComponent * 255).rounded()), Int((native.greenComponent * 255).rounded()), Int((native.blueComponent * 255).rounded()))
        })
    }
    private func save() {
        do {
            guard NSFont(name: settings.fontName, size: settings.fontSize) != nil else { throw TerminalError.invalid("This font is not installed. Enter its PostScript name, such as SFMono-Regular.") }
            guard settings.appearance.fallbackFontName.isEmpty || NSFont(name: settings.appearance.fallbackFontName, size: settings.fontSize) != nil else { throw TerminalError.invalid("The fallback font is not installed.") }
            guard AppearancePreferences.isHexColor(settings.background) else { throw TerminalError.invalid("Background must be a #RRGGBB color.") }
            try settings.appearance.validate(); _ = try KeyBindingMap(overrides: settings.keyBindings)
            store.saveSettings(settings, from: baseline); store.showSettings = false
        } catch { self.error = error.localizedDescription }
    }
}
