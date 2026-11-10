import XCTest
@testable import TerminalCore

final class AccountTests: XCTestCase {
    // Implements: FR-ACCOUNT-1
    func testProfilesHaveSeparateRootsAndProviderOwnedLoginPlans() throws {
        let root = URL(fileURLWithPath: "/tmp/trano-accounts-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try runtime.addAccount(provider: .claude, label: "Work")
        let second = try runtime.addAccount(provider: .claude, label: "Personal")
        let codex = try runtime.addAccount(provider: .codex, label: "Codex")
        let a = try runtime.accountCommand(first.id, login: true)
        let b = try runtime.accountCommand(second.id)
        XCTAssertNotEqual(a.environment["CLAUDE_CONFIG_DIR"], b.environment["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(a.arguments, ["claude", "auth", "login", "--claudeai"])
        XCTAssertTrue(a.removeEnvironment.contains("CLAUDE_CODE_OAUTH_TOKEN"))
        let c = try runtime.accountCommand(codex.id, login: true)
        XCTAssertEqual(c.arguments, ["codex", "login"])
        XCTAssertTrue(c.environment["CODEX_HOME"]!.hasPrefix(root.path + "/accounts/"))
        XCTAssertThrowsError(try runtime.addAccount(provider: .shell, label: "Invalid"))
        XCTAssertEqual(try TerminalRuntime(root: root).state().accounts.count, 3)
    }

    // Implements: FR-ACCOUNT-2
    func testFailoverRequiresTrustedLimitAndNeverChangesProviderOrReplaysTools() throws {
        let first = AccountProfile(provider: .claude, label: "A")
        let second = AccountProfile(provider: .claude, label: "B")
        let other = AccountProfile(provider: .codex, label: "C")
        let signal = AccountLimitSignal(accountID: first.id, retryAt: Date().addingTimeInterval(60), verified: true)
        XCTAssertNil(AccountFailover.next(current: first, accounts: [first, second, other], signal: signal, optIn: true, toolsInFlight: true, resumableSessionID: "session", adapterQualified: true))
        XCTAssertNil(AccountFailover.next(current: first, accounts: [first, other], signal: signal, optIn: true, toolsInFlight: false, resumableSessionID: "session", adapterQualified: true))
        XCTAssertNil(AccountFailover.next(current: first, accounts: [first, second], signal: signal, optIn: true, toolsInFlight: false, resumableSessionID: "session", adapterQualified: false))
        XCTAssertEqual(AccountFailover.next(current: first, accounts: [first, second, other], signal: signal, optIn: true, toolsInFlight: false, resumableSessionID: "session", adapterQualified: true)?.id, second.id)
    }
}
