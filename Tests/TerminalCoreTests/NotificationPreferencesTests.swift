import Foundation
import XCTest
@testable import TerminalCore

final class NotificationPreferencesTests: XCTestCase {
    // Implements: FR-NOTIFY-1, FR-QUOTA-1
    func testMissingNewKeysUseExplicitDefaultsAndQuotaSwitchesStayIndependent() throws {
        let value = try JSONDecoder().decode(NotificationPreferences.self, from: Data("{}".utf8))
        XCTAssertTrue(value.quotaLowEnabled)
        XCTAssertTrue(value.quotaResetEnabled)
        XCTAssertEqual(value.quotaLowRemainingPercent, 10)
        XCTAssertEqual(value.position, .topRight)
        XCTAssertTrue(value.includeIdleProcesses)
        XCTAssertFalse(value.badgeDockIcon)
        XCTAssertFalse(value.terminalNotifications)
        XCTAssertFalse(value.working.tabIndicator)
    }

    // Implements: FR-NOTIFY-1, FR-QUOTA-1
    func testEveryRexNotificationPreferenceRoundTripsWithoutLosingFalseValues() throws {
        var value = NotificationPreferences()
        value.position = .bottomLeft
        value.showActivityInTabs = false
        value.includeIdleProcesses = false
        value.showEachProcessInTabs = false
        value.systemNotifications = false
        value.badgeDockIcon = true
        value.playSounds = false
        value.soundVolume = 0.35
        value.working = NotificationChannels(enabled: true, tabIndicator: false, systemNotification: true, dockBadge: true, sound: true)
        value.blocked.enabled = false
        value.error.systemNotification = false
        value.done.sound = false
        value.terminalNotifications = true
        value.tailscaleSignIn = false
        value.tailscaleDeviceApproval = false
        value.tailscaleFailures = false
        value.quotaLowEnabled = false
        value.quotaResetEnabled = false
        value.quotaLowRemainingPercent = 7
        let decoded = try JSONDecoder().decode(NotificationPreferences.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
    }

    // Implements: FR-NOTIFY-2
    func testDoneBackgroundDeliveryUsesConfiguredChannelsAndWorkingStaysQuietByDefault() {
        var preferences = NotificationPreferences()
        preferences.badgeDockIcon = true
        let done = effects(.activity, .done, preferences)
        XCTAssertTrue(done.tabIndicator)
        XCTAssertTrue(done.systemNotification)
        XCTAssertTrue(done.dockBadge)
        XCTAssertEqual(done.soundVolume, 1)
        XCTAssertFalse(done.inApp)
        let working = effects(.activity, .running, preferences)
        XCTAssertFalse(working.tabIndicator)
        XCTAssertFalse(working.systemNotification)
        XCTAssertFalse(working.dockBadge)
        XCTAssertNil(working.soundVolume)
    }

    // Implements: FR-NOTIFY-2
    func testWorkingDotStaysOffWithoutSuppressingExplicitBannerAndSoundChannels() {
        var preferences = NotificationPreferences()
        preferences.working = NotificationChannels(enabled: true, tabIndicator: true, systemNotification: true, dockBadge: false, sound: true)
        let result = effects(.activity, .running, preferences)
        XCTAssertFalse(result.tabIndicator)
        XCTAssertTrue(result.systemNotification)
        XCTAssertEqual(result.soundVolume, 1)
        XCTAssertTrue(preferences.working.tabIndicator)
    }

    // Implements: FR-NOTIFY-2
    func testSystemNotificationSwitchDoesNotDisableOtherIndependentChannels() {
        var preferences = NotificationPreferences()
        preferences.systemNotifications = false
        preferences.badgeDockIcon = true
        preferences.soundVolume = 0.25
        let result = effects(.activity, .blocked, preferences)
        XCTAssertFalse(result.systemNotification)
        XCTAssertTrue(result.tabIndicator)
        XCTAssertTrue(result.dockBadge)
        XCTAssertEqual(result.soundVolume, 0.25)
        preferences.blocked.enabled = false
        let disabled = effects(.activity, .blocked, preferences)
        XCTAssertFalse(disabled.tabIndicator)
        XCTAssertFalse(disabled.systemNotification)
        XCTAssertFalse(disabled.dockBadge)
        XCTAssertNil(disabled.soundVolume)
    }

    // Implements: FR-NOTIFY-2
    func testForegroundAttentionUsesMacOSForOtherPanesButNotTheFocusedPane() {
        var preferences = NotificationPreferences()
        preferences.position = .bottomCenter
        let other = NotificationPolicy.effects(kind: .activity, activity: .error, paneID: "other", preferences: preferences,
                                               legacyMasterEnabled: true, context: NotificationContext(applicationActive: true, focusedPaneID: "focused"))
        XCTAssertFalse(other.inApp)
        XCTAssertTrue(other.systemNotification)
        XCTAssertEqual(other.position, .bottomCenter)
        let focused = NotificationPolicy.effects(kind: .activity, activity: .error, paneID: "focused", preferences: preferences,
                                                 legacyMasterEnabled: true, context: NotificationContext(applicationActive: true, focusedPaneID: "focused"))
        XCTAssertFalse(focused.inApp)
        XCTAssertFalse(focused.systemNotification, "The pane the user is looking at does not raise a banner")
    }

    // Implements: FR-NOTIFY-2, FR-QUOTA-1
    func testQuotaTerminalAndTailscaleTogglesGateTheirActualDeliveryDecision() {
        var preferences = NotificationPreferences()
        preferences.quotaLowEnabled = false
        XCTAssertFalse(effects(.quotaLow, nil, preferences).systemNotification)
        XCTAssertTrue(effects(.quotaReset, nil, preferences).systemNotification)
        preferences.quotaResetEnabled = false
        XCTAssertFalse(effects(.quotaReset, nil, preferences).systemNotification)
        XCTAssertFalse(effects(.terminal, nil, preferences).systemNotification)
        preferences.terminalNotifications = true
        XCTAssertTrue(effects(.terminal, nil, preferences).systemNotification)
        for kind in [NotificationKind.tailscaleSignIn, .tailscaleDeviceApproval, .tailscaleFailure] {
            XCTAssertTrue(effects(kind, nil, preferences).systemNotification)
        }
        preferences.tailscaleSignIn = false
        preferences.tailscaleDeviceApproval = false
        preferences.tailscaleFailures = false
        for kind in [NotificationKind.tailscaleSignIn, .tailscaleDeviceApproval, .tailscaleFailure] {
            XCTAssertFalse(effects(kind, nil, preferences).systemNotification)
        }
    }

    // Implements: FR-NOTIFY-2
    func testLegacyMasterMutesDeliveryButDoesNotRewriteVisualPreferences() {
        let preferences = NotificationPreferences()
        let result = NotificationPolicy.effects(kind: .activity, activity: .done, paneID: "pane", preferences: preferences,
                                                legacyMasterEnabled: false, context: NotificationContext(applicationActive: false))
        XCTAssertFalse(result.systemNotification)
        XCTAssertFalse(result.inApp)
        XCTAssertNil(result.soundVolume)
        XCTAssertTrue(result.tabIndicator)
        XCTAssertTrue(preferences.playSounds)
    }

    // Implements: FR-NOTIFY-2
    func testDockBadgeCountsUnreadTabsInsteadOfEveryPaneAndExcludesClosedWorkspaces() throws {
        var layout = WorkspaceLayout()
        let first = layout.addWorkspace(title: "First")
        let tab = layout.addTab(paneID: "a")
        try layout.split(tabID: tab, paneID: "b", axis: .horizontal)
        let closed = layout.addWorkspace(title: "Closed")
        layout.addTab(paneID: "c")
        layout.closeWorkspace(closed)
        try layout.selectWorkspace(first)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let sessions = [session("a", .done, date), session("b", .error, date), session("c", .blocked, date)]
        var preferences = NotificationPreferences()
        preferences.badgeDockIcon = true
        XCTAssertEqual(NotificationPolicy.dockBadgeCount(layout: layout, sessions: sessions, readAt: [:], preferences: preferences), 1)
        XCTAssertEqual(NotificationPolicy.dockBadgeCount(layout: layout, sessions: sessions, readAt: ["a": date, "b": date], preferences: preferences), 0)
        preferences.done.dockBadge = false
        preferences.error.dockBadge = false
        XCTAssertEqual(NotificationPolicy.dockBadgeCount(layout: layout, sessions: sessions, readAt: [:], preferences: preferences), 0)
    }

    // Implements: FR-NOTIFY-1
    func testInvalidVolumeAndQuotaThresholdCannotBePersisted() {
        for volume in [-0.1, 1.1, .infinity, .nan] {
            var preferences = NotificationPreferences()
            preferences.soundVolume = volume
            XCTAssertThrowsError(try preferences.validate())
        }
        for threshold in [-1, 101, .infinity, .nan] {
            var preferences = NotificationPreferences()
            preferences.quotaLowRemainingPercent = threshold
            XCTAssertThrowsError(try preferences.validate())
        }
    }

    // Implements: FR-NOTIFY-1, FR-QUOTA-1
    func testCancelAndSaveMergePreserveUneditedConcurrentNotificationChoices() throws {
        let initial = NotificationPreferences()
        var draft = NotificationPreferencesDraft(initial)
        draft.preferences.quotaResetEnabled = false
        draft.preferences.done.sound = false
        var concurrent = initial
        concurrent.quotaLowEnabled = false
        concurrent.blocked.dockBadge = false
        let saved = try draft.merged(into: concurrent)
        XCTAssertFalse(saved.quotaResetEnabled)
        XCTAssertFalse(saved.done.sound)
        XCTAssertFalse(saved.quotaLowEnabled)
        XCTAssertFalse(saved.blocked.dockBadge)
        draft.cancel()
        XCTAssertEqual(draft.preferences, initial)
    }

    // Implements: FR-NOTIFY-1, FR-QUOTA-1
    func testPrivateSidecarSurvivesAnOldPrimarySchemaRewrite() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotificationPreferencesStore(root: root)
        var value = NotificationPreferences()
        value.quotaResetEnabled = false
        value.quotaLowEnabled = false
        _ = try store.save(value)
        let url = root.appendingPathComponent("notification-preferences.json")
        guard FileManager.default.fileExists(atPath: url.path) else { XCTFail("Preferences were not persisted"); return }
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        try Data(#"{"settings":{"notifications":true}}"#.utf8).write(to: root.appendingPathComponent("state.json"))
        XCTAssertEqual(try NotificationPreferencesStore(root: root).read(), value)
    }

    // Implements: FR-NOTIFY-1
    func testPreferenceSidecarRejectsSymlinksAndMalformedExistingDataWithoutChangingTargets() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("unmanaged.json")
        let bytes = Data("preserve\n".utf8)
        try bytes.write(to: target)
        let url = root.appendingPathComponent("notification-preferences.json")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let store = NotificationPreferencesStore(root: root)
        XCTAssertThrowsError(try store.read())
        XCTAssertThrowsError(try store.save(NotificationPreferences()))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        try FileManager.default.removeItem(at: url)
        try Data("invalid JSON\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertThrowsError(try store.read())
        XCTAssertThrowsError(try store.save(NotificationPreferences()))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "invalid JSON\n")
    }

