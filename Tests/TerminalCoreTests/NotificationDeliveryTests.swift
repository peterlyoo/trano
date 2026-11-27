import Foundation
import XCTest
@testable import TerminalCore

final class NotificationDeliveryTests: XCTestCase {
    // Implements: FR-NOTIFY-2, FR-QUOTA-1
    func testDisabledQuotaResetCannotReachInjectedSystemOrSoundSink() {
        var preferences = NotificationPreferences(); preferences.quotaResetEnabled = false
        var system = 0; var banners = 0; var sounds: [Double] = []
        let message = NotificationMessage(identifier: "reset", kind: .quotaReset, title: "Fixture", body: "Fixture")
        NotificationDelivery.deliver(message, preferences: preferences, legacyMasterEnabled: true,
                                     context: NotificationContext(applicationActive: false), system: { _ in system += 1 },
                                     inApp: { _, _ in banners += 1 }, sound: { sounds.append($0) })
        XCTAssertEqual(system, 0); XCTAssertEqual(banners, 0); XCTAssertEqual(sounds, [])
        preferences.quotaLowEnabled = false; preferences.quotaResetEnabled = true; preferences.soundVolume = 0.35
        NotificationDelivery.deliver(message, preferences: preferences, legacyMasterEnabled: true,
                                     context: NotificationContext(applicationActive: false), system: { _ in system += 1 },
                                     inApp: { _, _ in banners += 1 }, sound: { sounds.append($0) })
        XCTAssertEqual(system, 1); XCTAssertEqual(sounds, [0.35])
    }

    // Implements: FR-NOTIFY-2
    func testForegroundOtherPaneReachesOnlyMacOSSink() {
        var preferences = NotificationPreferences(); preferences.position = .bottomLeft; preferences.playSounds = false
        var delivered: [String] = []
        let message = NotificationMessage(identifier: "activity", kind: .activity, title: "Fixture", body: "Fixture", paneID: "other", activity: .done)
        NotificationDelivery.deliver(message, preferences: preferences, legacyMasterEnabled: true,
                                     context: NotificationContext(applicationActive: true, focusedPaneID: "focused"),
                                     system: { delivered.append($0.identifier) },
                                     inApp: { _, _ in XCTFail("In-window notifications are disabled") }, sound: { _ in XCTFail("Sound reached while muted") })
        XCTAssertEqual(delivered, ["activity"])
    }

    // Implements: FR-QUOTA-2
    func testWindowlessLimitAndScheduledResetCopyNeverInventPercentOrAvailableQuota() {
        let account = AccountProfile(provider: .codex, label: "Fixture")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reached = QuotaAlarmNotice(kind: .quotaLow, accountID: account.id, provider: .codex, windowIDs: [], date: now, isLimitReached: true)
        let limited = NotificationMessage.quota(reached, account: account, threshold: 10)
        XCTAssertEqual(limited.title, "Codex quota reached · Fixture")
        XCTAssertFalse(limited.body.contains("%")); XCTAssertFalse(limited.body.contains("reset"))
        let reset = QuotaAlarmNotice(kind: .quotaReset, accountID: account.id, provider: .codex, windowIDs: ["primary"], date: now)
        let message = NotificationMessage.quota(reset, account: account, threshold: 10)
        XCTAssertEqual(message.body, "Scheduled quota reset time reached. Refresh usage to confirm availability.")
    }

    // Implements: FR-NOTIFY-2, FR-QUOTA-1
    func testSystemNotificationSwitchGatesEveryCategoryWithoutMutingIndependentSound() {
        var preferences = NotificationPreferences(); preferences.systemNotifications = false; preferences.terminalNotifications = true
        for kind in [NotificationKind.activity, .terminal, .quotaLow, .quotaReset, .tailscaleSignIn, .tailscaleDeviceApproval, .tailscaleFailure] {
            var sounds = 0
            let message = NotificationMessage(identifier: kind.rawValue, kind: kind, title: "Fixture", body: "Fixture", paneID: "pane", activity: .done)
            NotificationDelivery.deliver(message, preferences: preferences, legacyMasterEnabled: true,
                                         context: NotificationContext(applicationActive: false), system: { _ in XCTFail("System delivered for \(kind.rawValue)") },
                                         inApp: { _, _ in XCTFail("Foreground banner while inactive") }, sound: { _ in sounds += 1 })
            XCTAssertEqual(sounds, 1)
        }
    }

    // Implements: FR-NOTIFY-2
    func testLegacyMasterSuppressesEveryDeliverySinkAndBoundsUntrustedText() {
        let message = NotificationMessage(identifier: "fixture", kind: .terminal, title: String(repeating: "x", count: 200), body: "evil\u{1b}[0m\n" + String(repeating: "y", count: 1000))
        XCTAssertEqual(message.title.count, 100); XCTAssertEqual(message.body.count, 500)
        XCTAssertFalse(message.body.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains))
        var preferences = NotificationPreferences(); preferences.terminalNotifications = true
        NotificationDelivery.deliver(message, preferences: preferences, legacyMasterEnabled: false,
                                     context: NotificationContext(applicationActive: false), system: { _ in XCTFail("System delivered") },
                                     inApp: { _, _ in XCTFail("Banner delivered") }, sound: { _ in XCTFail("Sound delivered") })
    }

    // Implements: FR-NOTIFY-2
    func testServiceRestartBacklogSkipsStaleActivityAndKeepsLatestPerPane() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ revision: Int, _ pane: String, _ state: ActivityState, age: TimeInterval) -> ActivityEvent {
            var activity = Activity(); activity.state = state; activity.updatedAt = now.addingTimeInterval(-age)
            return ActivityEvent(revision: revision, sessionID: pane, title: pane, activity: activity, agent: .claude)
        }
        let backlog = [
            event(1, "yesterday", .error, age: 86_400),
            event(2, "shutdown", .error, age: 21_600),
            event(3, "fresh", .running, age: 5),
            event(4, "fresh", .done, age: 1),
            event(5, "idle", .idle, age: 1),
            event(6, "edge", .blocked, age: ActivityNotificationBacklog.maximumAge),
        ]
        let deliverable = ActivityNotificationBacklog.deliverable(backlog, now: now)
        XCTAssertEqual(deliverable.map(\.revision), [4, 6])
    }

    // Implements: FR-NOTIFY-2
    func testBatchDeliveryPostsEveryBannerButPlaysOneSound() {
        var preferences = NotificationPreferences(); preferences.soundVolume = 0.4
        let messages = (0..<15).map {
            NotificationMessage(identifier: "activity.\($0)", kind: .activity, title: "Fixture", body: "Task ended with an error",
                                paneID: "pane-\($0)", activity: .error)
        }
        var system: [String] = []; var sounds: [Double] = []
        NotificationDelivery.deliver(batch: messages, preferences: preferences, legacyMasterEnabled: true,
                                     context: { _ in NotificationContext(applicationActive: false) },
                                     system: { system.append($0.identifier) }, inApp: { _, _ in }, sound: { sounds.append($0) })
        XCTAssertEqual(system.count, 15); XCTAssertEqual(sounds, [0.4])
        sounds = []
        NotificationDelivery.deliver(batch: [], preferences: preferences, legacyMasterEnabled: true,
                                     context: { _ in NotificationContext(applicationActive: false) },
                                     system: { _ in XCTFail("Empty batch posted") }, inApp: { _, _ in }, sound: { sounds.append($0) })
        XCTAssertEqual(sounds, [])
    }
}
