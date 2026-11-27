import AppKit
import TerminalCore

extension AppStore {
    var interfaceThemeMode: ThemeMode {
        switch interfacePreferences.colorScheme {
        case .light: return .light
        case .dark: return .dark
        case .automatic: return NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? .light : .dark
        }
    }

    func themeApplication(for paneID: String) -> ThemeApplication {
        let assigned = state.settings.paneAppearanceProfiles[paneID].map { id in state.settings.appearanceProfiles.contains { $0.id == id } } ?? false
        return themePreferences.application(for: interfaceThemeMode, legacy: state.settings.resolvedAppearance(for: paneID), profileAssigned: assigned)
    }

    func interfaceResolvedSettings(for paneID: String) -> TerminalSettings {
        var settings = themeApplication(for: paneID).settings
        let assigned = state.settings.paneAppearanceProfiles[paneID].map { id in state.settings.appearanceProfiles.contains { $0.id == id } } ?? false
        if !assigned, let preview = windowOpacityPreview { settings.appearance.opacity = preview.opacity }
        return settings
    }

    func reloadThemePreferences() {
        let runtime = runtime
        queue.async { [weak self] in
            do {
                let value = try runtime.themePreferences()
                DispatchQueue.main.async { if self?.themePreferences != value { self?.themePreferences = value } }
            } catch { DispatchQueue.main.async { self?.message = error.localizedDescription } }
        }
    }
}
