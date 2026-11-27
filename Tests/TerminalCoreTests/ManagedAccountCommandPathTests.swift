import XCTest
@testable import TerminalCore

final class ManagedAccountCommandPathTests: XCTestCase {
    // Implements: FR-ORG-3, FR-ORG-4
    func testFactoriesUseSharedSearchPathForAuthenticationAndLaunchWithoutRunningProviders() throws {
        let runtime = try TerminalRuntime(root: URL(fileURLWithPath: "/tmp/trano-command-path-" + UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        let expected = ManagedAccountPath.normalized(ProcessInfo.processInfo.environment["PATH"], runtimeRoot: runtime.root)
        for provider in [AgentKind.claude, .codex] {
            let account = try runtime.addAccount(provider: provider, label: "Synthetic")
            for login in [true, false] {
                let command = try runtime.accountCommand(account.id, login: login)
                XCTAssertTrue(command.environment["PATH"] == expected)
                XCTAssertFalse((command.environment["PATH"] ?? "").split(separator: ":").contains(Substring(runtime.root.appendingPathComponent("bin").path)))
            }
        }
    }
}
