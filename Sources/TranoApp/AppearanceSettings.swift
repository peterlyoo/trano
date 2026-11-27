import AppKit
import SwiftUI
import TerminalCore

@MainActor final class SettingsDraft: ObservableObject {
    @Published var settings: TerminalSettings
    @Published var themePreferences: ThemePreferences
    private(set) var baselineThemes: ThemePreferences
    @Published var notificationPreferences: NotificationPreferences
    private(set) var baselineNotificationPreferences: NotificationPreferences
    @Published var automaticallyChecksForUpdates: Bool
    @Published var automaticallyDownloadsUpdates: Bool
    private var baseline: TerminalSettings
    private var baselineChecks: Bool
    private var baselineDownloads: Bool

    init(settings: TerminalSettings, automaticallyChecksForUpdates: Bool, automaticallyDownloadsUpdates: Bool, notificationPreferences: NotificationPreferences = NotificationPreferences(), themePreferences: ThemePreferences = ThemePreferences()) {
        self.settings = settings; baseline = settings
        self.themePreferences = themePreferences; baselineThemes = themePreferences
        self.notificationPreferences = notificationPreferences; baselineNotificationPreferences = notificationPreferences
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates; baselineChecks = automaticallyChecksForUpdates
        self.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates; baselineDownloads = automaticallyDownloadsUpdates
    }

    func reload(settings: TerminalSettings, automaticallyChecksForUpdates: Bool, automaticallyDownloadsUpdates: Bool, notificationPreferences: NotificationPreferences? = nil, themePreferences: ThemePreferences? = nil) {
        if let themePreferences { baselineThemes = themePreferences }
        baseline = settings; baselineChecks = automaticallyChecksForUpdates; baselineDownloads = automaticallyDownloadsUpdates
        if let notificationPreferences { baselineNotificationPreferences = notificationPreferences }
        cancel()
    }

