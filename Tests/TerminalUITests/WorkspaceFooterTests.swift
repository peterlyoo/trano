import AppKit
import SwiftUI
import XCTest
@testable import SwiftTerm
@testable import TerminalCore
@testable import TranoApp

@MainActor final class WorkspaceFooterTests: XCTestCase {
    // Implements: FR-CHROME-FOOTER-1, FR-NAV-6
    func testPopulatedWorkspaceKeepsTheNativeTerminalAtTheWindowBottomAfterResize() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/t-bottom-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        var session = TerminalSession(id: UUID().uuidString, title: "Native viewport", cwd: root.path, pid: 4711)
        session.alive = false
        let store = AppStore(runtime: runtime, startServices: false)
        store.state.layout.addWorkspace(title: "amber-cedar")
        store.state.layout.addTab(paneID: session.id)
        store.interfacePreferences.animationStyle = .off
        store.sessions = [session]
        let terminal = TranoView.makeClipboardTerminal(frame: .zero)
        terminal.store = store; terminal.paneID = session.id
        store.terminalViews[session.id] = terminal
        let host = NSHostingView(rootView: WorkspaceView(store: store))
        let window = WorkspaceWindow.make(contentRect: NSRect(x: -12000, y: -12000, width: 1000, height: 700), contentView: host)
        window.animationBehavior = .none
        window.orderFrontRegardless()
        defer {
            terminal.frameDriver.invalidate()
            window.contentView = nil; window.close()
            try? FileManager.default.removeItem(at: root)
        }
        var measurements: [[String: Double]] = []
        for size in [NSSize(width: 1000, height: 700), NSSize(width: 1000, height: 713), NSSize(width: 900, height: 620)] {
            window.setContentSize(size)
            for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            let workspace = try XCTUnwrap(region("terminal-workspace", in: host))
            let container = try XCTUnwrap(terminal.superview as? DeveloperTerminalContainer)
            let workspaceRect = topRect(workspace, in: host)
            let containerRect = topRect(container, in: host)
            let terminalRect = topRect(terminal, in: host)
            let rowHeight = terminal.cellDimension.height
            let rows = terminal.terminalDimensions.rows
            measurements.append(["height": size.height, "hostBottom": host.bounds.height,
                "workspaceBottom": workspaceRect.maxY, "containerBottom": containerRect.maxY,
                "terminalBottom": terminalRect.maxY, "containerHeight": container.bounds.height,
                "terminalHeight": terminal.bounds.height, "rowHeight": rowHeight, "rows": Double(rows)])
            XCTAssertEqual(workspaceRect.maxY, host.bounds.height, accuracy: 0.5)
            XCTAssertEqual(containerRect.maxY, workspaceRect.maxY, accuracy: 0.5)
            XCTAssertEqual(terminalRect.maxY, containerRect.maxY, accuracy: 0.5,
                           "Actual terminal must reclaim the bottom band, not only the outer workspace")
            XCTAssertEqual(rows, Int(floor(container.bounds.height / rowHeight)))
            let point = container.convert(NSPoint(x: 50, y: container.bounds.maxY - 0.5), to: container.superview)
            let hit = container.hitTest(point)
            XCTAssertTrue(hit === terminal || hit?.isDescendant(of: terminal) == true,
                          "The bottom edge must receive terminal mouse input")
            XCTAssertFalse(terminal.process.running)
            XCTAssertFalse(terminal.started)
            XCTAssertEqual(try runtime.state().sessions.count, 0)
            if let folder = ProcessInfo.processInfo.environment["TRANO_POPULATED_FOOTER_CAPTURE"] {
                try terminal.setUseMetal(false)
                terminal.feed(text: "\u{1b}[2J\u{1b}[HNative terminal viewport\r\n한글 입력 · bottom boundary")
                try await Task.sleep(for: .milliseconds(30))
                terminal.frameTick(); host.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: folder).appendingPathComponent("viewport-\(Int(size.height)).png"))
            }
        }
        if let folder = ProcessInfo.processInfo.environment["TRANO_POPULATED_FOOTER_CAPTURE"] {
            try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("geometry.json"))
        }
        var second = TerminalSession(id: UUID().uuidString, title: "Split viewport", cwd: root.path, pid: 4712)
        second.alive = false
        store.sessions.append(second)
        let secondTerminal = TranoView.makeClipboardTerminal(frame: .zero)
        secondTerminal.store = store; secondTerminal.paneID = second.id
        store.terminalViews[second.id] = secondTerminal
        defer { secondTerminal.frameDriver.invalidate() }
        for axis in [SplitAxis.horizontal, .vertical] {
            store.state.layout.tabs[0].tree = .split(id: UUID().uuidString, axis: axis, ratio: 0.5,
                                                    first: .pane(session.id), second: .pane(second.id))
            for padding in [0.0, 9.0] {
                store.interfacePreferences.paddingY = padding
                for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
                let workspace = try XCTUnwrap(region("terminal-workspace", in: host))
                let container = try XCTUnwrap(secondTerminal.superview as? DeveloperTerminalContainer)
                XCTAssertEqual(topRect(container, in: host).maxY, topRect(workspace, in: host).maxY - padding, accuracy: 0.5)
                for view in [terminal, secondTerminal] {
                    let owner = try XCTUnwrap(view.superview as? DeveloperTerminalContainer)
                    XCTAssertEqual(view.frame, owner.bounds)
                    XCTAssertEqual(view.terminalDimensions.rows, Int(owner.bounds.height / view.cellDimension.height))
                    XCTAssertFalse(view.started); XCTAssertFalse(view.process.running)
                }
                XCTAssertEqual(try runtime.state().sessions.count, 0)
            }
        }
    }

    private func topRect(_ view: NSView, in host: NSView) -> NSRect {
        let rect = view.convert(view.bounds, to: host)
        return NSRect(x: rect.minX, y: host.isFlipped ? rect.minY : host.bounds.maxY - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    // Implements: FR-NAV-6, U21
    func testWorkspaceContentReachesWindowBottomWithoutAStatusStrip() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/t-footer-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let binding = SupervisorBinding(paneID: "fixture", backendPID: 4711,
            configuration: SupervisorConfiguration(provider: .claude, cwd: root.path))
        let store = AppStore(runtime: runtime, externalBinding: binding)
        store.state.layout.addWorkspace(title: "amber-cedar")
        store.interfacePreferences.colorScheme = .dark
        store.interfacePreferences.animationStyle = .off
        store.sessions = (0..<40).map { _ in
            TerminalSession(id: UUID().uuidString, title: "Fixture", cwd: root.path, pid: 4711)
        }
        let host = NSHostingView(rootView: WorkspaceView(store: store))
        let window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 1000, height: 700),
                              styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.animationBehavior = .none
        window.contentView = host; window.orderFrontRegardless()
        defer { window.contentView = nil; window.close(); try? FileManager.default.removeItem(at: root) }
        for position in [InterfaceToolbarLayout.above, .left, .right] {
            store.interfacePreferences.toolbarLayout = position
            for sidebar in [false, true] {
                store.showSessionsSidebar = sidebar
                for size in [NSSize(width: 1000, height: 700), NSSize(width: 900, height: 620)] {
                    window.setContentSize(size)
                    for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
                    let workspace = try XCTUnwrap(region("terminal-workspace", in: host))
                    let rect = workspace.convert(workspace.bounds, to: host)
                    let bottomGap = host.isFlipped ? host.bounds.maxY - rect.maxY : rect.minY - host.bounds.minY
                    XCTAssertEqual(bottomGap, 0, accuracy: 0.5, "\(position) sidebar=\(sidebar) must reclaim the footer's entire height")
                    XCTAssertGreaterThan(rect.height, 500)
                    XCTAssertTrue(store.terminalViews.isEmpty, "This layout fixture must not attach or start terminal jobs")
                    XCTAssertEqual(try runtime.state().sessions.count, 0)
                    if position == .above && !sidebar && size.width == 1000 {
                        try capture(host)
                    }
                }
            }
        }
    }

    private func region(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.region(id, in: $0) }.first
    }

    private func capture(_ view: NSView) throws {
        guard let path = ProcessInfo.processInfo.environment["TRANO_FOOTER_CAPTURE"] else { return }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
