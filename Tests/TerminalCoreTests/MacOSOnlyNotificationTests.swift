import Foundation
import XCTest
@testable import TerminalCore

final class MacOSOnlyNotificationTests: XCTestCase {
    func testEnabledActivityReachesSystemSinkUnlessItsPaneIsFocusedAndNeverInWindowSink() {
        var preferences = NotificationPreferences()
        preferences.playSounds = false
        let contexts = [NotificationContext(applicationActive: false),
                        NotificationContext(applicationActive: true),
                        NotificationContext(applicationActive: true, focusedPaneID: "pane"),
                        NotificationContext(applicationActive: true, focusedPaneID: "another-pane")]
        for state in [ActivityState.blocked, .error, .done] {
            for context in contexts {
                let message = NotificationMessage(identifier: state.rawValue, kind: .activity,
                    title: "Fixture", body: "Fixture", paneID: "pane", activity: state)
                var delivered: [NotificationMessage] = []
                let effect = NotificationDelivery.deliver(message, preferences: preferences, legacyMasterEnabled: true,
                    context: context, system: { delivered.append($0) },
                    inApp: { _, _ in XCTFail("Activity must never produce an in-window notification") },
                    sound: { _ in XCTFail("Sound is disabled") })
                let watching = context.applicationActive && context.focusedPaneID == "pane"
                XCTAssertEqual(delivered, watching ? [] : [message], "The pane the user is looking at must not raise a banner")
                XCTAssertEqual(effect.systemNotification, !watching)
                XCTAssertFalse(effect.inApp)
            }
        }
    }

    func testEveryEnabledNotificationSourceUsesMacOSInForegroundAndBackground() {
        var preferences = NotificationPreferences()
        preferences.playSounds = false
        preferences.terminalNotifications = true
        for source in [NotificationKind.terminal, .quotaLow, .quotaReset, .tailscaleSignIn, .tailscaleDeviceApproval, .tailscaleFailure] {
            for active in [false, true] {
                let message = NotificationMessage(identifier: source.rawValue, kind: source, title: "Fixture", body: "Fixture")
                var calls = 0
                let effect = NotificationDelivery.deliver(message, preferences: preferences, legacyMasterEnabled: true,
                    context: NotificationContext(applicationActive: active), system: { _ in calls += 1 },
                    inApp: { _, _ in XCTFail("Source must never produce an in-window notification") }, sound: { _ in })
                XCTAssertEqual(calls, 1)
                XCTAssertTrue(effect.systemNotification)
                XCTAssertFalse(effect.inApp)
            }
        }
    }

    func testDisablingMacOSDoesNotFallbackToAnInWindowBannerOrMuteIndependentSound() {
        var preferences = NotificationPreferences()
        preferences.systemNotifications = false
        let effect = NotificationDelivery.deliver(
            NotificationMessage(identifier: "done", kind: .activity, title: "Fixture", body: "Fixture", paneID: "pane", activity: .done),
            preferences: preferences, legacyMasterEnabled: true,
            context: NotificationContext(applicationActive: true, focusedPaneID: "another-pane"),
            system: { _ in XCTFail("macOS notifications are disabled") },
            inApp: { _, _ in XCTFail("Disabling macOS must not enable a fallback banner") }, sound: { XCTAssertEqual($0, 1) })
        XCTAssertFalse(effect.systemNotification)
        XCTAssertFalse(effect.inApp)
        XCTAssertEqual(effect.soundVolume, 1)
    }

    func testMasterAndPerStateSwitchesStillGateSystemDelivery() {
        var preferences = NotificationPreferences()
        preferences.done.systemNotification = false
        for active in [false, true] {
            let context = NotificationContext(applicationActive: active)
            let stateDisabled = NotificationPolicy.effects(kind: .activity, activity: .done, paneID: "pane",
                preferences: preferences, legacyMasterEnabled: true, context: context)
            XCTAssertFalse(stateDisabled.systemNotification)
            XCTAssertFalse(stateDisabled.inApp)
            let masterDisabled = NotificationPolicy.effects(kind: .activity, activity: .blocked, paneID: "pane",
                preferences: preferences, legacyMasterEnabled: false, context: context)
            XCTAssertFalse(masterDisabled.systemNotification)
            XCTAssertFalse(masterDisabled.inApp)
            XCTAssertNil(masterDisabled.soundVolume)
        }
    }
}
