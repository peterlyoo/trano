import AppKit
import SwiftUI
import XCTest
import TerminalCore
@testable import TranoApp

final class ActivityGeometryTests: XCTestCase {
    // Implements: U07, U21
    @MainActor func testActivityPresentationKeepsTerminalViewportSize() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: "/tmp/trano-activity-" + UUID().uuidString)
        let runtime = try TerminalRuntime(root: directory)
        let store = AppStore(runtime: runtime)
        let deadline = Date().addingTimeInterval(3)
        while store.loading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.loading)
        let paneID = UUID().uuidString.lowercased()
        let terminal = TranoView(frame: .zero)
        store.terminalViews[paneID] = terminal
        store.state.layout.addTab(paneID: paneID)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: WorkspaceView(store: store))
        window.contentView = hosting
        defer {
            store.showActivity = false
            window.close()
            try? FileManager.default.removeItem(at: directory)
        }

        for size in [NSSize(width: 1280, height: 800), NSSize(width: 900, height: 620)] {
            window.setContentSize(size)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let before = terminal.convert(terminal.bounds, to: hosting).size
            XCTAssertGreaterThan(before.width, 400)
            XCTAssertGreaterThan(before.height, 300)

            store.showActivity = true
            try await Task.sleep(for: .milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
            let presented = terminal.convert(terminal.bounds, to: hosting).size
            XCTAssertEqual(presented.width, before.width, accuracy: 1)
            XCTAssertEqual(presented.height, before.height, accuracy: 1)

            store.showActivity = false
            try await Task.sleep(for: .milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
            let dismissed = terminal.convert(terminal.bounds, to: hosting).size
            XCTAssertEqual(dismissed.width, before.width, accuracy: 1)
            XCTAssertEqual(dismissed.height, before.height, accuracy: 1)
        }
    }
}
