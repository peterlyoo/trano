import Foundation

public enum QuotaAlarmDispatch {
    @discardableResult public static func advance(ledger: inout QuotaAlarmLedger, accounts: [AccountProfile], usage: [AccountUsageSnapshot],
                                                  preferences: NotificationPreferences, now: Date,
                                                  persist: (QuotaAlarmLedger) throws -> Void,
                                                  deliver: (QuotaAlarmNotice) -> Void) throws -> Date? {
        var updated = ledger
        let notices = QuotaAlarmEngine.advance(ledger: &updated, accounts: accounts, usage: usage, preferences: preferences, now: now)
        if updated != ledger { try persist(updated) }
        ledger = updated
        for notice in notices { deliver(notice) }
        return QuotaAlarmEngine.nextReset(ledger: ledger, accounts: accounts, now: now)
    }
}
