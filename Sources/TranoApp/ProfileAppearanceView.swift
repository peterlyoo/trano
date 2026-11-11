import AppKit
import SwiftUI
import TerminalCore
import UniformTypeIdentifiers

struct ExtendedAppearanceControls: View {
    @Binding var settings: TerminalSettings
    let root: URL
    @State private var importing = false
    @State private var error: String?
    @State private var importGeneration = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Line spacing").frame(width: 110, alignment: .leading)
                Slider(value: $settings.appearance.lineSpacing, in: 1...2, step: 0.05)
                Text(settings.appearance.lineSpacing, format: .number.precision(.fractionLength(2))).monospacedDigit().frame(width: 42)
            }
            HStack {
                Text("Hangul fallback").frame(width: 110, alignment: .leading)
                TextField("System fallback", text: $settings.appearance.fallbackFontName).textFieldStyle(.roundedBorder)
                Menu {
                    Button("System default") { settings.appearance.fallbackFontName = "" }
                    ForEach(["AppleSDGothicNeo-Regular", "AppleGothic", "NanumGothic"].filter { NSFont(name: $0, size: 14) != nil }, id: \.self) { name in
                        Button(name) { settings.appearance.fallbackFontName = name }
                    }
                } label: { Image(systemName: "textformat.abc") }.menuStyle(.borderlessButton).frame(width: 24).help("Choose fallback font")
            }
            HStack {
                Text("Background image").frame(width: 110, alignment: .leading)
                Button(settings.appearance.backgroundImagePath == nil ? "Choose Image…" : "Replace Image…", action: chooseImage).disabled(importing)
                if settings.appearance.backgroundImagePath != nil {
                    Button { settings.appearance.backgroundImagePath = nil } label: { Image(systemName: "xmark") }.help("Remove background image").accessibilityLabel("Remove background image")
                }
                if importing { ProgressView().controlSize(.small) }
            }
            if settings.appearance.backgroundImagePath != nil {
                HStack {
                    Text("Image intensity").frame(width: 110, alignment: .leading)
                    Slider(value: $settings.appearance.backgroundImageOpacity, in: 0...0.4)
                    Text(settings.appearance.backgroundImageOpacity, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 42)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }.onDisappear { importGeneration += 1 }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        importing = true; error = nil
        importGeneration += 1
        let generation = importGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try BackgroundImageStore.importImage(from: source, root: root) }
            DispatchQueue.main.async {
                guard generation == importGeneration else { return }
                importing = false
                switch result {
                case .success(let path): settings.appearance.backgroundImagePath = path
                case .failure(let failure): error = failure.localizedDescription
                }
            }
        }
    }
}

struct ProfileAppearanceView: View {
    @ObservedObject var store: AppStore
    var embedded = false
    var draft: Binding<TerminalSettings>?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var draftID = UUID().uuidString.lowercased()
    @State private var name = "New Profile"
    @State private var settings = TerminalSettings()
    @State private var error: String?

