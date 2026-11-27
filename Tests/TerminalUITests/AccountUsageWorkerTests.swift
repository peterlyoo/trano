import XCTest
@testable import TerminalCore
@testable import TranoApp

final class AccountUsageWorkerTests: XCTestCase {
    // Implements: FR-RESET-2, FR-RESET-3
    func testBackgroundRefreshSkipsDisabledAndUnsupportedAccountsAndDoesNotBlockRuntimeWork() throws {
        let root = URL(fileURLWithPath: "/tmp/trano-poll-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let enabled = try runtime.addAccount(provider: .codex, label: "Enabled")
        let disabled = try runtime.addAccount(provider: .codex, label: "Disabled")
        _ = try runtime.addAccount(provider: .claude, label: "Unsupported")
        try runtime.updateAccount(disabled.id, enabled: false)
        let entered = expectation(description: "Background refresh entered")
        let finished = expectation(description: "Background refresh finished")
        let release = DispatchSemaphore(value: 0)
        var visited: [String] = []
        let lock = NSLock()
        let worker = AccountUsageWorker(runtime: runtime, interval: 60, refresh: { id in
            XCTAssertFalse(Thread.isMainThread)
            lock.lock(); visited.append(id); lock.unlock()
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            finished.fulfill()
        })
        defer { release.signal(); withExtendedLifetime(worker) {} }
        wait(for: [entered], timeout: 3)
        let metadata = expectation(description: "Runtime metadata remains available")
        DispatchQueue.global().async {
            do { try runtime.update { $0.settings.fontSize = 19 }; XCTAssertEqual(try runtime.state().settings.fontSize, 19) }
            catch { XCTFail("Metadata work was blocked by usage refresh: \(error)") }
            metadata.fulfill()
        }
        wait(for: [metadata], timeout: 1)
        release.signal()
        wait(for: [finished], timeout: 1)
        lock.lock(); let actual = visited; lock.unlock()
        XCTAssertEqual(actual, [enabled.id])
    }

    // Implements: FR-RESET-3
    func testFreshUsageDoesNotCauseAnotherProviderRequestOnStartup() throws {
        let root = URL(fileURLWithPath: "/tmp/trano-poll-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try runtime.addAccount(provider: .codex, label: "Fresh")
        let snapshot = try AccountUsageAdapter.codex(accountID: account.id, data: Data(#"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":2}}"#.utf8))
        try TerminalRuntime.atomicWrite(JSONEncoder().encode([snapshot]), to: root.appendingPathComponent("account-usage.json"))
        let unwanted = expectation(description: "No redundant provider call")
        unwanted.isInverted = true
        let worker = AccountUsageWorker(runtime: runtime, interval: 60, refresh: { _ in unwanted.fulfill() })
        wait(for: [unwanted], timeout: 0.25)
        withExtendedLifetime(worker) {}
    }
}
