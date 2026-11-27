import Foundation

public enum DeveloperActionPolicy {
    public static func mayPreviewLink(preferences: DeveloperPreferences, hasMarkedText: Bool, hasModal: Bool, inputBusy: Bool) -> Bool {
        preferences.previewsLinks && !hasMarkedText && !hasModal && !inputBusy
    }
    public static func mayInstallUpdate(preferences: DeveloperPreferences, appHidden: Bool, visibleWindowCount: Int, inputBusy: Bool) -> Bool {
        preferences.installUpdatesAutomatically && !inputBusy && (appHidden || visibleWindowCount == 0)
    }
}
