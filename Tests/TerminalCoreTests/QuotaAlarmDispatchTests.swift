import Foundation
import XCTest
@testable import TerminalCore

final class QuotaAlarmDispatchTests: XCTestCase {
    // Implements: FR-QUOTA-2
    func testUnchangedRefreshHasNoWritesNotificationsOrDeadlineChange() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let account = AccountProfile(provider: .codex, label: "Fixture")
        let reset = now.addingTimeInterval(60)
        let usage = AccountUsageSnapshot(accountID: account.id, provider: .codex, status: .available, observedAt: now,
                                         windows: [AccountUsageWindow(id: "primary", usedPercent: 95, resetsAt: reset)], source: "fixture", message: nil)
        var ledger = QuotaAlarmLedger(); var writes = 0; var delivered = 0
        let initial = try QuotaAlarmDispatch.advance(ledger: &ledger, accounts: [account], usage: [usage], preferences: NotificationPreferences(), now: now,
                                                     persist: { _ in writes += 1 }, deliver: { _ in delivered += 1 })
        XCTAssertEqual(initial, reset); XCTAssertEqual(writes, 1); XCTAssertEqual(delivered, 1)
        writes = 0; delivered = 0
        let next = try QuotaAlarmDispatch.advance(ledger: &ledger, accounts: [account], usage: [usage], preferences: NotificationPreferences(), now: now.addingTimeInterval(1),
                                                  persist: { _ in writes += 1 }, deliver: { _ in delivered += 1 })
        XCTAssertEqual(next, initial); XCTAssertEqual(writes, 0); XCTAssertEqual(delivered, 0)
    }

    // Implements: FR-QUOTA-2
    func testFailedLedgerWriteNeverDeliversOrCommitsInMemoryDeduplication() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let account = AccountProfile(provider: .codex, label: "Fixture")
        let usage = AccountUsageSnapshot(accountID: account.id, provider: .codex, status: .limited, observedAt: now,
                                         windows: [], source: "fixture", message: nil)
        var ledger = QuotaAlarmLedger()
        XCTAssertThrowsError(try QuotaAlarmDispatch.advance(ledger: &ledger, accounts: [account], usage: [usage], preferences: NotificationPreferences(), now: now,
                                                           persist: { _ in throw TerminalError.runtime("Fixture failure") }, deliver: { _ in XCTFail("Delivered without durable deduplication") }))
        XCTAssertTrue(ledger.windows.isEmpty)
    }
}