    // Implements: FR-QUOTA-1, FR-QUOTA-2
    func testLowQuotaAlertsOncePerWindowAndDisabledDeliveryDoesNotReplayOnEnable() {
        let account = account()
        var preferences = NotificationPreferences()
        var ledger = QuotaAlarmLedger()
        let usage = snapshot(account, used: 95, reset: now.addingTimeInterval(60))
        let first = QuotaAlarmEngine.advance(ledger: &ledger, accounts: [account], usage: [usage], preferences: preferences, now: now)
        XCTAssertEqual(first.map(\.kind), [.quotaLow])
        XCTAssertTrue(QuotaAlarmEngine.advance(ledger: &ledger, accounts: [account], usage: [usage], preferences: preferences, now: now.addingTimeInterval(1)).isEmpty)
        var disabled = QuotaAlarmLedger()
        preferences.quotaLowEnabled = false
        XCTAssertTrue(QuotaAlarmEngine.advance(ledger: &disabled, accounts: [account], usage: [usage], preferences: preferences, now: now).isEmpty)
        preferences.quotaLowEnabled = true
        XCTAssertTrue(QuotaAlarmEngine.advance(ledger: &disabled, accounts: [account], usage: [usage], preferences: preferences, now: now.addingTimeInterval(1)).isEmpty)
    }

