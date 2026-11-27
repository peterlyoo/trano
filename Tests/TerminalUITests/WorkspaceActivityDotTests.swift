import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

@MainActor final class WorkspaceActivityDotTests: XCTestCase {
    // Implements: FR-NAV-6, FR-NAV-8
    func testNewSessionIsFixedImmediatelyAboveRemoteHostWithKeyboardAndSearchPreserved() async throws {
        for compact in [true, false] {
            let f = try Fixture(compact: compact); defer { f.close() }
            try await layout(f)
            let field = try XCTUnwrap(region("picker-search-field", in: f.host) as? NSTextField)
            XCTAssertTrue(f.window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            for _ in f.store.state.layout.workspaces.filter({ !$0.closed }) {
                editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
            }
            try await layout(f)
            XCTAssertEqual(selectedTitle(f), "New Session")
            let selected = try XCTUnwrap(region("picker-selected-command", in: f.host))
            let results = try XCTUnwrap(region("picker-results", in: f.host))
            let selectedRect = selected.convert(selected.bounds, to: f.host)
            let resultsRect = results.convert(results.bounds, to: f.host)
            func top(_ rect: NSRect) -> CGFloat { f.host.isFlipped ? rect.minY : f.host.bounds.maxY - rect.maxY }
            XCTAssertGreaterThanOrEqual(top(selectedRect), top(resultsRect) + resultsRect.height,
                                        "New Session must be outside the scrollable workspace rows")
            let newSession = try XCTUnwrap(region("picker-new-session-footer", in: f.host))
            let remote = try XCTUnwrap(region("picker-add-remote-host-footer", in: f.host))
            let newRect = newSession.convert(newSession.bounds, to: f.host)
            let remoteRect = remote.convert(remote.bounds, to: f.host)
            XCTAssertEqual(top(remoteRect), top(newRect) + newRect.height, accuracy: 1)
            XCTAssertTrue(f.host.bounds.contains(remoteRect))
            editor.insertText("fresh-workspace", replacementRange: editor.selectedRange())
            try await layout(f)
            XCTAssertEqual(editor.string, "fresh-workspace")
            XCTAssertEqual(selectedTitle(f), "Create “fresh-workspace”")
            XCTAssertNotNil(region("picker-new-session-footer", in: f.host))
            XCTAssertTrue(f.window.firstResponder === editor)
            try assertDiskUnchanged(f)
        }
    }

    // Implements: FR-WSACT-1, FR-WSACT-2
    func testWorkspaceMembershipFollowsLiveSplitPanesAndExcludesDetachedClosedMissingAndDeadPanes() async throws {
        let f = try Fixture(); defer { f.close() }
        try await layout(f)
        XCTAssertNotNil(dot(f.alpha, in: f))
        XCTAssertNil(dot(f.beta, in: f))
        XCTAssertNil(dot(f.empty, in: f))
        XCTAssertEqual(dots(in: f.host).count, 1)
        let tabIndex = try XCTUnwrap(f.store.state.layout.tabs.firstIndex { $0.id == f.activeTab })
        f.store.state.layout.tabs[tabIndex].workspaceID = f.beta
        try await layout(f)
        XCTAssertNil(dot(f.alpha, in: f))
        XCTAssertNotNil(dot(f.beta, in: f))
        XCTAssertEqual(dots(in: f.host).count, 1)
        let removed = f.store.state.layout.tabs.remove(at: tabIndex)
        f.store.state.layout.closedTabs.append(removed)
        try await layout(f)
        XCTAssertTrue(dots(in: f.host).isEmpty)
        XCTAssertEqual(selectedTitle(f), "Team Alpha")
        try assertDiskUnchanged(f)
    }

    // Implements: FR-WSACT-1, FR-WSACT-2, FR-WSACT-3
    func testLiveActivityAndReadReceiptUpdatesPreserveFilteredEditorAndSelectedWorkspace() async throws {
        let f = try Fixture(); defer { f.close() }
        try await layout(f)
        let field = try XCTUnwrap(region("picker-search-field", in: f.host) as? NSTextField)
        XCTAssertTrue(f.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("Team", replacementRange: editor.selectedRange())
        try await layout(f)
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        try await layout(f)
        XCTAssertEqual(selectedTitle(f), "Team Beta")
        let index = try XCTUnwrap(f.store.sessions.firstIndex { $0.id == f.activePane })
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        for state in [ActivityState.blocked, .error, .done] {
            f.store.sessions[index].activity.state = state
            f.store.sessions[index].activity.updatedAt = timestamp
            f.store.state.activityReadAt[f.activePane] = timestamp.addingTimeInterval(-1)
            try await layout(f)
            XCTAssertNotNil(dot(f.alpha, in: f), "Unread \(state) must light its workspace")
            f.store.state.activityReadAt[f.activePane] = timestamp
            try await layout(f)
            XCTAssertNil(dot(f.alpha, in: f), "Observed activity must clear its unread dot regardless of status")
            XCTAssertNil(dot(f.beta, in: f))
            assertInput(f, field: field, editor: editor)
        }
        f.store.sessions[index].activity.updatedAt = timestamp.addingTimeInterval(1)
        try await layout(f)
        XCTAssertNotNil(dot(f.alpha, in: f), "A newer completion becomes unread")
        for state in [ActivityState.running, .idle, .unknown] {
            f.store.sessions[index].activity.state = state
            try await layout(f)
            XCTAssertNil(dot(f.alpha, in: f))
            assertInput(f, field: field, editor: editor)
        }
        f.store.sessions[index].activity.state = .blocked
        f.store.sessions[index].alive = false
        try await layout(f)
        XCTAssertNil(dot(f.alpha, in: f), "Dead panes cannot light their workspace")
        f.store.sessions[index].alive = true
        try await layout(f)
        XCTAssertNotNil(dot(f.alpha, in: f))
        f.store.sessions.remove(at: index)
        try await layout(f)
        XCTAssertNil(dot(f.alpha, in: f), "A persisted but missing live pane cannot light its workspace")
        assertInput(f, field: field, editor: editor)
        try assertDiskUnchanged(f)
    }

    // Implements: FR-WSACT-1, FR-WSACT-3
    func testMountedDotIsSixPointsBesideTheTitleWithoutAHitTargetOrAccessibilityText() async throws {
        for compact in [true, false] {
            let f = try Fixture(compact: compact); defer { f.close() }
            try await layout(f)
            let dot = try XCTUnwrap(dot(f.alpha, in: f))
            let title = try XCTUnwrap(region("picker-workspace-title-" + f.alpha, in: f.host))
            let dotRect = dot.convert(dot.bounds, to: f.host)
            let titleRect = title.convert(title.bounds, to: f.host)
            XCTAssertEqual(dot.bounds.width, 6, accuracy: 0.1)
            XCTAssertEqual(dot.bounds.height, 6, accuracy: 0.1)
            XCTAssertGreaterThanOrEqual(dotRect.minX - titleRect.maxX, 3)
            XCTAssertLessThanOrEqual(dotRect.minX - titleRect.maxX, 8)
            XCTAssertEqual(dotRect.midY, titleRect.midY, accuracy: 1)
            XCTAssertTrue(f.host.bounds.contains(dotRect))
            XCTAssertNil(dot.hitTest(NSPoint(x: dot.bounds.midX, y: dot.bounds.midY)))
            XCTAssertFalse(dot.isAccessibilityElement())
            XCTAssertTrue((dot.accessibilityLabel() ?? "").isEmpty)
            XCTAssertEqual(selectedTitle(f), "Team Alpha")
            XCTAssertNotNil(region("picker-workspace-context-" + f.alpha, in: f.host))
            XCTAssertNotNil(region("picker-workspace-close-" + f.alpha, in: f.host))
            try assertPaintedDot(dot, accent: f.store.toolPanelTheme.accentNS)
            f.store.state.layout.workspaces[0].title = String(repeating: "A long workspace title ", count: 8)
            try await layout(f)
            let truncatedDot = try XCTUnwrap(self.dot(f.alpha, in: f))
            XCTAssertTrue(f.host.bounds.contains(truncatedDot.convert(truncatedDot.bounds, to: f.host)))
            XCTAssertEqual(truncatedDot.bounds.width, 6, accuracy: 0.1)
            XCTAssertEqual(selectedTitle(f), f.store.state.layout.workspaces[0].title)
            try assertDiskUnchanged(f)
        }
    }

    @MainActor private final class Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let store: AppStore
        let window: NSWindow
        let host: NSHostingView<PickerView>
        let alpha: String
        let beta: String
        let empty: String
        let activePane: String
        let activeTab: String
        let diskBefore: Data

        init(compact: Bool = true) throws {
            _ = NSApplication.shared
            let fixtureRoot = URL(fileURLWithPath: "/tmp/trano-wad-" + UUID().uuidString.prefix(8))
            root = fixtureRoot
            runtime = try TerminalRuntime(root: fixtureRoot)
            func pane(_ state: ActivityState, alive: Bool = true) -> TerminalSession {
                var value = TerminalSession(id: UUID().uuidString.lowercased(), title: "Fixture", cwd: fixtureRoot.path, pid: 4711)
                value.activity.state = state; value.activity.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
                value.alive = alive
                return value
            }
            let idle = pane(.idle), unknown = pane(.unknown), active = pane(.done)
            let betaIdle = pane(.idle), dead = pane(.error, alive: false)
            let detached = pane(.blocked), closed = pane(.error), missing = pane(.running)
            activePane = active.id
            var layout = WorkspaceLayout()
            alpha = layout.addWorkspace(title: "Team Alpha")
            layout.addTab(paneID: idle.id)
            activeTab = layout.addTab(paneID: unknown.id)
            try layout.split(tabID: activeTab, paneID: active.id, axis: .horizontal)
            beta = layout.addWorkspace(title: "Team Beta")
            let betaTab = layout.addTab(paneID: betaIdle.id)
            try layout.split(tabID: betaTab, paneID: dead.id, axis: .vertical)
            layout.addTab(paneID: missing.id)
            let closedTab = layout.addTab(paneID: closed.id)
            let closedIndex = try XCTUnwrap(layout.tabs.firstIndex { $0.id == closedTab })
            layout.closedTabs.append(layout.tabs.remove(at: closedIndex))
            empty = layout.addWorkspace(title: "Empty")
            try layout.selectWorkspace(alpha)
            let live = [idle, unknown, active, betaIdle, dead, detached, closed]
            try runtime.update { state in
                state.settings.automaticRestore = false
                state.sessions = live + [missing]
                state.sessions[3].activity.state = .running
                state.layout = layout
            }
            let binding = SupervisorBinding(paneID: idle.id, backendPID: 4711,
                configuration: SupervisorConfiguration(provider: .claude, cwd: root.path))
            store = AppStore(runtime: runtime, externalBinding: binding)
            store.state = try runtime.state(); store.sessions = live; store.picker = .sessions
            diskBefore = try Self.diskSnapshot(runtime)
            host = NSHostingView(rootView: PickerView(store: store, kind: .sessions, compact: compact))
            window = NSWindow(contentRect: NSRect(x: -14000, y: -14000, width: compact ? 320 : 540, height: 440),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            window.orderFrontRegardless()
        }
        static func diskSnapshot(_ runtime: TerminalRuntime) throws -> Data {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(runtime.state())
        }
        func close() {
            store.picker = nil; window.contentView = nil; window.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func assertDiskUnchanged(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Fixture.diskSnapshot(f.runtime), f.diskBefore, "Picker display and filtering must never write runtime state", file: file, line: line)
        XCTAssertTrue(f.store.terminalViews.isEmpty, "This component fixture must not start terminal jobs", file: file, line: line)
    }
    private func assertInput(_ f: Fixture, field: NSTextField, editor: NSTextView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(f.store.picker, .sessions, file: file, line: line)
        XCTAssertEqual(editor.string, "Team", file: file, line: line)
        XCTAssertTrue(f.window.firstResponder === editor, file: file, line: line)
        XCTAssertTrue(field.currentEditor() === editor, file: file, line: line)
        XCTAssertEqual(selectedTitle(f), "Team Beta", file: file, line: line)
    }
    private func selectedTitle(_ f: Fixture) -> String? { region("picker-selected-command", in: f.host)?.accessibilityLabel() }
    private func dot(_ id: String, in f: Fixture) -> NSView? { region("picker-workspace-activity-" + id, in: f.host) }
    private func dots(in view: NSView) -> [NSView] {
        (view.identifier?.rawValue.hasPrefix("picker-workspace-activity-") == true ? [view] : []) + view.subviews.flatMap { dots(in: $0) }
    }
    private func region(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.region(id, in: $0) }.first
    }
    private func layout(_ f: Fixture) async throws {
        f.host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        f.host.layoutSubtreeIfNeeded()
    }
    private func assertPaintedDot(_ dot: NSView, accent: NSColor) throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 12,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: 12, height: 12))
        context.cgContext.scaleBy(x: 2, y: 2)
        dot.draw(dot.bounds)
        let center = try XCTUnwrap(bitmap.colorAt(x: 6, y: 6)?.usingColorSpace(.deviceRGB))
        let expected = try XCTUnwrap(accent.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(center.alphaComponent, 0.7)
        XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0.2)
        XCTAssertEqual(center.redComponent, expected.redComponent, accuracy: 0.04)
        XCTAssertEqual(center.greenComponent, expected.greenComponent, accuracy: 0.04)
        XCTAssertEqual(center.blueComponent, expected.blueComponent, accuracy: 0.04)
    }
}
