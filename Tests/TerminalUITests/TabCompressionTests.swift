import AppKit
import SwiftUI
import XCTest
@testable import SwiftTerm
@testable import TerminalCore
@testable import TranoApp

@MainActor final class TabCompressionTests: XCTestCase {
    func testAddingTabsCompressesExistingWidthsAndKeepsEveryTabVisible() async throws {
        let f = try Fixture(); defer { f.close() }
        try await f.replaceTabs(3)
        let initial = try XCTUnwrap(f.tabRects().first?.width)
        try await f.replaceTabs(6)
        let compressed = try XCTUnwrap(f.tabRects().first?.width)
        XCTAssertLessThan(compressed, initial)
        try f.assertVisibleTabs(6)
        XCTAssertTrue(try f.runtime.list().isEmpty)
    }

    func testOverflowingTabsKeepMinimumWidthAndScrollToTheSelectedTab() async throws {
        let f = try Fixture(); defer { f.close() }
        try await f.replaceTabs(30)
        let tabs = f.store.state.layout.currentTabs
        for (tab, rect) in zip(tabs, try f.tabRects()) {
            XCTAssertGreaterThanOrEqual(rect.width, 80, "Tab shrank below its minimum width")
            let title = try XCTUnwrap(f.region("tab-title-" + tab.id))
            XCTAssertGreaterThanOrEqual(title.bounds.width, 8, "Tab title has no room for its first character")
        }
        for index in [0, 29, 14, 0] {
            try f.store.state.layout.selectTab(tabs[index].id)
            await f.layout()
            let row = try XCTUnwrap(f.region("workspace-tab-" + tabs[index].id))
            XCTAssertEqual(row.clippedVisibleBounds.width, row.bounds.width, accuracy: 1, "Selected tab \(index) is not scrolled into view")
        }
        XCTAssertLessThan(try XCTUnwrap(f.region("workspace-tab-" + tabs[29].id)).clippedVisibleBounds.width, 1, "Tab strip did not scroll")
    }

    func testCompressedCloseTargetsRemainInTheirOwnTabsAndSeparateFromDragging() async throws {
        let f = try Fixture(); defer { f.close() }
        try await f.replaceTabs(12)
        for tab in f.store.state.layout.currentTabs {
            let row = try XCTUnwrap(f.region("workspace-tab-" + tab.id))
            let close = try XCTUnwrap(f.region("tab-close-" + tab.id))
            let drag = try XCTUnwrap(f.region("tab-drag-" + tab.id))
            let rowRect = row.convert(row.bounds, to: f.hosting)
            let closeRect = close.convert(close.bounds, to: f.hosting)
            let dragRect = drag.convert(drag.bounds, to: f.hosting)
            XCTAssertGreaterThan(closeRect.width, 0)
            XCTAssertGreaterThan(closeRect.height, 0)
            XCTAssertTrue(rowRect.insetBy(dx: -1, dy: -1).contains(closeRect), "Close target escaped its tab")
            XCTAssertFalse(dragRect.contains(NSPoint(x: closeRect.midX, y: closeRect.midY)))
        }
    }

    func testFillAvailableSettingStillUsesAllTabSpaceWithoutOverflow() async throws {
        let f = try Fixture(); defer { f.close() }
        f.store.interfacePreferences.tabsFillAvailableSpace = true
        try await f.replaceTabs(6)
        try f.assertVisibleTabs(6)
        let filled = try XCTUnwrap(f.tabRects().first?.width)
        f.store.interfacePreferences.tabsFillAvailableSpace = false
        await f.layout()
        let compact = try XCTUnwrap(f.tabRects().first?.width)
        XCTAssertLessThanOrEqual(compact, filled)
        try f.assertVisibleTabs(6)
    }