    private var profileSettings: TerminalSettings { draft?.wrappedValue ?? store.state.settings }
    private var nameBinding: Binding<String> {
        Binding(get: { name }, set: { name = $0; stageProfile() })
    }
    private var settingsBinding: Binding<TerminalSettings> {
        Binding(get: { settings }, set: { settings = $0; stageProfile() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !embedded {
                HStack { Text("Appearance profiles").font(.title2.weight(.semibold)); Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 10) {
                    List(selection: $selectedID) {
                        ForEach(profileSettings.appearanceProfiles) { profile in Text(profile.name).tag(profile.id) }
                    }.frame(width: 150)
                    HStack {
                        Button { newProfile(); stageProfile(creating: true) } label: { Image(systemName: "plus") }.help("New profile").accessibilityLabel("New appearance profile")
                        Spacer()
                        Button {
                            guard let id = selectedID else { return }
                            if let draft {
                                var value = draft.wrappedValue
                                SettingsDraft.removeProfile(id, from: &value)
                                draft.wrappedValue = value
                            } else { store.perform { try $0.removeAppearanceProfile(id) } }
                            newProfile()
                        } label: { Image(systemName: "minus") }.disabled(selectedID == nil).help("Delete profile").accessibilityLabel("Delete appearance profile")
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("Profile name", text: nameBinding).textFieldStyle(.roundedBorder)
                        HStack {
                            TextField("Font name", text: settingsBinding.fontName).textFieldStyle(.roundedBorder)
                            Stepper("\(Int(settings.fontSize)) pt", value: settingsBinding.fontSize, in: 9...40).frame(width: 110)
                        }
                        Text("한글 · English · 0123456789\n❯ claude --resume")
                            .font(Font(NSFont(name: settings.fontName, size: settings.fontSize) ?? NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)))
                            .foregroundStyle(Color(NSColor(hex: settings.appearance.foreground)))
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor(hex: settings.background)))
                        HStack {
                            profileColor("Background", settingsBinding.background)
                            profileColor("Text", settingsBinding.appearance.foreground)
                        }
                        HStack {
                            profileColor("Cursor", settingsBinding.appearance.cursor)
                            profileColor("Selection", settingsBinding.appearance.selection)
                        }
                        HStack {
                            Text("Opacity").frame(width: 110, alignment: .leading)
                            Slider(value: settingsBinding.appearance.opacity, in: 0.3...1)
                        }
                        ExtendedAppearanceControls(settings: settingsBinding, root: store.runtime.root).id(draftID)
                        if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                        if !embedded { HStack { Spacer(); Button("Save Profile", action: save) } }
                    }.padding(.trailing, 8)
                }.disabled(embedded && selectedID == nil)
            }
        }.padding(embedded ? 16 : 24)
            .frame(width: embedded ? nil : 720, height: embedded ? nil : 560)
            .preferredColorScheme(.dark)
            .onAppear { newProfile(); if let first = profileSettings.appearanceProfiles.first { selectedID = first.id; load(first.id) } }
            .onChange(of: selectedID) { _, id in if let id { load(id) } }
    }

    private func newProfile() {
        selectedID = nil; draftID = UUID().uuidString.lowercased(); name = "New Profile"
        settings = profileSettings.resolvedAppearance(for: store.focusedID ?? "")
        error = nil
    }

    private func load(_ id: String) {
        guard let profile = profileSettings.appearanceProfiles.first(where: { $0.id == id }) else { return }
        draftID = profile.id; name = profile.name
        settings = profileSettings
        settings.fontName = profile.fontName; settings.fontSize = profile.fontSize
        settings.background = profile.background; settings.appearance = profile.appearance
        error = nil
    }

    private func stageProfile(creating: Bool = false) {
        guard let draft, creating || selectedID != nil else { return }
        var value = draft.wrappedValue
        SettingsDraft.setProfile(AppearanceProfile(id: draftID, name: name, settings: settings), in: &value)
        draft.wrappedValue = value
        if creating { selectedID = draftID }
    }

    private func save() {
        do {
            guard SettingsDraft.font(named: settings.fontName, size: settings.fontSize) != nil,
                  settings.appearance.fallbackFontName.isEmpty || NSFont(name: settings.appearance.fallbackFontName, size: settings.fontSize) != nil else {
                throw TerminalError.invalid("Choose installed font names.")
            }
            let profile = AppearanceProfile(id: draftID, name: name.trimmingCharacters(in: .whitespacesAndNewlines), settings: settings)
            try profile.validate()
            store.perform { try $0.saveAppearanceProfile(profile) }
            selectedID = profile.id; error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func profileColor(_ title: String, _ binding: Binding<String>) -> some View {
        ColorPicker(title, selection: Binding(get: { Color(NSColor(hex: binding.wrappedValue)) }, set: { color in
            guard let native = NSColor(color).usingColorSpace(.sRGB) else { return }
            binding.wrappedValue = String(format: "#%02X%02X%02X", Int((native.redComponent * 255).rounded()), Int((native.greenComponent * 255).rounded()), Int((native.blueComponent * 255).rounded()))
        }), supportsOpacity: false).font(.caption)
    }
}
