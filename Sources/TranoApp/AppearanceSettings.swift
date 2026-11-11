import AppKit
import SwiftUI
import TerminalCore

@MainActor final class SettingsDraft: ObservableObject {
    @Published var settings: TerminalSettings
    @Published var automaticallyChecksForUpdates: Bool
    @Published var automaticallyDownloadsUpdates: Bool
    private var baseline: TerminalSettings
    private var baselineChecks: Bool
    private var baselineDownloads: Bool

    init(settings: TerminalSettings, automaticallyChecksForUpdates: Bool, automaticallyDownloadsUpdates: Bool) {
        self.settings = settings; baseline = settings
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates; baselineChecks = automaticallyChecksForUpdates
        self.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates; baselineDownloads = automaticallyDownloadsUpdates
    }

    func reload(settings: TerminalSettings, automaticallyChecksForUpdates: Bool, automaticallyDownloadsUpdates: Bool) {
        baseline = settings; baselineChecks = automaticallyChecksForUpdates; baselineDownloads = automaticallyDownloadsUpdates
        cancel()
    }

    func cancel() {
        settings = baseline
        automaticallyChecksForUpdates = baselineChecks
        automaticallyDownloadsUpdates = baselineDownloads
    }

    static func setProfile(_ profile: AppearanceProfile, in settings: inout TerminalSettings) {
        if let index = settings.appearanceProfiles.firstIndex(where: { $0.id == profile.id }) { settings.appearanceProfiles[index] = profile }
        else { settings.appearanceProfiles.append(profile) }
    }

    static func removeProfile(_ id: String, from settings: inout TerminalSettings) {
        settings.appearanceProfiles.removeAll { $0.id == id }
        settings.paneAppearanceProfiles = settings.paneAppearanceProfiles.filter { $0.value != id }
    }

