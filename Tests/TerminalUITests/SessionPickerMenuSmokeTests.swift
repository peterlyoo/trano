import AppKit
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class SessionPickerMenuSmokeTests: XCTestCase {
    // Implements: FR-NAV-8
    @MainActor func testSessionRowMenuOffersRenameCloseAndPersistentOrdering() async throws {
        _ = NSApplication.shared
        let runtime = try TerminalRuntime(root: URL(fileURLWithPath: "/tmp/trano-pms-" + UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        var id = ""
        try runtime.update { state in
            state.settings.automaticRestore = false
            id = state.layout.addWorkspace(title: "Alpha")
            _ = state.layout.addWorkspace(title: "Beta")
        }
        let store = AppStore(runtime: runtime)
        let deadline = Date().addingTimeInterval(3)
        while store.loading && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(store.loading)
        store.picker = .sessions
        let menu = store.workspacePickerContextMenu(workspaceID: id)
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), ["Rename Session…", "Close Session", "Move Up", "Move Down"])
        XCTAssertEqual(menu.items.first { $0.identifier?.rawValue == "picker-move-session-up" }?.isEnabled, false)
        XCTAssertEqual(menu.items.first { $0.identifier?.rawValue == "picker-move-session-down" }?.isEnabled, true)
    }
}
