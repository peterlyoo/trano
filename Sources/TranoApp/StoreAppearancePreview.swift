import Foundation
import TerminalCore

struct WindowOpacityPreview: Equatable {
    let owner: UUID
    let opacity: Double
}

extension AppStore {
    var effectiveWindowOpacity: Double { windowOpacityPreview?.opacity ?? state.settings.appearance.opacity }

    func beginWindowOpacityPreview(owner: UUID, opacity: Double) {
        guard opacity.isFinite, AppearancePreferences.opacityRange.contains(opacity) else { return }
        windowOpacityPreview = WindowOpacityPreview(owner: owner, opacity: opacity)
        floatingPanes.synchronize()
    }
    func updateWindowOpacityPreview(owner: UUID, opacity: Double) {
        guard windowOpacityPreview?.owner == owner, opacity.isFinite,
              AppearancePreferences.opacityRange.contains(opacity), windowOpacityPreview?.opacity != opacity else { return }
        windowOpacityPreview = WindowOpacityPreview(owner: owner, opacity: opacity)
        floatingPanes.synchronize()
    }
    func endWindowOpacityPreview(owner: UUID) {
        guard windowOpacityPreview?.owner == owner else { return }
        windowOpacityPreview = nil
        floatingPanes.synchronize()
    }
}