    func testRestartControllerTracksTheInstalledBuild() async throws {
        let f = try Fixture(); defer { f.close() }
        let bundle = f.root.appendingPathComponent("Installed.app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bundle.appendingPathComponent("Contents/MacOS/TranoApp").path, contents: Data(), attributes: [.posixPermissions: 0o755])
        func install(_ id: String) throws {
            try PropertyListSerialization.data(fromPropertyList: ["TranoBuildID": id], format: .xml, options: 0)
                .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        }
        let current = String(repeating: "a", count: 64)
        try install(current)
        let controller = AppRestartController(bundleURL: bundle, running: BuildIdentity(info: ["TranoBuildID": current]))
        controller.check()
        XCTAssertNil(controller.pendingBuild)
        try install(String(repeating: "c", count: 64))
        controller.check()
        XCTAssertEqual(controller.pendingBuild?.buildID, String(repeating: "c", count: 64))
        try install(current)
        controller.check()
        XCTAssertNil(controller.pendingBuild)
        XCTAssertNil(f.region("restart-update-button"), "Test process is unbundled, so the shared controller must stay idle")
    }

    @MainActor private final class Fixture {
        let root = URL(fileURLWithPath: "/tmp/trano-tab-compression-" + UUID().uuidString.prefix(8))
        let runtime: TerminalRuntime
        let store: AppStore
        let hosting: NSHostingView<WorkspaceView>
        let window: NSWindow
        init() throws {
            _ = NSApplication.shared
            runtime = try TerminalRuntime(root: root)
            store = AppStore(runtime: runtime, startServices: false)
            store.interfacePreferences = InterfacePreferences()
            hosting = NSHostingView(rootView: WorkspaceView(store: store))
            window = WorkspaceWindow.make(contentRect: NSRect(x: -12000, y: -12000, width: 1000, height: 700), contentView: hosting)
            window.animationBehavior = .none
            window.orderFrontRegardless()
        }
        func replaceTabs(_ count: Int) async throws {
            var layout = WorkspaceLayout()
            layout.addWorkspace(title: "test-session")
            var rows: [TerminalSession] = []
            for index in 0..<count {
                let id = UUID().uuidString.lowercased()
                rows.append(TerminalSession(id: id, title: "Agent review of a sufficiently long filename \(index)", cwd: root.path, pid: 0, alive: false))
                layout.addTab(paneID: id)
                let terminal = TranoView(frame: .zero)
                terminal.frameDriver.invalidate()
                terminal.paneID = id; terminal.store = store
                store.terminalViews[id] = terminal
            }
            store.sessions = rows
            store.state.sessions = rows
            store.state.layout = layout
            await self.layout()
        }
        func layout() async {
            for _ in 0..<6 {
                hosting.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        func region(_ id: String) -> NSView? {
            func find(_ view: NSView) -> NSView? {
                if view.identifier?.rawValue == id { return view }
                return view.subviews.lazy.compactMap { find($0) }.first
            }
            return find(hosting)
        }
        func tabRects() throws -> [NSRect] {
            try store.state.layout.currentTabs.map { tab in
                let view = try XCTUnwrap(region("workspace-tab-" + tab.id))
                return view.convert(view.bounds, to: hosting)
            }
        }
        func assertVisibleTabs(_ count: Int, file: StaticString = #filePath, line: UInt = #line) throws {
            let header = try XCTUnwrap(region("workspace-header"), file: file, line: line)
            let palette = try XCTUnwrap(region("command-palette-button"), file: file, line: line)
            let headerRect = header.convert(header.bounds, to: hosting)
            let paletteRect = palette.convert(palette.bounds, to: hosting)
            let rects = try tabRects()
            XCTAssertEqual(rects.count, count, file: file, line: line)
            for rect in rects {
                XCTAssertGreaterThan(rect.width, 0, file: file, line: line)
                XCTAssertTrue(headerRect.insetBy(dx: -1, dy: -1).contains(rect), "Tab outside header: \(rect)", file: file, line: line)
                XCTAssertLessThanOrEqual(rect.maxX, paletteRect.minX, file: file, line: line)
            }
            for (left, right) in zip(rects, rects.dropFirst()) {
                XCTAssertLessThanOrEqual(left.maxX, right.minX + 1, file: file, line: line)
            }
        }
        func close() {
            window.contentView = nil; window.close(); store.terminalViews.removeAll()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
