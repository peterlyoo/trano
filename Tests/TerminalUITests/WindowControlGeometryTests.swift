import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class WindowControlGeometryTests: XCTestCase {
    // Implements: FR-NAV-6
    @MainActor func testRexSizedNativeControlsStayCenteredAfterFrameAndNativeUpdates() async throws {
        _ = NSApplication.shared
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let window = WorkspaceWindow.make(contentRect: content.frame, contentView: content)
        window.setFrameOrigin(NSPoint(x: -12000, y: -12000))
        window.orderFrontRegardless()
        defer { window.close() }
        let original = try buttons(in: window)
        let actions = original.map(\.action)
        let targets = original.map(\.target)
        for size in [NSSize(width: 1000, height: 700), NSSize(width: 1300, height: 900), NSSize(width: 900, height: 620)] {
            window.setFrame(NSRect(origin: NSPoint(x: -12000, y: -12000), size: size), display: true)
            content.superview?.layoutSubtreeIfNeeded()
            window.update()
            try await Task.sleep(for: .milliseconds(30))
            try assertGeometry(window)
            for (index, button) in try buttons(in: window).enumerated() {
                XCTAssertTrue(button === original[index])
                XCTAssertEqual(button.action, actions[index])
                XCTAssertTrue(button.target === targets[index])
                XCTAssertFalse(button.isHidden)
                XCTAssertTrue(button.isEnabled)
            }
        }
    }

    // Implements: FR-NAV-6, U01
    @MainActor func testCenteredControlsRetainHeaderGapViewportAndNativeCloseWithoutStoppingJobs() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-controls-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let pane = try runtime.create(title: "Controls", cwd: root.path, shell: "/bin/sleep", arguments: ["90"])
        try runtime.update {
            $0.settings.automaticRestore = false
            $0.layout.addWorkspace(title: "Controls")
            $0.layout.addTab(paneID: pane.id)
        }
        let store = AppStore(runtime: runtime)
        let hosting = NSHostingView(rootView: WorkspaceView(store: store))
        let window = WorkspaceWindow.make(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), contentView: hosting)
        window.setFrameOrigin(NSPoint(x: -12000, y: -12000))
        let delegate = ApplicationDelegate()
        delegate.window = window; delegate.store = store; delegate.windows[window] = store
        window.delegate = delegate
        window.orderFrontRegardless()
        defer {
            window.close()
            for view in store.terminalViews.values { view.terminate() }
            try? runtime.terminate(pane.id)
            runtime.shutdownTestHost()
            try? FileManager.default.removeItem(at: root)
        }
        let deadline = Date().addingTimeInterval(5)
        while (store.loading || store.terminalViews[pane.id]?.process.running != true) && Date() < deadline {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(store.loading)
        let frame = try XCTUnwrap(hosting.superview)
        let header = try XCTUnwrap(region("workspace-header", in: hosting))
        let selector = try XCTUnwrap(region("workspace-switcher", in: hosting))
        let viewport = try XCTUnwrap(region("terminal-workspace", in: hosting))
        let headerRect = header.convert(header.bounds, to: frame)
        let selectorRect = selector.convert(selector.bounds, to: frame)
        let viewportRect = viewport.convert(viewport.bounds, to: frame)
        XCTAssertEqual(headerRect.height, 40, accuracy: 0.1)
        XCTAssertEqual(selectorRect.minX, 72, accuracy: 0.1)
        for button in try buttons(in: window) {
            XCTAssertEqual(button.convert(button.bounds, to: frame).midY, headerRect.midY, accuracy: 0.1)
        }
        let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        XCTAssertEqual(selectorRect.minX - zoom.convert(zoom.bounds, to: frame).maxX, 3, accuracy: 0.1)
        window.update()
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(viewport.convert(viewport.bounds, to: frame), viewportRect)
        if let destination = ProcessInfo.processInfo.environment["TRANO_WINDOW_CONTROLS_PREVIEW"] {
            frame.layoutSubtreeIfNeeded()
            for scale in [1, 2] {
                let rect = NSRect(x: 0, y: frame.bounds.maxY - 42, width: min(500, frame.bounds.width), height: 42)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width) * scale,
                    pixelsHigh: Int(rect.height) * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                bitmap.size = rect.size
                frame.cacheDisplay(in: rect, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: destination + "-\(scale)x.png"))
            }
        }
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        close.performClick(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(delegate.windows.isEmpty)
        XCTAssertTrue(try XCTUnwrap(runtime.list().first).alive)
        XCTAssertEqual(try runtime.list().first?.pid, pane.pid)
    }

    @MainActor private func buttons(in window: NSWindow) throws -> [NSButton] {
        try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { try XCTUnwrap(window.standardWindowButton($0)) }
    }

    @MainActor private func assertGeometry(_ window: NSWindow) throws {
        let frame = try XCTUnwrap(window.contentView?.superview)
        for (index, button) in try buttons(in: window).enumerated() {
            let rect = button.convert(button.bounds, to: frame)
            XCTAssertEqual(rect.width, 14, accuracy: 0.1)
            XCTAssertEqual(rect.height, 14, accuracy: 0.1)
            XCTAssertEqual(rect.minX, 9 + CGFloat(index) * 23, accuracy: 0.1)
            XCTAssertEqual(frame.bounds.maxY - rect.midY, 20, accuracy: 0.1)
            XCTAssertTrue(button.visibleRect.contains(button.bounds))
            XCTAssertTrue(try XCTUnwrap(button.superview).bounds.contains(button.frame))
            for x in [CGFloat(2), button.bounds.midX, button.bounds.maxX - 2] {
                let point = button.convert(NSPoint(x: x, y: button.bounds.midY), to: frame)
                let hit = try XCTUnwrap(frame.hitTest(point))
                XCTAssertTrue(hit === button || hit.isDescendant(of: button))
            }
        }
    }

    @MainActor private func region(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.region(id, in: $0) }.first
    }
}