    static func font(named name: String, size: Double) -> NSFont? {
        guard size.isFinite, (9...40).contains(size) else { return nil }
        if let font = NSFont(name: name, size: size) { return font }
        guard name == TerminalSettings().fontName else { return nil }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func save(persist: (TerminalSettings, TerminalSettings) throws -> Void, updateChecks: (Bool) -> Void, updateDownloads: (Bool) -> Void) throws {
        guard Self.font(named: settings.fontName, size: settings.fontSize) != nil else { throw TerminalError.invalid("This font is not installed. Enter its PostScript name, such as SFMono-Regular.") }
        guard settings.appearance.fallbackFontName.isEmpty || NSFont(name: settings.appearance.fallbackFontName, size: settings.fontSize) != nil else { throw TerminalError.invalid("The fallback font is not installed.") }
        guard AppearancePreferences.isHexColor(settings.background) else { throw TerminalError.invalid("Background must be a #RRGGBB color.") }
        try settings.appearance.validate(); _ = try KeyBindingMap(overrides: settings.keyBindings)
        try settings.validateAppearanceProfiles()
        for profile in settings.appearanceProfiles {
            guard Self.font(named: profile.fontName, size: profile.fontSize) != nil,
                  profile.appearance.fallbackFontName.isEmpty || NSFont(name: profile.appearance.fallbackFontName, size: profile.fontSize) != nil else {
                throw TerminalError.invalid("Choose installed fonts for profile “\(profile.name)”.")
            }
        }
        try persist(settings, baseline)
        if automaticallyChecksForUpdates != baselineChecks { updateChecks(automaticallyChecksForUpdates) }
        if automaticallyDownloadsUpdates != baselineDownloads { updateDownloads(automaticallyDownloadsUpdates) }
    }
}

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @StateObject private var draft: SettingsDraft
    @State private var query = ""
    @State private var error: String?
    @State private var section = "appearance"
    @ObservedObject private var updater = UpdateController.shared
    init(store: AppStore, initialSection: String = "appearance") {
        self.store = store; _section = State(initialValue: initialSection)
        _draft = StateObject(wrappedValue: SettingsDraft(settings: store.state.settings,
                                                       automaticallyChecksForUpdates: UpdateController.shared.automaticallyChecksForUpdates,
                                                       automaticallyDownloadsUpdates: UpdateController.shared.automaticallyDownloadsUpdates))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings").font(.title2.weight(.semibold))
            TabView(selection: $section) {
                appearance.tabItem { Label("Appearance", systemImage: "paintpalette") }.tag("appearance")
                keyboard.tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag("shortcuts")
                ProfileAppearanceView(store: store, embedded: true, draft: $draft.settings).tabItem { Label("Profiles", systemImage: "rectangle.stack") }.tag("profiles")
                Form {
                    Toggle("Option key sends Meta", isOn: Binding(get: { draft.settings.optionAsMeta ?? false }, set: { draft.settings.optionAsMeta = $0 }))
                    Stepper("Scrollback: \(draft.settings.scrollbackLines.formatted()) lines", value: $draft.settings.scrollbackLines, in: 1000...100_000, step: 1000)
                    Toggle("Completion notifications", isOn: $draft.settings.notifications)
                    Toggle("Restore sessions after restart", isOn: $draft.settings.automaticRestore)
                    Toggle("Save scrollback for recovery", isOn: $draft.settings.persistScrollback)
                    Text("Saves up to 10,000 lines or 4 MiB per pane locally as plain text. Turning this off removes saved copies.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Allow Notifications…", action: store.authorizeNotifications)
                }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }.tag("general")
                Form {
                    Toggle("Automatically check for updates", isOn: $draft.automaticallyChecksForUpdates).disabled(!updater.canCheckForUpdates)
                    Toggle("Download updates automatically", isOn: $draft.automaticallyDownloadsUpdates).disabled(!updater.canCheckForUpdates)
                    Text(updater.status).font(.callout).foregroundStyle(.secondary)
                    Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates)
                }.formStyle(.grouped).tabItem { Label("Updates", systemImage: "arrow.down.circle") }.tag("updates")
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Restore Defaults") { draft.settings = TerminalSettings(); error = nil }
                Spacer()
                Button("Cancel") { draft.cancel(); store.showSettings = false }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 680, height: 570).preferredColorScheme(.dark)
            .onAppear { draft.reload(settings: store.state.settings, automaticallyChecksForUpdates: updater.automaticallyChecksForUpdates, automaticallyDownloadsUpdates: updater.automaticallyDownloadsUpdates) }
    }

    private var appearance: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Theme").frame(width: 100, alignment: .leading)
                    ForEach(TerminalTheme.all) { theme in
                        Button(theme.title) { draft.settings.background = theme.background; draft.settings.appearance = theme.appearance }
                    }
                }
                HStack {
                    Text("Font").frame(width: 100, alignment: .leading)
                    TextField("Font name", text: $draft.settings.fontName).textFieldStyle(.roundedBorder)
                    Menu {
                        ForEach(["SFMono-Regular", "Menlo-Regular", "Monaco"].filter { NSFont(name: $0, size: 14) != nil }, id: \.self) { name in
                            Button(name) { draft.settings.fontName = name }
                        }
                    } label: { Image(systemName: "textformat") }.menuStyle(.borderlessButton).frame(width: 24).help("Choose font")
                    Stepper("\(Int(draft.settings.fontSize)) pt", value: $draft.settings.fontSize, in: 9...40).frame(width: 112)
                }
                Text("Trano  ~/projects\n한글 입력 · English · 0123456789\n❯ claude --resume")
                    .font(Font(NSFont(name: draft.settings.fontName, size: draft.settings.fontSize) ?? NSFont.monospacedSystemFont(ofSize: draft.settings.fontSize, weight: .regular)))
                    .foregroundStyle(Color(NSColor(hex: draft.settings.appearance.foreground)))
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor(hex: draft.settings.background))).clipShape(RoundedRectangle(cornerRadius: 6))
                HStack {
                    colorPicker("Background", $draft.settings.background)
                    colorPicker("Text", $draft.settings.appearance.foreground)
                    colorPicker("Cursor", $draft.settings.appearance.cursor)
                    colorPicker("Selection", $draft.settings.appearance.selection)
                }
                HStack {
                    Text("Opacity").frame(width: 100, alignment: .leading)
                    Slider(value: $draft.settings.appearance.opacity, in: 0.3...1)
                    Text(draft.settings.appearance.opacity, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 42)
                }
                HStack {
                    Picker("Cursor", selection: $draft.settings.appearance.cursorStyle) {
                        ForEach(TerminalCursorStyle.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }.pickerStyle(.segmented)
                    Toggle("Blink", isOn: $draft.settings.appearance.cursorBlink).toggleStyle(.checkbox)
                }
                ExtendedAppearanceControls(settings: $draft.settings, root: store.runtime.root)
                Text("ANSI palette").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(0..<16, id: \.self) { index in
                        ColorPicker("Color \(index)", selection: colorBinding($draft.settings.appearance.ansiColors[index]), supportsOpacity: false)
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
                            KeyboardShortcutRecorder(value: (draft.settings.keyBindings[action.id] ?? action.bindings).first) { shortcut in
                                var proposed = draft.settings.keyBindings; proposed[action.id] = [shortcut]
                                do { _ = try KeyBindingMap(overrides: proposed); draft.settings.keyBindings = proposed; error = nil }
                                catch { self.error = error.localizedDescription }
                            }.frame(width: 142, height: 26)
                            Button { draft.settings.keyBindings[action.id] = []; error = nil } label: { Image(systemName: "xmark") }.help("Remove shortcut").accessibilityLabel("Remove \(action.title) shortcut")
                            Button { draft.settings.keyBindings.removeValue(forKey: action.id); error = nil } label: { Image(systemName: "arrow.counterclockwise") }.help("Restore default").accessibilityLabel("Restore \(action.title) shortcut")
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
            try draft.save(persist: { store.saveSettings($0, from: $1) },
                           updateChecks: { updater.automaticallyChecksForUpdates = $0 },
                           updateDownloads: { updater.automaticallyDownloadsUpdates = $0 })
            store.showSettings = false
        } catch { self.error = error.localizedDescription }
    }
}