    func cancel() {
        settings = baseline; themePreferences = baselineThemes
        notificationPreferences = baselineNotificationPreferences
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
        if name == "system-monospace" { return NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }
        if let font = NSFont(name: name, size: size) { return font }
        guard name == TerminalSettings().fontName || name == "SFMono-Regular" else { return nil }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func validate() throws {
        try themePreferences.validate()
        guard Self.font(named: settings.fontName, size: settings.fontSize) != nil else { throw TerminalError.invalid("Choose an installed font.") }
        guard settings.appearance.fallbackFontName.isEmpty || NSFont(name: settings.appearance.fallbackFontName, size: settings.fontSize) != nil else { throw TerminalError.invalid("The fallback font is not installed.") }
        guard AppearancePreferences.isHexColor(settings.background) else { throw TerminalError.invalid("Background must be a #RRGGBB color.") }
        try settings.appearance.validate(); _ = try TerminalKeySequenceMap(overrides: settings.keyBindings)
        try settings.validateAppearanceProfiles()
        for profile in settings.appearanceProfiles {
            guard Self.font(named: profile.fontName, size: profile.fontSize) != nil,
                  profile.appearance.fallbackFontName.isEmpty || NSFont(name: profile.appearance.fallbackFontName, size: profile.fontSize) != nil else {
                throw TerminalError.invalid("Choose installed fonts for profile “\(profile.name)”.")
            }
        }
        try notificationPreferences.validate()
    }

    func save(persist: (TerminalSettings, TerminalSettings) throws -> Void, updateChecks: (Bool) -> Void, updateDownloads: (Bool) -> Void, persistNotifications: (NotificationPreferences, NotificationPreferences) throws -> Void = { _, _ in }) throws {
        try validate()
        try persistNotifications(notificationPreferences, baselineNotificationPreferences)
        try persist(settings, baseline)
        if automaticallyChecksForUpdates != baselineChecks { updateChecks(automaticallyChecksForUpdates) }
        if automaticallyDownloadsUpdates != baselineDownloads { updateDownloads(automaticallyDownloadsUpdates) }
    }
}

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @StateObject private var draft: SettingsDraft
    @State private var query = ""
    @State private var shortcutSteps = 1
    @StateObject private var extended: ExtendedSettingsDraft
    @StateObject private var saveCoordinator = SettingsSaveCoordinator()
    @StateObject private var serverConnection: SettingsServerConnection
    @StateObject private var installationController = DeveloperInstallationController()
    private var saving: Bool { saveCoordinator.isSaving }
    @State private var error: String?
    @State private var section = "appearance"
    @State private var interfaceDraft = InterfacePreferences()
    @State private var interfaceBaseline = InterfacePreferences()
    @State private var opacityPreviewOwner = UUID()
    @ObservedObject private var updater = UpdateController.shared
    init(store: AppStore, initialSection: String = "appearance", serverConnection: SettingsServerConnection? = nil, settingsDraft: SettingsDraft? = nil) {
        self.store = store; _section = State(initialValue: initialSection)
        _extended = StateObject(wrappedValue: ExtendedSettingsDraft(terminal: store.terminalPreferences,
            server: store.serverPreferences, integrations: store.integrationsPreferences, developer: store.developerPreferences))
        let runtime = store.runtime
        _serverConnection = StateObject(wrappedValue: serverConnection ?? SettingsServerConnection(makeBackend: {
            try LiveServerSettingsBackend(runtime: runtime)
        }))
        _draft = StateObject(wrappedValue: settingsDraft ?? SettingsDraft(settings: store.state.settings,
                                                       automaticallyChecksForUpdates: UpdateController.shared.automaticallyChecksForUpdates,
                                                       automaticallyDownloadsUpdates: UpdateController.shared.automaticallyDownloadsUpdates,
                                                       notificationPreferences: store.notificationPreferences, themePreferences: store.themePreferences))
    }
    var body: some View {
        VStack(spacing: 0) {
            ToolPanelHeader("Settings", canClose: !saving, closeLabel: "Cancel", onClose: cancelSettings)
            VStack(alignment: .leading, spacing: ToolPanelMetrics.sectionSpacing) {
                HStack(spacing: 0) {
                    SettingsNavigationSidebar(selection: $section)
                        .frame(width: 148)
                    Divider()
                    settingsContent.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .disabled(saving)
                .allowsHitTesting(!saving)
                if let error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Button("Restore Defaults") {
                        draft.settings = TerminalSettings(); draft.notificationPreferences = NotificationPreferences()
                        draft.themePreferences = ThemePreferences(); interfaceDraft = InterfacePreferences()
                        extended.terminal = TerminalPreferences(); extended.server = ServerPreferences()
                        extended.integrations = IntegrationsPreferences(); extended.developer = DeveloperPreferences(); error = nil
                    }.disabled(saving)
                    Spacer()
                    Button("Cancel", action: cancelSettings).keyboardShortcut(.cancelAction).disabled(saving)
                    Button(saving ? "Saving…" : "Save") { save() }.keyboardShortcut(.defaultAction).disabled(saving || serverConnection.controller?.busy == true)
                }
            }.padding(ToolPanelMetrics.contentInset)
        }.frame(width: 880, height: 630).toolPanelSurface(store.toolPanelTheme)
            .dismissOnOutsideClick("settings-sheet", canDismiss: { !saving }, perform: cancelSettings)
            .onAppear {
                interfaceDraft = store.interfacePreferences; interfaceBaseline = interfaceDraft
                extended.reload(terminal: store.terminalPreferences, server: store.serverPreferences,
                    integrations: store.integrationsPreferences, developer: store.developerPreferences)
                draft.reload(settings: store.state.settings, automaticallyChecksForUpdates: updater.automaticallyChecksForUpdates,
                    automaticallyDownloadsUpdates: updater.automaticallyDownloadsUpdates,
                    notificationPreferences: store.notificationPreferences, themePreferences: store.themePreferences)
                store.beginWindowOpacityPreview(owner: opacityPreviewOwner, opacity: draft.settings.appearance.opacity)
            }
            .onChange(of: draft.settings.appearance.opacity) { _, value in
                store.updateWindowOpacityPreview(owner: opacityPreviewOwner, opacity: value)
            }
            .onDisappear { store.endWindowOpacityPreview(owner: opacityPreviewOwner) }
    }

    private func cancelSettings() {
        guard !saving else { return }
        store.endWindowOpacityPreview(owner: opacityPreviewOwner)
        draft.cancel()
        extended.cancel()
        interfaceDraft = interfaceBaseline
        store.showSettings = false
    }

