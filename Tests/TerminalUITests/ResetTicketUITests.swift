import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class ResetTicketUITests: XCTestCase {
    // Implements: FR-RESET-3
    @MainActor func testBrokenUsageCacheDoesNotBlockWorkspaceActions() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        try TerminalRuntime.atomicWrite(Data("invalid cache".utf8), to: f.root.appendingPathComponent("account-usage.json"))
        f.store.perform { try $0.update { $0.settings.fontSize = 19 } }
        try await settle(f) { f.store.state.settings.fontSize == 19 }
        XCTAssertNil(f.store.message)
        XCTAssertTrue(try XCTUnwrap(f.runtime.list().first).alive)
    }

    // Implements: FR-RESET-1, FR-RESET-2, FR-RESET-3
    @MainActor func testTicketShowsExactAccountTotalBesidePaletteAndOpensDetailsWithoutChangingJobs() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        try save([try usage(f.accounts[0], count: 2), try usage(f.accounts[1], count: 1)], in: f)
        try await settle(f) { self.button(in: f.hosting)?.title == "3" }
        let ticket = try XCTUnwrap(button(in: f.hosting))
        let palette = try XCTUnwrap(region("command-palette-button", in: f.hosting))
        let header = try XCTUnwrap(region("workspace-header", in: f.hosting))
        let frame = ticket.convert(ticket.bounds, to: f.hosting)
        let commandFrame = palette.convert(palette.bounds, to: f.hosting)
        XCTAssertNotNil(ticket.image)
        XCTAssertTrue(ticket.target === ticket)
        XCTAssertEqual(ticket.accessibilityValue() as? String, "3 available")
        XCTAssertLessThanOrEqual(frame.maxX, commandFrame.minX)
        XCTAssertLessThanOrEqual(commandFrame.minX - frame.maxX, 6)
        XCTAssertTrue(header.convert(header.bounds, to: f.hosting).contains(frame))
        let before = try f.runtime.state().layout
        let pid = try XCTUnwrap(f.runtime.list().first).pid
        ticket.performClick(nil)
        try await settle(f) { f.store.showAccounts }
        XCTAssertEqual(try f.runtime.state().layout, before)
        XCTAssertEqual(try XCTUnwrap(f.runtime.list().first).pid, pid)
        XCTAssertTrue(try XCTUnwrap(f.runtime.list().first).alive)
        XCTAssertEqual(try f.runtime.accountUsage().compactMap { $0.resetCredits?.availableCount }.reduce(0, +), 3)
    }

    // Implements: FR-RESET-2
    @MainActor func testTicketHidesForZeroUnknownStaleExpiredAndDisabledAccounts() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        for unavailable in [try usage(f.accounts[0], count: 0), try usage(f.accounts[0], count: nil),
                            try usage(f.accounts[0], count: 7, now: Date().addingTimeInterval(-301)),
                            try usage(f.accounts[0], count: 1, expiresAt: Date().addingTimeInterval(-1))] {
            try save([try usage(f.accounts[0], count: 1)], in: f)
            try await settle(f) { self.button(in: f.hosting)?.title == "1" }
            try save([unavailable, try usage(f.accounts[2], count: 9)], in: f)
            try await settle(f) { self.button(in: f.hosting) == nil }
        }
    }

    // Implements: FR-RESET-2
    @MainActor func testCountUpdatesInPlaceAndFitsTheCompactHeader() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        f.window.setContentSize(NSSize(width: 900, height: 620))
        for count in [1, 12, 999, 1_000_000] {
            try save([try usage(f.accounts[0], count: count)], in: f)
            try await settle(f) { self.button(in: f.hosting)?.title == String(count) }
            let button = try XCTUnwrap(button(in: f.hosting))
            let header = try XCTUnwrap(region("workspace-header", in: f.hosting))
            XCTAssertGreaterThanOrEqual(button.bounds.width, button.intrinsicContentSize.width)
            XCTAssertTrue(header.convert(header.bounds, to: f.hosting).contains(button.convert(button.bounds, to: f.hosting)))
            XCTAssertLessThanOrEqual(header.bounds.height, 40.5)
        }
    }

    private struct Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let store: AppStore
        let hosting: NSHostingView<WorkspaceView>
        let window: NSWindow
        let accounts: [AccountProfile]
    }

    @MainActor private func fixture() async throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-reset-ui-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let pane = try runtime.create(title: "Reset fixture", cwd: root.path, shell: "/bin/sleep", arguments: ["120"])
        let accounts = try (0..<3).map { try runtime.addAccount(provider: .codex, label: "Reset account \($0)") }
        try runtime.updateAccount(accounts[2].id, enabled: false)
        try runtime.update { state in
            state.settings.automaticRestore = false
            _ = state.layout.addWorkspace(title: "Reset tickets")
            _ = state.layout.addTab(paneID: pane.id)
        }
        let store = AppStore(runtime: runtime)
        let hosting = NSHostingView(rootView: WorkspaceView(store: store))
        let window = WorkspaceWindow.make(contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 720), contentView: hosting)
        window.orderFrontRegardless()
        let f = Fixture(root: root, runtime: runtime, store: store, hosting: hosting, window: window, accounts: accounts)
        try await settle(f) { !store.loading && store.terminalViews[pane.id]?.process.running == true }
        return f
    }

    private func usage(_ account: AccountProfile, count: Int?, now: Date = Date(), expiresAt: Date? = nil) throws -> AccountUsageSnapshot {
        var payload: [String: Any] = ["ordinaryUsageAllowed": true, "rateLimits": [:]]
        if let count {
            var summary: [String: Any] = ["availableCount": count]
            if let expiresAt {
                summary["credits"] = [["id": "expired-fixture", "grantedAt": now.addingTimeInterval(-3600).timeIntervalSince1970.rounded(.down),
                                       "expiresAt": expiresAt.timeIntervalSince1970.rounded(.down), "resetType": "full", "status": "available"]]
            }
            payload["rateLimitResetCredits"] = summary
        }
        return try AccountUsageAdapter.codex(accountID: account.id, data: JSONSerialization.data(withJSONObject: payload), now: now)
    }

    @MainActor private func save(_ values: [AccountUsageSnapshot], in f: Fixture) throws {
        try TerminalRuntime.atomicWrite(JSONEncoder().encode(values), to: f.root.appendingPathComponent("account-usage.json"))
        f.store.refresh()
    }

    @MainActor private func region(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id && !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty { return view }
        return view.subviews.lazy.compactMap { self.region(id, in: $0) }.first
    }
    @MainActor private func button(in view: NSView) -> NSButton? { region("reset-ticket-button", in: view) as? NSButton }
    @MainActor private func settle(_ f: Fixture, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            f.hosting.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        } while Date() < deadline
        XCTFail("Reset ticket did not reach its expected native state")
    }
    @MainActor private func dispose(_ f: Fixture) {
        f.store.showAccounts = false
        for view in f.store.terminalViews.values { view.terminate() }
        f.store.terminalViews.removeAll()
        f.window.close()
        for pane in (try? f.runtime.list()) ?? [] { try? f.runtime.terminate(pane.id) }
        f.runtime.shutdownTestHost()
        try? FileManager.default.removeItem(at: f.root)
    }
}