    // Implements: FR-QUOTA-1, FR-QUOTA-2
    func testKnownResetDeadlineFiresOnceEvenWithoutAnotherProviderPoll() throws {
        let account = account()
        var ledger = QuotaAlarmLedger()
        var preferences = NotificationPreferences()
        preferences.quotaLowEnabled = false
        let reset = now.addingTimeInterval(60)
        _ = QuotaAlarmEngine.advance(ledger: &ledger, accounts: [account], usage: [snapshot(account, used: 100, reset: reset)], preferences: preferences, now: now)
        XCTAssertEqual(QuotaAlarmEngine.nextReset(ledger: ledger, accounts: [account], now: now), reset)
        ledger = try JSONDecoder().decode(QuotaAlarmLedger.self, from: JSONEncoder().encode(ledger))
        let notices = QuotaAlarmEngine.advance(ledger: &ledger, accounts: [account], usage: [], preferences: preferences, now: reset.addingTimeInterval(1))
        XCTAssertEqual(notices.map(\.kind), [.quotaReset])
        XCTAssertEqual(notices.first?.accountID, account.id)
        XCTAssertEqual(notices.first?.windowIDs, ["primary"])
        XCTAssertTrue(QuotaAlarmEngine.advance(ledger: &ledger, accounts: [account], usage: [], preferences: preferences, now: reset.addingTimeInterval(2)).isEmpty)
        XCTAssertNil(QuotaAlarmEngine.nextReset(ledger: ledger, accounts: [account], now: reset.addingTimeInterval(2)))
    }