    @ViewBuilder private var settingsContent: some View {
        switch section {
        case "interface": InterfaceSettingsForm(value: $interfaceDraft)
        case "themes": ThemeSettingsView(preferences: $draft.themePreferences, legacy: draft.settings, fontSmoothing: extended.terminal.fontSmoothing)
        case "terminal": TerminalSettingsForm(terminalPreferences: $extended.terminal, legacy: $draft.settings,
            clearRecentPaths: { store.perform { try $0.clearAllTerminalPaths() } })
        case "server": ConnectedServerSettingsPage(preferences: $extended.server, connection: serverConnection, root: store.runtime.root)
        case "integrations": ConnectedIntegrationsSettingsPage(preferences: $extended.integrations, connection: serverConnection)
        case "developer": developerSettings
        case "notifications": NotificationSettingsView(preferences: $draft.notificationPreferences,
            deliveryEnabled: $draft.settings.notifications, tailscaleAvailable: serverConnection.tailscaleAvailable,
            expandedControls: true, authorize: store.authorizeNotifications)
            .onAppear { serverConnection.refreshCapabilities() }
        case "shortcuts": keyboard
        case "profiles": ProfileAppearanceView(store: store, embedded: true, draft: $draft.settings)
        case "general": generalSettings
        case "updates": updateSettings
        default: appearance
        }
    }

    private var generalSettings: some View {
                Form {
                    Toggle("Option key sends Meta", isOn: Binding(get: { draft.settings.optionAsMeta ?? false }, set: { draft.settings.optionAsMeta = $0 }))
                    Stepper("Scrollback: \(draft.settings.scrollbackLines.formatted()) lines", value: $draft.settings.scrollbackLines, in: 1000...100_000, step: 1000)
                    Toggle("Restore sessions after restart", isOn: $draft.settings.automaticRestore)
                    Toggle("Save scrollback for recovery", isOn: $draft.settings.persistScrollback)
                    Text("Saves up to 10,000 lines or 4 MiB per pane locally as plain text. Turning this off removes saved copies.")
                        .font(.caption).foregroundStyle(.secondary)
                }.formStyle(.grouped)
    }

