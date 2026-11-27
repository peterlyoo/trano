import AppKit
import SwiftUI
import XCTest
@testable import TranoApp

@MainActor final class TitlebarDoubleClickTests: XCTestCase {
    func testDoubleClickUsesNativeZoomAndNextDoubleClickRestores() throws {
        let f = try Fixture(); defer { f.close() }
        f.drag.mouseDown(with: try f.click(2))
        XCTAssertEqual(f.window.zoomCalls, 1)
        XCTAssertTrue(f.window.simulatedZoomed)
        XCTAssertEqual(f.window.dragCalls, 0)
        f.drag.mouseDown(with: try f.click(2))
        XCTAssertEqual(f.window.zoomCalls, 2)
        XCTAssertFalse(f.window.simulatedZoomed)
        XCTAssertEqual(f.window.dragCalls, 0)
    }

    func testSingleClickStillDragsAndOtherWindowIsUntouched() throws {
        let f = try Fixture(); defer { f.close() }
        let other = try Fixture(); defer { other.close() }
        f.drag.mouseDown(with: try f.click(1))
        XCTAssertEqual(f.window.dragCalls, 1)
        XCTAssertEqual(f.window.zoomCalls, 0)
        f.drag.mouseDown(with: try f.click(2))
        XCTAssertEqual(other.window.zoomCalls, 0)
        XCTAssertEqual(other.window.dragCalls, 0)
    }

    func testControlDoubleClickRetainsContextMenuRouting() throws {
        let f = try Fixture(); defer { f.close() }
        f.drag.mouseDown(with: try f.click(2, flags: .control))
        XCTAssertEqual(f.window.zoomCalls, 0)
        XCTAssertEqual(f.window.dragCalls, 0)
    }

    @MainActor private final class Fixture {
        let window: SpyWindow
        let hosting: NSHostingView<WindowDragRegion>
        let drag: NSView
        init() throws {
            _ = NSApplication.shared
            let host = NSHostingView(rootView: WindowDragRegion())
            hosting = host
            window = SpyWindow(contentRect: NSRect(x: -12000, y: -12000, width: 500, height: 40),
                               styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            func find(_ view: NSView) -> NSView? {
                if view.identifier?.rawValue == "window-drag-region" { return view }
                return view.subviews.lazy.compactMap { find($0) }.first
            }
            drag = try XCTUnwrap(find(host))
        }
        func click(_ count: Int, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 150, y: 15),
                modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: count, pressure: 1))
        }
        func close() { window.contentView = nil; window.close() }
    }

    @MainActor private final class SpyWindow: NSWindow {
        var zoomCalls = 0
        var dragCalls = 0
        var simulatedZoomed = false
        override func performZoom(_ sender: Any?) { zoomCalls += 1; simulatedZoomed.toggle() }
        override func performDrag(with event: NSEvent) { dragCalls += 1 }
    }
}