    // Implements: FR-QUOTA-1, FR-QUOTA-2
    func testDisabledResetIsConsumedAndAnAlreadyPastFirstObservationDoesNotAlert() {
        let account = account()
        var ledger = QuotaAlarmLedger()
        var preferences = NotificationPreferences()
        preferences.quotaResetEnabled = false
        let reset = now.addingTimeInterval(60)
        _ = QuotaAlarmEngine.advance(ledger: &ledger, accounts: [account], usage: [snapshot(account, used: 20, reset: reset)], preferences: preferences, now: now)
        XCTAssertTrue(QuotaAlarmEngine.advance(ledger: &ledger, accounts: [account], usage: [], preferences: preferences, now: reset.addingTimeInterval(1)).isEmpty)
        preferences.quotaResetEnabled = true
        XCTAssertTrue(QuotaAlarmEngine.advance(ledger: &ledger, accounts: [account], usage: [], preferences: preferences, now: reset.addingTimeInterval(2)).isEmpty)
        var freshLedger = QuotaAlarmLedger()
        XCTAssertTrue(QuotaAlarmEngine.advance(ledger: &freshLedger, accounts: [account], usage: [snapshot(account, used: 99, reset: now.addingTimeInterval(-1))], preferences: preferences, now: now).isEmpty)
    }

