import XCTest
@testable import TerminalCore

final class AccountResetCreditTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func snapshot(_ summary: Any?, accountID: String = "codex-a", at observation: Date? = nil) throws -> AccountUsageSnapshot {
        var payload: [String: Any] = [
            "ordinaryUsageAllowed": false,
            "rateLimits": ["primary": ["usedPercent": 100, "resetsAt": 2_000_000_060]]
        ]
        if let summary { payload["rateLimitResetCredits"] = summary }
        return try AccountUsageAdapter.codex(accountID: accountID, data: JSONSerialization.data(withJSONObject: payload), now: observation ?? now)
    }

    private func credit(_ id: String, status: String = "available", expiresAt: Any? = nil) -> [String: Any] {
        var value: [String: Any] = ["id": id, "grantedAt": 1_999_999_000, "resetType": "codexRateLimits", "status": status]
        if let expiresAt { value["expiresAt"] = expiresAt }
        return value
    }

    // Implements: FR-RESET-2
    func testSummaryCountIsAuthoritativeWhenDetailsAreMissingNullEmptyOrCapped() throws {
        for detail in [nil, NSNull(), [], [credit("one")]] as [Any?] {
            var summary: [String: Any] = ["availableCount": 8]
            if let detail { summary["credits"] = detail }
            let value = try snapshot(summary)
            XCTAssertEqual(value.freshAvailableResetCount(now: now), 8)
            XCTAssertEqual(value.resetCredits?.availableCount, 8)
            XCTAssertEqual(value.resetCredits?.observedAt, now)
        }
        XCTAssertNil(try snapshot(["availableCount": 8]).resetCredits?.credits)
        XCTAssertNil(try snapshot(["availableCount": 8, "credits": NSNull()]).resetCredits?.credits)
        XCTAssertEqual(try snapshot(["availableCount": 8, "credits": []]).resetCredits?.credits, [])
    }

    // Implements: FR-RESET-2
    func testConfirmedZeroIsDifferentFromMissingOrNullSummary() throws {
        XCTAssertEqual(try snapshot(["availableCount": 0]).freshAvailableResetCount(now: now), 0)
        for summary in [nil, NSNull(), "unsupported", [], [:]] as [Any?] {
            let value = try snapshot(summary)
            XCTAssertNil(value.resetCredits)
            XCTAssertNil(value.freshAvailableResetCount(now: now))
            XCTAssertEqual(value.status, .limited)
            XCTAssertEqual(value.windows.count, 1)
        }
    }

    // Implements: FR-RESET-2
    func testInvalidSummaryCountsDoNotInvalidateUsage() throws {
        for count in [true, false, -1, 0.25, "3", NSNull(), 1_000_001, NSNumber(value: UInt64.max)] as [Any] {
            let value = try snapshot(["availableCount": count])
            XCTAssertNil(value.resetCredits, "Unexpected reset count for \(count)")
            XCTAssertEqual(value.status, .limited)
            XCTAssertEqual(value.windows.first?.usedPercent, 100)
            XCTAssertEqual(value.retryAt, now.addingTimeInterval(60))
        }
        let value = try snapshot(["availableCount": 1_000_000])
        XCTAssertEqual(value.freshAvailableResetCount(now: now), 1_000_000)
        for count in [Double.infinity, -Double.infinity, Double.nan] {
            XCTAssertNil(AccountResetCredits.parse(["availableCount": NSNumber(value: count)], observedAt: now))
        }
    }

    // Implements: FR-RESET-2
    func testExpiredAvailableIDsAreSubtractedOnceWithoutDoubleCountingOtherStatuses() throws {
        let details = [
            credit("expired", expiresAt: 2_000_000_010),
            credit("expired", expiresAt: 2_000_000_010),
            credit("redeeming", status: "redeeming", expiresAt: 1_999_999_999),
            credit("redeemed", status: "redeemed", expiresAt: 1_999_999_999),
            credit("unknown", status: "unknown", expiresAt: 1_999_999_999),
            credit("revoked", status: "revoked", expiresAt: 1_999_999_999),
            credit("future", expiresAt: 2_000_000_200),
            credit("no-expiry", expiresAt: NSNull())
        ]
        let value = try snapshot(["availableCount": 4, "credits": details])
        XCTAssertEqual(value.freshAvailableResetCount(now: now), 4)
        XCTAssertEqual(value.freshAvailableResetCount(now: now.addingTimeInterval(10)), 3)
        XCTAssertEqual(value.freshAvailableResetCount(now: now.addingTimeInterval(200)), 2)
        XCTAssertEqual(value.resetCredits?.credits?.first { $0.id == "redeeming" }?.status, .redeeming)
        XCTAssertEqual(value.resetCredits?.credits?.first { $0.id == "redeemed" }?.status, .redeemed)
        XCTAssertEqual(value.resetCredits?.credits?.first { $0.id == "revoked" }?.status, .unknown)
    }

    // Implements: FR-RESET-2
    func testAlreadyExpiredAvailableRowsCannotMakeTheCountNegative() throws {
        let value = try snapshot(["availableCount": 1, "credits": [credit("old-a", expiresAt: 1_999_999_999), credit("old-b", expiresAt: 1_999_999_998)]])
        XCTAssertEqual(value.freshAvailableResetCount(now: now), 0)
    }

    // Implements: FR-RESET-2
    func testCreditDetailsKeepProviderDisplayFieldsWithoutChangingOrdinaryUsagePermission() throws {
        var detail = credit("opaque-id", expiresAt: 2_000_000_200)
        detail["title"] = "Quota reset"
        detail["description"] = "Resets the included quota"
        let value = try snapshot(["availableCount": 2, "credits": [detail]])
        let parsed = try XCTUnwrap(value.resetCredits?.credits?.first)
        XCTAssertEqual(parsed.id, "opaque-id")
        XCTAssertEqual(parsed.grantedAt, Date(timeIntervalSince1970: 1_999_999_000))
        XCTAssertEqual(parsed.expiresAt, now.addingTimeInterval(200))
        XCTAssertEqual(parsed.resetType, "codexRateLimits")
        XCTAssertEqual(parsed.status, .available)
        XCTAssertEqual(parsed.title, "Quota reset")
        XCTAssertEqual(parsed.description, "Resets the included quota")
        XCTAssertEqual(value.status, .limited)
        XCTAssertEqual(value.retryAt, now.addingTimeInterval(60))
    }

    // Implements: FR-RESET-2
    func testScheduledResetsAndOtherCreditFieldsNeverImplyResetCredits() throws {
        let payload = Data(#"{"ordinaryUsageAllowed":true,"rateLimits":{"primary":{"usedPercent":3,"resetsAt":2000000060},"credits":{"hasCredits":true,"balance":"100","unlimited":false},"rateLimitResetCredits":{"availableCount":99}},"rateLimitUpsell":{"availableCount":99}}"#.utf8)
        let value = try AccountUsageAdapter.codex(accountID: "c", data: payload, now: now)
        XCTAssertEqual(value.status, .available)
        XCTAssertNil(value.freshAvailableResetCount(now: now))
        let claude = try AccountUsageAdapter.claude(accountID: "a", data: Data(#"{"rateLimitResetCredits":{"availableCount":9},"rate_limits":{"five_hour":{"used_percentage":25,"resets_at":2000000060}}}"#.utf8), now: now)
        XCTAssertNil(claude.resetCredits)
    }

    // Implements: FR-RESET-2
    func testMalformedOptionalDetailsDoNotDiscardTheConfirmedSummaryOrUsage() throws {
        for details in [true, "invalid", [NSNull(), ["id": "broken"], credit("valid")]] as [Any] {
            let value = try snapshot(["availableCount": 5, "credits": details])
            XCTAssertEqual(value.freshAvailableResetCount(now: now), 5)
            XCTAssertEqual(value.status, .limited)
        }
        var invalid = credit("bad-expiry")
        invalid["expiresAt"] = true
        let value = try snapshot(["availableCount": 5, "credits": [invalid, credit("valid")]])
        XCTAssertEqual(value.resetCredits?.credits?.map(\.id), ["valid"])
    }

    // Implements: FR-RESET-2
    func testResetCountRequiresFreshObservationIncludingTheExactBoundary() throws {
        let value = try snapshot(["availableCount": 3])
        XCTAssertEqual(value.freshAvailableResetCount(now: now.addingTimeInterval(300)), 3)
        XCTAssertNil(value.freshAvailableResetCount(now: now.addingTimeInterval(300.001)))
        XCTAssertNil(value.freshAvailableResetCount(now: now.addingTimeInterval(-0.001)))
        for seconds in [Double.infinity, -Double.infinity, Double.nan] {
            XCTAssertNil(value.freshAvailableResetCount(now: Date(timeIntervalSince1970: seconds)))
        }
    }

    // Implements: FR-RESET-2
    func testProviderDetailsAreBounded() throws {
        let rows = (0..<400).map { credit("credit-\($0)") }
        let value = try snapshot(["availableCount": 500, "credits": rows])
        XCTAssertEqual(value.freshAvailableResetCount(now: now), 500)
        XCTAssertEqual(value.resetCredits?.credits?.count, 256)
        var detail = credit("bounded")
        detail["title"] = String(repeating: "x", count: 600)
        detail["description"] = String(repeating: "y", count: 2_100)
        let bounded = try XCTUnwrap(snapshot(["availableCount": 1, "credits": [detail]]).resetCredits?.credits?.first)
        XCTAssertLessThanOrEqual(bounded.title?.utf8.count ?? 0, 512)
        XCTAssertLessThanOrEqual(bounded.description?.utf8.count ?? 0, 2_048)
    }

    // Implements: FR-RESET-2
    func testLegacyAndMalformedOptionalCacheRemainReadable() throws {
        let source = try snapshot(nil)
        let encoded = try JSONEncoder().encode(source)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "resetCredits")
        let decoded = try JSONDecoder().decode(AccountUsageSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.resetCredits)
        XCTAssertEqual(decoded.windows, source.windows)
        for malformed in [true, "invalid", ["availableCount": true], ["availableCount": -1]] as [Any] {
            legacy["resetCredits"] = malformed
            let cached = try JSONDecoder().decode(AccountUsageSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
            XCTAssertNil(cached.resetCredits)
            XCTAssertEqual(cached.windows, source.windows)
            XCTAssertEqual(cached.status, .limited)
        }
    }

    // Implements: FR-RESET-2
    func testCacheRoundTripPreservesAccountsCountsAndExpiry() throws {
        let runtime = try TerminalRuntime(root: URL(fileURLWithPath: "/tmp/trano-rc-" + UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        let first = try runtime.addAccount(provider: .codex, label: "First")
        let second = try runtime.addAccount(provider: .codex, label: "Second")
        let values = try [snapshot(["availableCount": 8, "credits": [credit("expires", expiresAt: 2_000_000_010)]], accountID: first.id), snapshot(["availableCount": 0], accountID: second.id)]
        try JSONEncoder().encode(values).write(to: runtime.root.appendingPathComponent("account-usage.json"))
        let loaded = try runtime.accountUsage(now: now.addingTimeInterval(10))
        XCTAssertEqual(loaded.map(\.accountID), [first.id, second.id])
        XCTAssertEqual(loaded.map { $0.freshAvailableResetCount(now: now.addingTimeInterval(10)) }, [7, 0])
        XCTAssertEqual(loaded.first?.resetCredits?.observedAt, now)
    }

    // Implements: FR-RESET-2
    func testReportedLimitPreservesOriginalCreditFreshnessAndFailureClearsIt() throws {
        let runtime = try TerminalRuntime(root: URL(fileURLWithPath: "/tmp/trano-rc-" + UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        let account = try runtime.addAccount(provider: .codex, label: "Fixture")
        let observation = Date().addingTimeInterval(-301)
        let prior = try snapshot(["availableCount": 3], accountID: account.id, at: observation)
        try JSONEncoder().encode([prior]).write(to: runtime.root.appendingPathComponent("account-usage.json"))
        let limited = try runtime.recordAccountLimit(accountID: account.id, source: "fixture")
        XCTAssertEqual(limited.resetCredits?.availableCount, 3)
        XCTAssertEqual(limited.resetCredits?.observedAt, observation)
        XCTAssertNil(limited.freshAvailableResetCount(now: Date()))
        for authentication in [false, true] {
            try JSONEncoder().encode([prior]).write(to: runtime.root.appendingPathComponent("account-usage.json"))
            let failed = try runtime.recordAccountFailure(accountID: account.id, authentication: authentication)
            XCTAssertNil(failed.resetCredits)
            XCTAssertNil(try runtime.accountUsage().first?.freshAvailableResetCount(now: Date()))
        }
    }
}
