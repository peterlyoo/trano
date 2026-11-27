import Foundation
import XCTest
@testable import TerminalCore

final class OrganizationUsageScopeTests: XCTestCase {
    private let now = Date()
    private let firstBinding = "11111111-2222-4333-8444-555555555555"
    private let secondBinding = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    // Implements: FR-ORG-3, FR-ORG-4
    func testSnapshotAndLedgerScopeRoundTripAndLegacyDecode() throws {
        let account = AccountProfile(provider: .claude, label: "Fixture")
        XCTAssertNil(try binding(of: snapshot(account, binding: nil)))
        XCTAssertEqual(try binding(of: snapshot(account, binding: firstBinding)), firstBinding)
        XCTAssertNil(try binding(of: window(account, binding: nil, reset: now)))
        XCTAssertEqual(try binding(of: window(account, binding: firstBinding, reset: now)), firstBinding)
        XCTAssertNil(try binding(of: snapshot(account, binding: "")))
        XCTAssertNil(try binding(of: window(account, binding: "", reset: now)))
        let emptySnapshot = AccountUsageSnapshot(accountID: account.id, provider: .claude, status: .unknown, observedAt: now,
            windows: [], source: "fixture", message: nil, organizationBindingID: "")
        XCTAssertNil(try binding(of: emptySnapshot))
        let emptyWindow = QuotaAlarmWindow(accountID: account.id, provider: .claude, windowID: "primary", resetAt: now,
            lowActive: false, resetConsumed: false, organizationBindingID: "")
        XCTAssertNil(try binding(of: emptyWindow))
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testBoundCacheRejectsLegacyOtherBindingWrongProviderAndMissingObservation() throws {
        let fixture = try fixture(binding: firstBinding)
        defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
        for value in [try snapshot(fixture.account, binding: nil), try snapshot(fixture.account, binding: secondBinding),
                      try snapshot(fixture.account, binding: firstBinding, provider: .codex)] {
            try save([value], to: fixture.runtime)
            let result = try XCTUnwrap(fixture.runtime.accountUsage(now: now).first)
            XCTAssertEqual(result.status, .unavailable)
            XCTAssertTrue(result.windows.isEmpty)
            XCTAssertNil(result.resetCredits)
        }
        try save([], to: fixture.runtime)
        XCTAssertEqual(try fixture.runtime.accountUsage(now: now).first?.status, .unavailable)
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testMatchingBindingAndLegacyUnboundClaudeCodexPreserveQuotaAndResetCredits() throws {
        for provider in [AgentKind.claude, .codex] {
            let fixture = try fixture(provider: provider)
            defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
            try save([snapshot(fixture.account, binding: nil)], to: fixture.runtime)
            let result = try XCTUnwrap(fixture.runtime.accountUsage(now: now).first)
            XCTAssertEqual(result.status, .available)
            XCTAssertEqual(result.freshAvailableResetCount(now: now), 3)
        }
        let fixture = try fixture(binding: firstBinding)
        defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
        try save([snapshot(fixture.account, binding: firstBinding)], to: fixture.runtime)
        let result = try XCTUnwrap(fixture.runtime.accountUsage(now: now).first)
        XCTAssertEqual(result.status, .available)
        XCTAssertEqual(result.freshAvailableResetCount(now: now), 3)
        XCTAssertEqual(try binding(of: result), firstBinding)
        XCTAssertEqual(try fixture.runtime.refreshAccountUsage(accountID: fixture.account.id).status, .available)
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testTrackedUnboundClearDoesNotReviveLegacyOrPreviousOrganizationQuota() throws {
        let fixture = try fixture(binding: secondBinding, selected: false)
        defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
        for oldBinding in [nil, firstBinding] {
            try save([snapshot(fixture.account, binding: oldBinding)], to: fixture.runtime)
            XCTAssertEqual(try fixture.runtime.accountUsage(now: now).first?.status, .unavailable)
        }
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testAllStaleWritersReturnUnavailableWithoutChangingCacheOrRuntime() throws {
        let fixture = try fixture(binding: secondBinding)
        defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
        let current = try snapshot(fixture.account, binding: secondBinding)
        let payload = try claudePayload()
        let attempts: [() throws -> AccountUsageSnapshot] = [
            { try fixture.runtime.recordClaudeAccountUsage(accountID: fixture.account.id, data: payload, organizationBindingID: self.firstBinding) },
            { try fixture.runtime.recordAccountLimit(accountID: fixture.account.id, source: "fixture", organizationBindingID: self.firstBinding) },
            { try fixture.runtime.recordAccountFailure(accountID: fixture.account.id, authentication: true, organizationBindingID: self.firstBinding) },
            { try fixture.runtime.recordClaudeAccountUsage(accountID: fixture.account.id, data: payload, organizationBindingID: nil) }
        ]
        for attempt in attempts {
            try save([current], to: fixture.runtime)
            let bytes = try Data(contentsOf: cache(fixture.runtime))
            let revision = try fixture.runtime.state().revision
            let result = try attempt()
            XCTAssertEqual(result.status, .unavailable)
            XCTAssertTrue(result.windows.isEmpty)
            XCTAssertNil(result.resetCredits)
            XCTAssertEqual(try Data(contentsOf: cache(fixture.runtime)), bytes)
            XCTAssertEqual(try fixture.runtime.state().revision, revision)
        }
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testMatchingWritersPersistTheirProvidedScopeAndRetainUnrelatedCache() throws {
        let fixture = try fixture(binding: firstBinding)
        defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
        let other = AccountProfile(provider: .codex, label: "Unrelated")
        try fixture.runtime.update { $0.accounts.append(other) }
        let unrelated = try snapshot(other, binding: nil)
        try save([unrelated], to: fixture.runtime)
        let observed = try fixture.runtime.recordClaudeAccountUsage(accountID: fixture.account.id, data: claudePayload(), organizationBindingID: firstBinding)
        XCTAssertEqual(observed.status, .available)
        XCTAssertEqual(try binding(of: observed), firstBinding)
        let limited = try fixture.runtime.recordAccountLimit(accountID: fixture.account.id, source: "fixture", organizationBindingID: firstBinding)
        XCTAssertEqual(limited.status, .limited)
        XCTAssertEqual(try binding(of: limited), firstBinding)
        let failed = try fixture.runtime.recordAccountFailure(accountID: fixture.account.id, authentication: true, organizationBindingID: firstBinding)
        XCTAssertEqual(failed.status, .authenticationRequired)
        XCTAssertEqual(try binding(of: failed), firstBinding)
        XCTAssertEqual(try fixture.runtime.accountUsage(now: now).first { $0.accountID == other.id }, unrelated)
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testMismatchedLedgerIsPrunedBeforeDueResetAndFutureResetScheduling() throws {
        let account = scopedAccount(firstBinding)
        for oldBinding in [nil, secondBinding] {
            var ledger = QuotaAlarmLedger()
            ledger.windows = [try window(account, binding: oldBinding, reset: now.addingTimeInterval(-1))]
            let notices = QuotaAlarmEngine.advance(ledger: &ledger, accounts: [account], usage: [], preferences: NotificationPreferences(), now: now)
            XCTAssertTrue(notices.isEmpty)
            XCTAssertTrue(ledger.windows.isEmpty)
            ledger.windows = [try window(account, binding: oldBinding, reset: now.addingTimeInterval(60))]
            XCTAssertNil(QuotaAlarmEngine.nextReset(ledger: ledger, accounts: [account], now: now))
        }
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testLedgerObservationsRequireExactScopeAndNewBindingHasIndependentLowState() throws {
        var account = scopedAccount(firstBinding)
        var ledger = QuotaAlarmLedger()
        for oldBinding in [nil, secondBinding] {
            let notices = QuotaAlarmEngine.advance(ledger: &ledger, accounts: [account], usage: [try snapshot(account, binding: oldBinding)], preferences: NotificationPreferences(), now: now)
            XCTAssertTrue(notices.isEmpty)
            XCTAssertTrue(ledger.windows.isEmpty)
        }
        let first = QuotaAlarmEngine.advance(ledger: &ledger, accounts: [account], usage: [try snapshot(account, binding: firstBinding)], preferences: NotificationPreferences(), now: now)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(try binding(of: XCTUnwrap(ledger.windows.first)), firstBinding)
        XCTAssertEqual(QuotaAlarmEngine.nextReset(ledger: ledger, accounts: [account], now: now), now.addingTimeInterval(60))
        XCTAssertTrue(QuotaAlarmEngine.advance(ledger: &ledger, accounts: [account], usage: [try snapshot(account, binding: firstBinding)], preferences: NotificationPreferences(), now: now).isEmpty)
        account.organization = AccountOrganizationState(bindingID: secondBinding)
        let next = QuotaAlarmEngine.advance(ledger: &ledger, accounts: [account], usage: [try snapshot(account, binding: secondBinding)], preferences: NotificationPreferences(), now: now)
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(try binding(of: XCTUnwrap(ledger.windows.first)), secondBinding)
    }

    private struct Fixture { let runtime: TerminalRuntime; let account: AccountProfile }
    private struct Sidecar: Encodable { let schemaVersion = 1; let profiles: [String: AccountOrganizationState] }

    private func fixture(provider: AgentKind = .claude, binding: String? = nil, selected: Bool = true) throws -> Fixture {
        let root = URL(fileURLWithPath: "/tmp/trano-usage-scope-" + UUID().uuidString.prefix(12))
        let runtime = try TerminalRuntime(root: root)
        var account = AccountProfile(provider: provider, label: "Synthetic")
        try runtime.update { $0.accounts = [account] }
        if let binding {
            let selection = selected ? try ClaudeOrganizationSelection(uuid: firstBinding, name: "Synthetic") : nil
            account.organization = AccountOrganizationState(selection: selection, bindingID: binding, profileEnabled: true, profilePinned: false)
            let data = try JSONEncoder().encode(Sidecar(profiles: [account.id: try XCTUnwrap(account.organization)]))
            try TerminalRuntime.atomicWrite(data, to: root.appendingPathComponent("account-organizations-v1.json"))
        }
        return Fixture(runtime: runtime, account: account)
    }

    private func scopedAccount(_ binding: String) -> AccountProfile {
        var account = AccountProfile(provider: .claude, label: "Synthetic")
        account.organization = AccountOrganizationState(bindingID: binding)
        return account
    }
    private func snapshot(_ account: AccountProfile, binding: String?, provider: AgentKind? = nil) throws -> AccountUsageSnapshot {
        let credits = AccountResetCredits.parse(["availableCount": 3], observedAt: now)
        let value = AccountUsageSnapshot(accountID: account.id, provider: provider ?? account.provider, status: .available, observedAt: now,
            windows: [AccountUsageWindow(id: "primary", usedPercent: 95, resetsAt: now.addingTimeInterval(60))], source: "fixture", message: nil, resetCredits: credits)
        return try withBinding(value, binding: binding)
    }
    private func window(_ account: AccountProfile, binding: String?, reset: Date) throws -> QuotaAlarmWindow {
        try withBinding(QuotaAlarmWindow(accountID: account.id, provider: account.provider, windowID: "primary", resetAt: reset, lowActive: true, resetConsumed: false, observedAt: now), binding: binding)
    }
    private func withBinding<T: Codable>(_ value: T, binding: String?) throws -> T {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        if let binding { object["organizationBindingID"] = binding }
        else { object.removeValue(forKey: "organizationBindingID") }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func binding<T: Encodable>(of value: T) throws -> String? {
        (try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])?["organizationBindingID"] as? String
    }
    private func save(_ values: [AccountUsageSnapshot], to runtime: TerminalRuntime) throws {
        try TerminalRuntime.atomicWrite(JSONEncoder().encode(values), to: cache(runtime))
    }
    private func cache(_ runtime: TerminalRuntime) -> URL { runtime.root.appendingPathComponent("account-usage.json") }
    private func claudePayload() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["rate_limits": ["five_hour": ["used_percentage": 20, "resets_at": now.addingTimeInterval(60).timeIntervalSince1970]]])
    }
}
