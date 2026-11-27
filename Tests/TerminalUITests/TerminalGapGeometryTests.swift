import AppKit
import SwiftUI
import SwiftTerm
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class TerminalGapGeometryTests: XCTestCase {
    // Implements: FR-NAV-6, U02
    @MainActor func testHeaderPaneAndFirstTerminalRowHaveNoUnusedLayoutStrip() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-gap-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let pane = try runtime.create(title: "Gap measurement", cwd: root.path, shell: "/bin/sleep", arguments: ["90"])
        try runtime.update {
            $0.settings.automaticRestore = false
            $0.layout.addWorkspace(title: "amber-cedar")
            $0.layout.addTab(paneID: pane.id)
        }
        let store = AppStore(runtime: runtime, recoverOnStartup: false)
        let hosting = NSHostingView(rootView: WorkspaceView(store: store))
        let window = WorkspaceWindow.make(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), contentView: hosting)
        window.setFrameOrigin(NSPoint(x: -12000, y: -12000))
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
        let terminal = try XCTUnwrap(store.terminalViews[pane.id])
        terminal.suspendsRenderingWhenNotVisible = false
        var measurements: [[String: Double]] = []
        for size in [NSSize(width: 1000, height: 700), NSSize(width: 1300, height: 900), NSSize(width: 900, height: 620)] {
            window.setFrame(NSRect(origin: NSPoint(x: -12000, y: -12000), size: size), display: true)
            hosting.layoutSubtreeIfNeeded()
            window.update()
            try await Task.sleep(for: .milliseconds(50))
            let frame = try XCTUnwrap(hosting.superview)
            let header = try XCTUnwrap(region("workspace-header", in: hosting))
            let viewport = try XCTUnwrap(region("terminal-workspace", in: hosting))
            let paneHeader = try XCTUnwrap(region("pane-header-" + pane.id, in: hosting))
            let headerRect = header.convert(header.bounds, to: frame)
            let viewportRect = viewport.convert(viewport.bounds, to: frame)
            let paneHeaderRect = paneHeader.convert(paneHeader.bounds, to: frame)
            let terminalRect = terminal.convert(terminal.bounds, to: frame)
            let headerTop = top(headerRect, in: frame)
            let workspaceTop = top(viewportRect, in: frame)
            let paneHeaderTop = top(paneHeaderRect, in: frame)
            let terminalTop = top(terminalRect, in: frame)
            measurements.append([
                "window_width": window.frame.width, "window_height": window.frame.height,
                "header_top": headerTop, "header_height": headerRect.height,
                "workspace_top": workspaceTop, "pane_header_top": paneHeaderTop,
                "pane_header_height": paneHeaderRect.height, "terminal_top": terminalTop,
                "terminal_height": terminalRect.height,
                "after_header_gap": workspaceTop - headerTop - headerRect.height,
                "before_pane_header_gap": paneHeaderTop - workspaceTop,
                "before_terminal_gap": terminalTop - paneHeaderTop - paneHeaderRect.height
            ])
            XCTAssertEqual(headerTop, 0, accuracy: 0.1)
            XCTAssertEqual(headerRect.height, 40, accuracy: 0.1)
            XCTAssertEqual(workspaceTop - headerTop - headerRect.height, 1, accuracy: 0.1)
            XCTAssertEqual(paneHeaderTop, workspaceTop, accuracy: 0.1)
            XCTAssertEqual(paneHeaderRect.height, 28, accuracy: 0.1)
            XCTAssertEqual(terminalTop, paneHeaderTop + paneHeaderRect.height, accuracy: 0.1)
            XCTAssertEqual(terminalRect.minX, viewportRect.minX, accuracy: 0.1)
            XCTAssertEqual(terminalRect.width, viewportRect.width, accuracy: 0.1)
            XCTAssertEqual(terminalRect.height, viewportRect.height - paneHeaderRect.height, accuracy: 0.1)
            terminal.feed(text: "\u{1b}[2J\u{1b}[H\u{1b}[48;2;197;61;83mTOP ROW                         \u{1b}[0m")
            let rowDeadline = Date().addingTimeInterval(2)
            while terminal.terminalContentSnapshot(region: .viewport)?.rows.first?.text.hasPrefix("TOP ROW") != true && Date() < rowDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let row = try XCTUnwrap(terminal.terminalContentSnapshot(region: .viewport)?.rows.first)
            XCTAssertTrue(row.text.hasPrefix("TOP ROW"))
            XCTAssertEqual(row.cells.first?.attribute.bg, .trueColor(red: 197, green: 61, blue: 83))
            if let destination = ProcessInfo.processInfo.environment["TRANO_TERMINAL_GAP_PREVIEW"] {
                terminal.needsDisplay = true
                terminal.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                let rect = NSRect(x: 0, y: frame.bounds.maxY - 180, width: min(900, frame.bounds.width), height: 180)
                let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: rect))
                frame.cacheDisplay(in: rect, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: destination + "-\(Int(size.width))x\(Int(size.height)).png"))
            }
        }
        if let destination = ProcessInfo.processInfo.environment["TRANO_TERMINAL_GAP_PREVIEW"] {
            let data = try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: destination + "-metrics.json"))
        }
        XCTAssertTrue(try XCTUnwrap(runtime.list().first).alive)
        XCTAssertEqual(try runtime.list().first?.pid, pane.pid)
    }

    @MainActor private func top(_ rect: NSRect, in view: NSView) -> CGFloat {
        view.isFlipped ? rect.minY - view.bounds.minY : view.bounds.maxY - rect.maxY
    }

    @MainActor private func region(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.region(id, in: $0) }.first
    }
}
