import Foundation

public struct TerminalFontAdjustmentPlan {
    public let settings: TerminalSettings
    public let preferences: TerminalPreferences

    public static func make(delta: Double, settings: TerminalSettings,
                            preferences: TerminalPreferences, paneID: String?) throws -> TerminalFontAdjustmentPlan {
        guard delta.isFinite else { throw TerminalError.invalid("Invalid font size adjustment") }
        let profileIndex = paneID.flatMap { settings.paneAppearanceProfiles[$0] }.flatMap { profileID in
            settings.appearanceProfiles.firstIndex { $0.id == profileID }
        }
        let legacy = paneID.map { settings.resolvedAppearance(for: $0) } ?? settings
        let current = preferences.resolved(legacy: legacy, profileAssigned: profileIndex != nil).fontSize
        guard current.isFinite else { throw TerminalError.invalid("Invalid current font size") }
        let size = delta == 0 ? 14 : min(40, max(9, current + delta))
        var changedSettings = settings
        var changedPreferences = preferences
        if let profileIndex {
            changedSettings.appearanceProfiles[profileIndex].fontSize = size
        } else {
            changedSettings.fontSize = size
            changedPreferences.fontSize = nil
        }
        return TerminalFontAdjustmentPlan(settings: changedSettings, preferences: changedPreferences)
    }
}
