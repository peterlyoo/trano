import Foundation
import XCTest
@testable import TerminalCore

final class InterfaceRuntimeTests: XCTestCase {
    // Implements: FR-SET-55
    func testRuntimeTopologyHookBalancesNewSplitsAndKeepsUserDividerAndPaneIdentity() throws {
        let root = URL(fileURLWithPath: "/tmp/trano-ifr-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try TerminalRuntime(root: root)
        var prefs = InterfacePreferences()
        prefs.autobalanceSplits = true
        try runtime.saveInterfacePreferences(prefs)
        try runtime.update { state in
            _ = state.layout.addWorkspace(title: "steady-forest")
            _ = state.layout.addTab(paneID: "a")
            state.layout.tabs[0].tree = .split(id: "manual", axis: .horizontal, ratio: 0.3, first: .pane("a"), second: .pane("b"))
        }
        let tabID = try XCTUnwrap(try runtime.state().layout.tabs.first?.id)
        try runtime.markInterfaceSplitManuallyResized("manual")
        try runtime.update { state in
            state.layout.tabs[0].tree = .split(id: "manual", axis: .horizontal, ratio: 0.3, first: .pane("a"), second: .split(id: "new", axis: .vertical, ratio: 0.7, first: .pane("b"), second: .pane("c")))
        }
        let tab = try XCTUnwrap(try runtime.state().layout.tabs.first)
        XCTAssertEqual(tab.id, tabID)
        XCTAssertEqual(tab.panes, ["a", "b", "c"])
        XCTAssertEqual(tab.tree.ratio(for: "manual"), 0.3)
        XCTAssertEqual(tab.tree.ratio(for: "new"), 0.5)
    }
}
