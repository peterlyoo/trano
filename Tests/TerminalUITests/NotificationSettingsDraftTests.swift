import AppKit
import SwiftUI
import XCTest
import TerminalCore
@testable import TranoApp

final class NotificationSettingsDraftTests: XCTestCase {
    // Implements: FR-NOTIFY-1, FR-QUOTA-1
    @MainActor func testCancelRestoresIndependentQuotaDefaultsWithoutPersistence() {
        let draft = makeDraft()
        XCTAssertTrue(draft.notificationPreferences.quotaLowEnabled)
        XCTAssertTrue(draft.notificationPreferences.quotaResetEnabled)
        draft.notificationPreferences.quotaLowEnabled = false
        draft.notificationPreferences.quotaResetEnabled = false
        draft.notificationPreferences.quotaLowRemainingPercent = 25
        draft.cancel()
        XCTAssertTrue(draft.notificationPreferences.quotaLowEnabled)
        XCTAssertTrue(draft.notificationPreferences.quotaResetEnabled)
        XCTAssertEqual(draft.notificationPreferences.quotaLowRemainingPercent, 10)
    }

    // Implements: FR-NOTIFY-1, FR-QUOTA-1
    @MainActor func testSavePersistsLowQuotaSwitchIndependentlyFromResetSwitch() throws {
        let draft = makeDraft(); draft.notificationPreferences.quotaLowEnabled = false
        var mainWrites = 0; var notificationWrites = 0
        try draft.save(persist: { _, _ in mainWrites += 1 }, updateChecks: { _ in XCTFail("Unchanged updater preference") },
                       updateDownloads: { _ in XCTFail("Unchanged updater preference") }, persistNotifications: { value, baseline in
            notificationWrites += 1
            XCTAssertFalse(value.quotaLowEnabled); XCTAssertTrue(value.quotaResetEnabled)
            XCTAssertTrue(baseline.quotaLowEnabled); XCTAssertTrue(baseline.quotaResetEnabled)
        })
        XCTAssertEqual(mainWrites, 1); XCTAssertEqual(notificationWrites, 1)
    }

    // Implements: FR-NOTIFY-1, FR-QUOTA-1
    @MainActor func testSavePersistsResetSwitchIndependentlyFromLowQuotaSwitch() throws {
        let draft = makeDraft(); draft.notificationPreferences.quotaResetEnabled = false
        var saved: NotificationPreferences?
        try draft.save(persist: { _, _ in }, updateChecks: { _ in }, updateDownloads: { _ in }, persistNotifications: { value, _ in saved = value })
        XCTAssertEqual(saved?.quotaLowEnabled, true); XCTAssertEqual(saved?.quotaResetEnabled, false)
    }

    // Implements: FR-NOTIFY-1, FR-QUOTA-1
    @MainActor func testInvalidQuotaThresholdPreventsBothSettingsAndNotificationWrites() {
        let draft = makeDraft(); draft.notificationPreferences.quotaLowRemainingPercent = 101
        draft.automaticallyChecksForUpdates = false; draft.automaticallyDownloadsUpdates = true
        var writes = 0
        XCTAssertThrowsError(try draft.save(persist: { _, _ in writes += 1 }, updateChecks: { _ in writes += 1 },
                                            updateDownloads: { _ in writes += 1 }, persistNotifications: { _, _ in writes += 1 }))
        XCTAssertEqual(writes, 0)
    }

    // Implements: FR-NOTIFY-1
    @MainActor func testReloadUsesSavedNotificationPreferencesAsTheNewCancelBaseline() {
        let draft = makeDraft(); var saved = NotificationPreferences(); saved.quotaResetEnabled = false
        draft.reload(settings: draft.settings, automaticallyChecksForUpdates: true, automaticallyDownloadsUpdates: false, notificationPreferences: saved)
        draft.notificationPreferences.quotaResetEnabled = true
        draft.cancel()
        XCTAssertEqual(draft.notificationPreferences, saved)
    }

    // Implements: FR-NOTIFY-1, FR-QUOTA-1
    @MainActor func testNotificationFormLaysOutWithoutWindowOrAuthorizationRequest() {
        let draft = makeDraft()
        let preferences = Binding(get: { draft.notificationPreferences }, set: { draft.notificationPreferences = $0 })
        let master = Binding(get: { draft.settings.notifications }, set: { draft.settings.notifications = $0 })
        let host = NSHostingView(rootView: NotificationSettingsView(preferences: preferences, deliveryEnabled: master, authorize: { XCTFail("Authorization requested during rendering") }))
        host.frame = NSRect(x: 0, y: 0, width: 632, height: 430)
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(host.window)
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    @MainActor private func makeDraft() -> SettingsDraft {
        var settings = TerminalSettings()
        settings.fontName = NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular).fontName
        return SettingsDraft(settings: settings, automaticallyChecksForUpdates: true, automaticallyDownloadsUpdates: false)
    }
}