    private var updateSettings: some View {
                Form {
                    Toggle("Automatically check for updates", isOn: $draft.automaticallyChecksForUpdates).disabled(!updater.canCheckForUpdates)
                    Toggle("Download updates automatically", isOn: automaticDownloads).disabled(!updater.canCheckForUpdates)
                    Text(updater.status).font(.callout).foregroundStyle(.secondary)
                    Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates)
                }.formStyle(.grouped)
    }

    private var automaticDownloads: Binding<Bool> {
        Binding(get: { extended.automaticDownloads(inherited: draft.automaticallyDownloadsUpdates) },
                set: { extended.setAutomaticDownloads($0) })
    }

    private var developerInstallationKey: String {
        extended.developer.installationLocation.rawValue + ":" + extended.developer.sourceDirectory
    }

    private var developerSettings: some View {
        ScrollView {
            DeveloperSettingsSection(preferences: $extended.developer, origins: $extended.server.allowedOrigins,
                readiness: DeveloperUpdatePolicy.resolve(extended.developer, info: Bundle.main.infoDictionary ?? [:],
                    inheritedAutomaticDownloads: draft.automaticallyDownloadsUpdates),
                metadata: installationController.metadata, installationStatus: installationController.status,
                localAPIURL: serverConnection.controller?.snapshot?.runtime.localAPIURL ?? store.runtime.root.appendingPathComponent("api.sock").path,
                validateOrigins: { values in var server = extended.server; server.allowedOrigins = values; try server.validate() },
                chooseSource: {
                    installationController.chooseDirectory(owner: NSApp.keyWindow) { url in
                        extended.developer.sourceDirectory = url.path
                        extended.developer.installationLocation = .sourceCheckout
                    }
                }, refresh: refreshDeveloperInstallation)
                .padding(18)
        }
        .onAppear(perform: refreshDeveloperInstallation)
        .onChange(of: developerInstallationKey) { _, _ in refreshDeveloperInstallation() }
    }

    private func refreshDeveloperInstallation() {
        installationController.refresh(preferences: extended.developer,
            bundledHelper: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Trano Service.app"))
    }

    private var appearancePreviewSettings: TerminalSettings {
        draft.themePreferences.application(for: store.interfaceThemeMode, legacy: draft.settings).settings
    }

    private var appearance: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Font").frame(width: 100, alignment: .leading)
                    FontChoicePicker(title: "Terminal font", selection: $draft.settings.fontName)
                    Stepper("\(Int(draft.settings.fontSize)) pt", value: $draft.settings.fontSize, in: 9...40).frame(width: 112)
                }
                Text("Trano  ~/projects\n한글 입력 · English · 0123456789\n❯ claude --resume")
                    .font(Font(InstalledFontCatalog.previewFont(draft.settings)))
                    .foregroundStyle(Color(NSColor(hex: appearancePreviewSettings.appearance.foreground)))
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor(hex: appearancePreviewSettings.background))).clipShape(RoundedRectangle(cornerRadius: 6))
                HStack {
                    Text("Window opacity").frame(width: 100, alignment: .leading)
                    WindowOpacityControl(value: $draft.settings.appearance.opacity)
                    Text(draft.settings.appearance.opacity, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 42)
                }
                HStack {
                    Picker("Cursor", selection: $draft.settings.appearance.cursorStyle) {
                        ForEach(TerminalCursorStyle.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }.pickerStyle(.segmented)
                    Toggle("Blink", isOn: $draft.settings.appearance.cursorBlink).toggleStyle(.checkbox)
                }
                ExtendedAppearanceControls(settings: $draft.settings, root: store.runtime.root)
            }.padding(18)
        }
    }

    private var shortcutRecordingMode: ShortcutRecordingMode {
        shortcutSteps == 1 ? .single : .sequence(length: shortcutSteps)
    }

    private var keyboard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                TextField("Search shortcuts…", text: $query).textFieldStyle(.roundedBorder)
                Text("Key steps").foregroundStyle(.secondary)
                Picker("Key steps", selection: $shortcutSteps) {
                    Text("1").tag(1); Text("2").tag(2); Text("3").tag(3)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 110)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(((try? ActionCatalog.resolved(overrides: draft.settings.keyBindings)) ?? ActionCatalog.all).filter { query.isEmpty || ($0.title + " " + $0.category).localizedCaseInsensitiveContains(query) }) { action in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) { Text(action.title).font(.system(size: ToolPanelMetrics.bodySize)); Text(action.category).font(.system(size: ToolPanelMetrics.captionSize)).foregroundStyle(.secondary) }
                            Spacer()
                            KeyboardShortcutRecorder(value: action.bindings.first, mode: shortcutRecordingMode) { shortcut in
                                var proposed = draft.settings.keyBindings; proposed[action.id] = [shortcut]
                                do { _ = try TerminalKeySequenceMap(overrides: proposed); draft.settings.keyBindings = proposed; error = nil }
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

    private func save() {
        guard (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else {
            error = "Finish composing text before saving."; return
        }
        guard NSApp.keyWindow?.makeFirstResponder(nil) != false else {
            error = "Finish editing the current field before saving."; return
        }
        error = nil
        let settings = draft.settings, themes = draft.themePreferences, notifications = draft.notificationPreferences
        let themeBaseline = draft.baselineThemes, notificationBaseline = draft.baselineNotificationPreferences
        let interface = interfaceDraft, previousInterface = interfaceBaseline
        let checks = draft.automaticallyChecksForUpdates, downloads = draft.automaticallyDownloadsUpdates
        saveCoordinator.save(extended, validateLocal: {
            try interface.validate(); try draft.validate()
            _ = try TerminalFontAdapter.font(for: extended.terminal.resolved(legacy: settings))
        }, local: { snapshot, done in
            do {
                try draft.save(persist: { value, baseline in
                    store.saveSettings(value, from: baseline, themes: themes, themeBaseline: themeBaseline,
                        notifications: notifications, notificationBaseline: notificationBaseline,
                        interface: interface, interfaceBaseline: previousInterface,
                        terminal: snapshot.terminal, terminalBaseline: snapshot.terminalBaseline,
                        developer: snapshot.developer, developerBaseline: snapshot.developerBaseline, completion: done)
                }, updateChecks: { _ in }, updateDownloads: { _ in })
            } catch { done(error) }
        }, didSaveLocal: { _ in
            updater.automaticallyChecksForUpdates = checks
            updater.automaticallyDownloadsUpdates = extended.automaticDownloads(inherited: downloads)
            updater.applyDeveloperPreferences(extended.developer)
            interfaceBaseline = interface
            draft.reload(settings: settings, automaticallyChecksForUpdates: checks,
                automaticallyDownloadsUpdates: updater.automaticallyDownloadsUpdates,
                notificationPreferences: notifications, themePreferences: themes)
        }, server: { baseline, edited, done in
            serverConnection.saveServer(baseline: baseline, edited: edited) { failure in
                if failure == nil { updateExternalCaches() }; done(failure)
            }
        }, integrations: { baseline, edited, done in
            serverConnection.saveIntegrations(baseline: baseline, edited: edited) { failure in
                if failure == nil { updateExternalCaches() }; done(failure)
            }
        }, completion: { outcome in
            error = outcome.message
            if outcome.succeeded { store.showSettings = false }
        })
    }

    private func updateExternalCaches() {
        guard let snapshot = serverConnection.controller?.snapshot else { return }
        store.serverPreferences = snapshot.server; store.integrationsPreferences = snapshot.integrations
    }
}
