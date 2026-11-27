import XCTest
@testable import TerminalCore

final class AccountOrganizationProofFreshnessTests: XCTestCase {
    // Implements: FR-ORG-3, FR-ORG-4
    func testSameIdentityRefreshSixSecondsLaterKeepsEarlierProjectProofUntilItsOwnTTL() throws {
        let runtime = try organizationFixtureRuntime(root: URL(fileURLWithPath: "/tmp/trano-proof-clock-" + UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        let selected = try ClaudeOrganizationSelection(uuid: "12345678-1234-4234-8234-123456789abc", name: "Synthetic")
        let account = try runtime.addAccount(provider: .claude, label: "Work", organization: selected)
        let first = try runtime.preflightAccountOrganization(accountID: account.id, cwd: "/tmp/project-a", authenticate: { account, _ in
            AccountAuthenticationSnapshot(accountID: account.id, provider: .claude, status: .authenticated, checkedAt: Date(),
                organization: selected, organizationVerification: .verified)
        })
        let secondTime = first.checkedAt.addingTimeInterval(6)
        _ = try runtime.refreshAccountOrganization(accountID: account.id, expectedBindingID: first.bindingID,
            context: ClaudeAuthenticationContext(cwd: "/tmp/project-b"), authenticate: { account, _ in
                AccountAuthenticationSnapshot(accountID: account.id, provider: .claude, status: .authenticated, checkedAt: secondTime,
                    organization: selected, organizationVerification: .verified)
            })
        let stored = try XCTUnwrap(runtime.state().accounts.first?.organization)
        XCTAssertEqual(stored.bindingID, first.bindingID)
        XCTAssertEqual(stored.checkedAt, secondTime)
        XCTAssertNil(stored.authenticationFingerprint?.contextDigest)
        try runtime.transaction {
            XCTAssertNoThrow(try runtime.validateAccountOrganizationAuthorization(first, now: secondTime, cwd: "/tmp/project-a"))
            XCTAssertThrowsError(try runtime.validateAccountOrganizationAuthorization(first, now: first.checkedAt.addingTimeInterval(60), cwd: "/tmp/project-a"))
            XCTAssertThrowsError(try runtime.validateAccountOrganizationAuthorization(first, now: secondTime, cwd: "/tmp/project-b"))
            XCTAssertThrowsError(try runtime.validateAccountOrganizationAuthorization(first, now: first.checkedAt.addingTimeInterval(-6), cwd: "/tmp/project-a"))
        }
        _ = try runtime.refreshAccountOrganization(accountID: account.id, expectedBindingID: first.bindingID,
            context: ClaudeAuthenticationContext(cwd: "/tmp/project-b"), authenticate: { account, _ in
                AccountAuthenticationSnapshot(accountID: account.id, provider: .claude, status: .authenticated,
                    checkedAt: first.checkedAt.addingTimeInterval(-61), organization: selected, organizationVerification: .verified)
            })
        XCTAssertThrowsError(try runtime.validateAccountOrganizationAuthorization(first, now: first.checkedAt, cwd: "/tmp/project-a"))
    }
}