    // Implements: FR-QUOTA-2
    func testUnknownStaleInvalidAndDisabledAccountsDoNotCreateQuotaAlerts() {
        var account = account()
        let reset = now.addingTimeInterval(60)
        for usage in [snapshot(account, used: 99, reset: reset, status: .unknown),
                      snapshot(account, used: 99, reset: reset, observedAt: now.addingTimeInterval(-301)),
                      snapshot(account, used: .nan, reset: reset),
                      snapshot(account, used: 101, reset: reset)] {
            var ledger = QuotaAlarmLedger()
            XCTAssertTrue(QuotaAlarmEngine.advance(ledger: &ledger, accounts: [account], usage: [usage], preferences: NotificationPreferences(), now: now).isEmpty)
            XCTAssertTrue(ledger.windows.isEmpty)
        }
        account.enabled = false
        var ledger = QuotaAlarmLedger()
        XCTAssertTrue(QuotaAlarmEngine.advance(ledger: &ledger, accounts: [account], usage: [snapshot(account, used: 99, reset: reset)], preferences: NotificationPreferences(), now: now).isEmpty)
    }

    // Implements: FR-QUOTA-2
    func testAChangedWindowStartsANewLowQuotaCycleWithoutDuplicateResets() {
        let account = account()
        var ledger = QuotaAlarmLedger()
        let preferences = NotificationPreferences()
        _ = QuotaAlarmEngine.advance(ledger: &ledger, accounts: [account], usage: [snapshot(account, used: 95, reset: now.addingTimeInterval(30))], preferences: preferences, now: now)
        let later = now.addingTimeInterval(10)
        let changed = snapshot(account, used: 95, reset: now.addingTimeInterval(120), observedAt: later)
        let notices = QuotaAlarmEngine.advance(ledger: &ledger, accounts: [account], usage: [changed], preferences: preferences, now: later)
        XCTAssertEqual(notices.map(\.kind), [.quotaLow])
        XCTAssertEqual(ledger.windows.count, 1)
        XCTAssertEqual(QuotaAlarmEngine.nextReset(ledger: ledger, accounts: [account], now: later), now.addingTimeInterval(120))
    }

    // Implements: FR-QUOTA-2
    func testKnownLimitWithoutPercentOrResetAlertsWithoutInventingAWindow() {
        let account = account()
        let limited = AccountUsageSnapshot(accountID: account.id, provider: .codex, status: .limited, observedAt: now,
                                           windows: [], source: "fixture", message: nil)
        var ledger = QuotaAlarmLedger()
        let first = QuotaAlarmEngine.advance(ledger: &ledger, accounts: [account], usage: [limited], preferences: NotificationPreferences(), now: now)
        XCTAssertEqual(first.map(\.kind), [.quotaLow])
        XCTAssertEqual(first.first?.windowIDs, [])
        XCTAssertEqual(first.first?.isLimitReached, true)
        XCTAssertNil(QuotaAlarmEngine.nextReset(ledger: ledger, accounts: [account], now: now))
        XCTAssertTrue(QuotaAlarmEngine.advance(ledger: &ledger, accounts: [account], usage: [limited], preferences: NotificationPreferences(), now: now.addingTimeInterval(1)).isEmpty)
        var disabled = NotificationPreferences(); disabled.quotaLowEnabled = false
        var consumed = QuotaAlarmLedger()
        XCTAssertTrue(QuotaAlarmEngine.advance(ledger: &consumed, accounts: [account], usage: [limited], preferences: disabled, now: now).isEmpty)
        XCTAssertTrue(QuotaAlarmEngine.advance(ledger: &consumed, accounts: [account], usage: [limited], preferences: NotificationPreferences(), now: now.addingTimeInterval(1)).isEmpty)
    }

