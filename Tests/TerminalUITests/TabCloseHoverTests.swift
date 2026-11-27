import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

@MainActor final class TabCloseHoverTests: XCTestCase {
    func testTabCloseButtonHasNoInkUntilThePointerHoversThatTab() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-tabx-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try TerminalRuntime(root: root)
        let store = AppStore(runtime: runtime)
        let deadline = Date().addingTimeInterval(3)
        while store.loading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(400))
        var ids: [String] = []
        for index in 1...2 {
            let id = UUID().uuidString.lowercased()
            ids.append(store.state.layout.addTab(paneID: id))
            store.sessions.append(TerminalSession(id: id, title: "Tab \(index)", cwd: root.path, pid: 0, alive: false))
            store.terminalViews[id] = TranoView(frame: .zero)
        }
        let hosting = NSHostingView(rootView: WorkspaceView(store: store))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 600), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { store.terminalViews.removeAll(); window.close() }
        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()

        func region(_ id: String, in view: NSView) -> NSView? {
            if view.identifier?.rawValue == id { return view }
            return view.subviews.lazy.compactMap { region(id, in: $0) }.first
        }
        func hoverView(for tabID: String) throws -> HoverTrackingView {
            let tab = try XCTUnwrap(region("workspace-tab-" + tabID, in: hosting))
            let frame = tab.convert(tab.bounds, to: nil)
            func all(_ view: NSView) -> [HoverTrackingView] { (view as? HoverTrackingView).map { [$0] } ?? [] + view.subviews.flatMap(all) }
            return try XCTUnwrap(all(hosting).first { $0.convert($0.bounds, to: nil).intersects(frame) && abs($0.convert($0.bounds, to: nil).width - frame.width) < 2 })
        }
        func ink(_ tabID: String) throws -> Int {
            let close = try XCTUnwrap(region("tab-close-" + tabID, in: hosting))
            let rect = close.convert(close.bounds, to: hosting)
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: rect))
            hosting.cacheDisplay(in: rect, to: bitmap)
            let background = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0))
            var count = 0
            for x in 0..<bitmap.pixelsWide { for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                let d = abs(color.redComponent - background.redComponent) + abs(color.greenComponent - background.greenComponent) + abs(color.blueComponent - background.blueComponent)
                if d > 0.08 { count += 1 }
            } }
            return count
        }
        XCTAssertEqual(try ink(ids[0]), 0, "Close X must be invisible before hover")
        XCTAssertEqual(try ink(ids[1]), 0)
        let hovered = try hoverView(for: ids[0])
        hovered.mouseEntered(with: try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: hovered.convert(NSPoint(x: hovered.bounds.midX, y: hovered.bounds.midY), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
        try await Task.sleep(for: .milliseconds(50)); hosting.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(try ink(ids[0]), 0, "Hovered tab shows its close X")
        XCTAssertEqual(try ink(ids[1]), 0, "Other tabs stay hidden")
        try hoverView(for: ids[0]).mouseExited(with: try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
        try await Task.sleep(for: .milliseconds(50)); hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(try ink(ids[0]), 0)
    }
}
