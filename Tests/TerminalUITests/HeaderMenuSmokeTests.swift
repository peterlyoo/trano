import AppKit
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class HeaderMenuSmokeTests: XCTestCase {
    // Implements: FR-NAV-7
    @MainActor func testEmptyHeaderStillOffersCreationAndCustomizeCommands() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-hm-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(runtime: runtime)
        let deadline = Date().addingTimeInterval(3)
        while store.loading && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(store.loading)
        let menu = store.headerContextMenu()
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["New Tab", "Rename Session…", "Close Session", "Use as Master View", "New Session", "Add Remote Host…", "Customize View"])
        XCTAssertFalse(try XCTUnwrap(menu.items.first { $0.title == "Rename Session…" }).isEnabled)
        XCTAssertFalse(try XCTUnwrap(menu.items.first { $0.title == "Close Session" }).isEnabled)
        XCTAssertFalse(try XCTUnwrap(menu.items.first { $0.title == "Use as Master View" }).isEnabled)
    }
}
