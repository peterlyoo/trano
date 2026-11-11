import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class ActivityGeometryTests: XCTestCase {
    // Implements: U07, U21
    @MainActor func testActivityPresentationKeepsTerminalViewportSize() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        for size in [NSSize(width: 1280, height: 800), NSSize(width: 900, height: 620)] {
          for sidebar in [false, true] {
            fixture.store.showSessionsSidebar = sidebar
            fixture.window.setContentSize(size)
            fixture.hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let before = fixture.terminal.convert(fixture.terminal.bounds, to: fixture.hosting).size
            XCTAssertGreaterThan(before.width, 400)
            XCTAssertGreaterThan(before.height, 300)

            fixture.store.showActivity = true
            try await Task.sleep(for: .milliseconds(100))
            fixture.hosting.layoutSubtreeIfNeeded()
            let presented = fixture.terminal.convert(fixture.terminal.bounds, to: fixture.hosting).size
            XCTAssertEqual(presented.width, before.width, accuracy: 1)
            XCTAssertEqual(presented.height, before.height, accuracy: 1)
            let panel = try XCTUnwrap(region("activity-panel", in: fixture.hosting))
            let workspace = try XCTUnwrap(region("terminal-workspace", in: fixture.hosting))
            XCTAssertTrue(panel.window === fixture.window)
            let panelRect = panel.convert(panel.bounds, to: fixture.hosting)
            let workspaceRect = workspace.convert(workspace.bounds, to: fixture.hosting)
            XCTAssertTrue(workspaceRect.insetBy(dx: -0.5, dy: -0.5).contains(panelRect))
            XCTAssertTrue(fixture.hosting.bounds.insetBy(dx: -0.5, dy: -0.5).contains(panelRect))
            if let path = ProcessInfo.processInfo.environment["TRANO_ACTIVITY_SNAPSHOT"], size.width == 900, !sidebar {
                let bitmap = try XCTUnwrap(fixture.hosting.bitmapImageRepForCachingDisplay(in: fixture.hosting.bounds))
                fixture.hosting.cacheDisplay(in: fixture.hosting.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
                if let path = ProcessInfo.processInfo.environment["TRANO_UNIFIED_FRAME_SNAPSHOT"], let frame = fixture.window.contentView?.superview {
                    frame.layoutSubtreeIfNeeded()
                    let image = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
                    frame.cacheDisplay(in: frame.bounds, to: image)
                    try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
                }
            }

            fixture.store.showActivity = false
            try await Task.sleep(for: .milliseconds(100))
            fixture.hosting.layoutSubtreeIfNeeded()
            XCTAssertNil(region("activity-panel", in: fixture.hosting))
            let dismissed = fixture.terminal.convert(fixture.terminal.bounds, to: fixture.hosting).size
            XCTAssertEqual(dismissed.width, before.width, accuracy: 1)
            XCTAssertEqual(dismissed.height, before.height, accuracy: 1)
          }
        }
    }

    // Implements: FR-NAV-6
    @MainActor func testBlankHeaderSpaceRoutesToNativeWindowDrag() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let drag = try XCTUnwrap(regions("window-drag-region", in: fixture.hosting).max { $0.bounds.width < $1.bounds.width })
        XCTAssertGreaterThan(drag.bounds.width, 100)
        let frame = try XCTUnwrap(fixture.window.contentView?.superview)
        let point = drag.convert(NSPoint(x: drag.bounds.midX, y: drag.bounds.midY), to: frame)
        XCTAssertTrue(frame.hitTest(point) === drag)
    }

    // Implements: FR-NAV-6
    @MainActor func testCompactWorkspaceHeaderReclaimsSidebarWidth() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        XCTAssertEqual(fixture.terminal.bounds.width, fixture.hosting.bounds.width - 16, accuracy: 1)
        let header = try XCTUnwrap(region("workspace-header", in: fixture.hosting))
        let switcher = try XCTUnwrap(region("workspace-switcher", in: fixture.hosting))
        let headerRect = header.convert(header.bounds, to: fixture.hosting)
        let switcherRect = switcher.convert(switcher.bounds, to: fixture.hosting)
        XCTAssertLessThanOrEqual(headerRect.height, 40)
        XCTAssertEqual(fixture.hosting.isFlipped ? headerRect.minY : fixture.hosting.bounds.maxY - headerRect.maxY, 0, accuracy: 1)
        XCTAssertGreaterThanOrEqual(switcherRect.minX, 76)
        XCTAssertLessThanOrEqual(switcherRect.width, 170)
        let frame = try XCTUnwrap(fixture.window.contentView?.superview)
        let frameHeader = header.convert(header.bounds, to: frame)
        XCTAssertEqual(frame.isFlipped ? frameHeader.minY - frame.bounds.minY : frame.bounds.maxY - frameHeader.maxY, 0, accuracy: 1)
    }

    // Implements: FR-NAV-6
    @MainActor func testActivityPrecedesCommandPaletteInsideHeader() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let activity = try XCTUnwrap(region("activity-button", in: fixture.hosting))
        let palette = try XCTUnwrap(region("command-palette-button", in: fixture.hosting))
        let activityRect = activity.convert(activity.bounds, to: fixture.hosting)
        let paletteRect = palette.convert(palette.bounds, to: fixture.hosting)
        XCTAssertLessThanOrEqual(activityRect.maxX, paletteRect.minX)
        XCTAssertTrue(fixture.hosting.bounds.contains(activityRect))
        XCTAssertTrue(fixture.hosting.bounds.contains(paletteRect))
        let frame = try XCTUnwrap(fixture.window.contentView?.superview)
        let switcher = try XCTUnwrap(region("workspace-switcher", in: fixture.hosting))
        for region in [switcher, activity, palette] {
            let point = region.convert(NSPoint(x: region.bounds.midX, y: region.bounds.midY), to: frame)
            let hit = try XCTUnwrap(frame.hitTest(point))
            XCTAssertTrue(hit === fixture.hosting || hit.isDescendant(of: fixture.hosting))
        }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try XCTUnwrap(fixture.window.standardWindowButton(kind))
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: frame)
            let hit = try XCTUnwrap(frame.hitTest(point))
            XCTAssertTrue(hit === button || hit.isDescendant(of: button))
        }
    }

    // Implements: FR-NAV-6
    @MainActor func testSessionsSidebarIsOptionalAndKeepsLayout() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let layout = fixture.store.state.layout
        let wide = fixture.terminal.bounds.width
        XCTAssertFalse(fixture.store.showSessionsSidebar)
        fixture.store.showSessionsSidebar = true
        try await Task.sleep(for: .milliseconds(100))
        fixture.hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(fixture.terminal.bounds.width, wide - 217, accuracy: 1)
        fixture.store.showSessionsSidebar = false
        try await Task.sleep(for: .milliseconds(100))
        fixture.hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(fixture.terminal.bounds.width, wide, accuracy: 1)
        XCTAssertEqual(fixture.store.state.layout, layout)
    }

    // Implements: U07, FR-NAV-6
    @MainActor func testEscapeClosesActivityBeforeTerminalDispatch() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        fixture.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        fixture.window.orderFrontRegardless()
        let delegate = ApplicationDelegate()
        delegate.windows[fixture.window] = fixture.store
        fixture.store.showActivity = true
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertNotNil(event.window)
        XCTAssertTrue(delegate.handle(event))
        XCTAssertFalse(fixture.store.showActivity)
        XCTAssertFalse(delegate.handle(event))
    }

    @MainActor private func region(_ id: String, in view: NSView) -> NSView? {
        regions(id, in: view).first
    }

    @MainActor private func regions(_ id: String, in view: NSView) -> [NSView] {
        (view.identifier?.rawValue == id ? [view] : []) + view.subviews.flatMap { regions(id, in: $0) }
    }

    @MainActor private func dispose(_ fixture: Fixture) {
        fixture.store.showActivity = false
        fixture.window.close()
        try? FileManager.default.removeItem(at: fixture.root)
    }

    private struct Fixture {
        let root: URL
        let store: AppStore
        let terminal: TranoView
        let window: NSWindow
        let hosting: NSHostingView<WorkspaceView>
    }

    @MainActor private func makeFixture() async throws -> Fixture {
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
        var sample = TerminalSession(id: paneID, title: "Review build", cwd: directory.path, pid: 0, agent: .claude, alive: false)
        sample.activity.state = .blocked
        sample.activity.reason = "Waiting for review"
        store.sessions = [sample]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: WorkspaceView(store: store))
        window.contentView = hosting
        window.appearance = NSAppearance(named: .darkAqua)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        return Fixture(root: directory, store: store, terminal: terminal, window: window, hosting: hosting)
    }
}
