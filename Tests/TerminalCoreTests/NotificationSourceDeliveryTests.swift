import Foundation
import XCTest
@testable import TerminalCore

final class NotificationSourceDeliveryTests: XCTestCase {
    func testTerminalProgramSourceIsIndependentFromActivityAndQuotaSources() {
        var preferences = NotificationPreferences(); preferences.terminalNotifications = false
        XCTAssertFalse(effects(.terminal, preferences).systemNotification)
        XCTAssertTrue(effects(.activity, preferences).systemNotification)
        XCTAssertTrue(effects(.quotaLow, preferences).systemNotification)
        XCTAssertTrue(effects(.quotaReset, preferences).systemNotification)
        preferences.terminalNotifications = true
        preferences.quotaLowEnabled = false
        XCTAssertTrue(effects(.terminal, preferences).systemNotification)
        XCTAssertFalse(effects(.quotaLow, preferences).systemNotification)
        XCTAssertTrue(effects(.quotaReset, preferences).systemNotification)
    }

    func testMacOSBannerSwitchKeepsSoundIndependentWithoutInWindowFallback() {
        var preferences = NotificationPreferences(); preferences.systemNotifications = false; preferences.terminalNotifications = true
        for source in [NotificationKind.activity, .terminal, .quotaLow, .quotaReset, .tailscaleSignIn] {
            let result = effects(source, preferences)
            XCTAssertFalse(result.systemNotification)
            XCTAssertNotNil(result.soundVolume)
        }
        let inApp = NotificationPolicy.effects(kind: .activity, activity: .done, paneID: "other", preferences: preferences,
                                               legacyMasterEnabled: true, context: NotificationContext(applicationActive: true, focusedPaneID: "focused"))
        XCTAssertFalse(inApp.inApp)
        XCTAssertFalse(inApp.systemNotification)
    }

    func testBannerAndSoundMasterDoesNotDisableTabActivityOrDockBadges() {
        var preferences = NotificationPreferences(); preferences.badgeDockIcon = true
        let muted = NotificationPolicy.effects(kind: .activity, activity: .done, paneID: "other", preferences: preferences,
                                               legacyMasterEnabled: false, context: NotificationContext(applicationActive: true))
        XCTAssertFalse(muted.inApp); XCTAssertFalse(muted.systemNotification); XCTAssertNil(muted.soundVolume)
        XCTAssertTrue(muted.tabIndicator); XCTAssertTrue(muted.dockBadge)
    }

    func testPerStateBannerColumnGatesMacOSActivityBanners() {
        var preferences = NotificationPreferences(); preferences.done.systemNotification = false
        XCTAssertFalse(effects(.activity, preferences).systemNotification)
        let inApp = NotificationPolicy.effects(kind: .activity, activity: .done, paneID: "other", preferences: preferences,
                                               legacyMasterEnabled: true, context: NotificationContext(applicationActive: true, focusedPaneID: "focused"))
        XCTAssertFalse(inApp.inApp); XCTAssertNotNil(inApp.soundVolume)
    }

    private func effects(_ source: NotificationKind, _ preferences: NotificationPreferences) -> NotificationEffects {
        NotificationPolicy.effects(kind: source, activity: .done, paneID: "pane", preferences: preferences,
                                   legacyMasterEnabled: true, context: NotificationContext(applicationActive: false))
    }
}
