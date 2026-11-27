import Foundation
import XCTest
@testable import TerminalCore

final class NotificationBannerInboxTests: XCTestCase {
    // Implements: FR-NOTIFY-2
    func testLegacyInboxFilteringCannotReplaceForegroundMacOSDelivery() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let a = "00000000-0000-4000-8000-000000000001"
        let b = "00000000-0000-4000-8000-000000000002"
        let entries = [a, b].map { pane in
            NotificationBanner(message: NotificationMessage(identifier: pane, kind: .activity, title: "Fixture", body: "Completed", paneID: pane, activity: .done), position: .topRight, createdAt: now, expiresAt: now.addingTimeInterval(8))
        }
        var messages: [String] = []
        for entry in entries {
            NotificationDelivery.deliver(entry.message, preferences: NotificationPreferences(), legacyMasterEnabled: true,
                                         context: NotificationContext(applicationActive: true), system: { messages.append($0.identifier) },
                                         inApp: { _, _ in XCTFail("In-window notifications are disabled") }, sound: { _ in })
        }
        XCTAssertEqual(messages, [a, b])
        XCTAssertEqual(NotificationBannerInbox.presentable(entries, paneIDs: [a, b], focusedPaneID: a).map(\.id), [b])
        XCTAssertEqual(NotificationBannerInbox.presentable(entries, paneIDs: [a, b], focusedPaneID: b).map(\.id), [a])
        XCTAssertTrue(NotificationBannerInbox.presentable(entries, paneIDs: [], focusedPaneID: b).isEmpty)
    }

    // Implements: FR-NOTIFY-2
    func testPrivateInboxCrossesHelperGUIBoundaryBoundsEntriesAndExpiresWithoutSystemCalls() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-banner-unit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let producer = NotificationBannerInbox(root: root)
        let pane = "00000000-0000-4000-8000-000000000001"
        for index in 0..<40 {
            let message = NotificationMessage(identifier: "fixture.\(index)", kind: .activity, title: "Fixture", body: "Completed", paneID: pane, activity: .done)
            try producer.append(message, position: .bottomCenter, now: now)
        }
        let consumer = NotificationBannerInbox(root: root)
        let entries = try consumer.read(now: now)
        XCTAssertEqual(entries.count, 32); XCTAssertEqual(entries.first?.id, "fixture.8")
        XCTAssertEqual(entries.first?.position, .bottomCenter)
        XCTAssertTrue(try consumer.read(now: now.addingTimeInterval(8)).isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("notification-banners.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try producer.append(NotificationMessage(identifier: "bad", kind: .terminal, title: "Fixture", body: "Fixture"), position: .topRight, now: now))
    }
}