    // Implements: FR-QUOTA-2
    func testOlderObservationCannotRearmALowWindowOrReplaceItsDeadline() {
        let account = account()
        var ledger = QuotaAlarmLedger()
        let reset = now.addingTimeInterval(120)
        _ = QuotaAlarmEngine.advance(ledger: &ledger, accounts: [account], usage: [snapshot(account, used: 95, reset: reset)], preferences: NotificationPreferences(), now: now)
        let older = snapshot(account, used: 20, reset: now.addingTimeInterval(60), observedAt: now.addingTimeInterval(-10))
        XCTAssertTrue(QuotaAlarmEngine.advance(ledger: &ledger, accounts: [account], usage: [older], preferences: NotificationPreferences(), now: now).isEmpty)
        XCTAssertEqual(ledger.windows.first?.resetAt, reset)
        XCTAssertEqual(ledger.windows.first?.lowActive, true)
    }

    // Implements: FR-QUOTA-2
    func testLedgerPersistenceKeepsDeduplicationAcrossRestartAndRejectsSymlink() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let account = account()
        var ledger = QuotaAlarmLedger()
        let usage = snapshot(account, used: 95, reset: now.addingTimeInterval(60))
        _ = QuotaAlarmEngine.advance(ledger: &ledger, accounts: [account], usage: [usage], preferences: NotificationPreferences(), now: now)
        let store = QuotaAlarmLedgerStore(root: root)
        try store.save(ledger)
        var restored = try store.read()
        XCTAssertEqual(restored, ledger)
        XCTAssertTrue(QuotaAlarmEngine.advance(ledger: &restored, accounts: [account], usage: [usage], preferences: NotificationPreferences(), now: now.addingTimeInterval(1)).isEmpty)
        let url = root.appendingPathComponent("quota-notification-ledger.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try FileManager.default.removeItem(at: url)
        let target = root.appendingPathComponent("unmanaged")
        try Data("preserved".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertThrowsError(try store.save(ledger))
        XCTAssertEqual(try Data(contentsOf: target), Data("preserved".utf8))
    }

    // Implements: FR-QUOTA-2
    func testQuotaRecoveryDoesNotReplayLowInTheSameReportedWindow() {
        let account = account(); var ledger = QuotaAlarmLedger()
        let preferences = NotificationPreferences(); let reset = now.addingTimeInterval(120)
        _ = QuotaAlarmEngine.advance(ledger: &ledger, accounts: [account], usage: [snapshot(account, used: 95, reset: reset)], preferences: preferences, now: now)
        let recovered = now.addingTimeInterval(1)
        XCTAssertTrue(QuotaAlarmEngine.advance(ledger: &ledger, accounts: [account], usage: [snapshot(account, used: 20, reset: reset, observedAt: recovered)], preferences: preferences, now: recovered).isEmpty)
        let later = now.addingTimeInterval(2)
        XCTAssertTrue(QuotaAlarmEngine.advance(ledger: &ledger, accounts: [account], usage: [snapshot(account, used: 95, reset: reset, observedAt: later)], preferences: preferences, now: later).isEmpty)
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func effects(_ kind: NotificationKind, _ activity: ActivityState?, _ preferences: NotificationPreferences) -> NotificationEffects {
        NotificationPolicy.effects(kind: kind, activity: activity, paneID: "pane", preferences: preferences,
                                   legacyMasterEnabled: true, context: NotificationContext(applicationActive: false))
    }
    private func account() -> AccountProfile {
        var profile = AccountProfile(provider: .codex, label: "Fixture")
        profile.id = "00000000-0000-4000-8000-000000000001"
        return profile
    }
    private func snapshot(_ account: AccountProfile, used: Double, reset: Date?, status: AccountUsageStatus = .available,
                          observedAt: Date? = nil) -> AccountUsageSnapshot {
        AccountUsageSnapshot(accountID: account.id, provider: account.provider, status: status, observedAt: observedAt ?? now,
                             windows: [AccountUsageWindow(id: "primary", usedPercent: used, resetsAt: reset)], source: "fixture", message: nil)
    }
    private func session(_ id: String, _ state: ActivityState, _ date: Date) -> TerminalSession {
        var value = TerminalSession(id: id, title: id, cwd: "/fixture", pid: 0)
        value.activity.state = state; value.activity.updatedAt = date
        return value
    }
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-notification-unit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
}
