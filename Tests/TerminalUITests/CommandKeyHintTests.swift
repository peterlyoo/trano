import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class CommandKeyHintTests: XCTestCase {
    // Implements: FR-NAV-2, U03, U09
    @MainActor func testHoldThresholdAndEarlyReleaseCancelPendingHints() {
        let scheduler = HintScheduler()
        var states: [Bool] = []
        let hints = CommandKeyHints(schedule: scheduler.schedule, onChange: { states.append($0) })
        hints.flagsChanged(.command, eligible: { true })
        XCTAssertFalse(hints.isVisible)
        XCTAssertEqual(scheduler.jobs.count, 1)
        XCTAssertEqual(scheduler.jobs[0].delay, 0.4, accuracy: 0.001)
        hints.flagsChanged([], eligible: { true })
        XCTAssertTrue(scheduler.jobs[0].cancelled)
        scheduler.jobs[0].fire()
        XCTAssertFalse(hints.isVisible)
        XCTAssertTrue(states.isEmpty)

        hints.flagsChanged(.command, eligible: { true })
        scheduler.jobs[1].fire()
        XCTAssertTrue(hints.isVisible)
        hints.flagsChanged([], eligible: { true })
        XCTAssertFalse(hints.isVisible)
        XCTAssertEqual(states, [true, false])
    }

    // Implements: FR-NAV-2, U03, U09
    @MainActor func testModifierCombinationAndShortcutSuppressUntilCommandRelease() {
        let scheduler = HintScheduler()
        let hints = CommandKeyHints(schedule: scheduler.schedule, onChange: { _ in })
        hints.flagsChanged([.command, .shift], eligible: { true })
        hints.flagsChanged(.command, eligible: { true })
        XCTAssertTrue(scheduler.jobs.isEmpty)
        hints.flagsChanged([], eligible: { true })
        hints.flagsChanged(.command, eligible: { true })
        hints.interrupt()
        scheduler.jobs[0].fire()
        XCTAssertFalse(hints.isVisible)
        hints.flagsChanged(.command, eligible: { true })
        XCTAssertEqual(scheduler.jobs.count, 1)
        hints.flagsChanged([], eligible: { true })
        hints.flagsChanged(.command, eligible: { true })
        scheduler.jobs[1].fire()
        XCTAssertTrue(hints.isVisible)
        hints.flagsChanged([.command, .option], eligible: { true })
        XCTAssertFalse(hints.isVisible)
    }

    // Implements: FR-NAV-2, U03, U09
    @MainActor func testEligibilityIsRecheckedAndStaleCallbacksCannotReshowHints() {
        let scheduler = HintScheduler()
        var eligible = true
        let hints = CommandKeyHints(schedule: scheduler.schedule, onChange: { _ in })
        hints.flagsChanged(.command, eligible: { eligible })
        eligible = false
        scheduler.jobs[0].fire()
        XCTAssertFalse(hints.isVisible)
        hints.cancel()
        eligible = true
        hints.flagsChanged(.command, eligible: { eligible })
        hints.cancel()
        hints.flagsChanged(.command, eligible: { eligible })
        scheduler.jobs[1].fire()
        XCTAssertFalse(hints.isVisible)
        scheduler.jobs[2].fire()
        XCTAssertTrue(hints.isVisible)
    }

    // Implements: FR-NAV-2, U09
    @MainActor func testHintNumbersMatchFirstEightAndLastTabDispatch() {
        XCTAssertEqual(CommandKeyHints.label(for: 0, count: 1), "⌘1")
        XCTAssertEqual((0..<9).map { CommandKeyHints.label(for: $0, count: 9) }, (1...9).map { "⌘\($0)" })
        XCTAssertEqual((0..<8).map { CommandKeyHints.label(for: $0, count: 12) }, (1...8).map { "⌘\($0)" })
        XCTAssertNil(CommandKeyHints.label(for: 8, count: 12))
        XCTAssertNil(CommandKeyHints.label(for: 9, count: 12))
        XCTAssertNil(CommandKeyHints.label(for: 10, count: 12))
        XCTAssertEqual(CommandKeyHints.label(for: 11, count: 12), "⌘9")
        XCTAssertNil(CommandKeyHints.label(for: -1, count: 3))
        XCTAssertNil(CommandKeyHints.label(for: 3, count: 3))
    }

    // Implements: FR-NAV-2, FR-NAV-6, U03, U09
    @MainActor func testNativeHoldBadgesPreserveTabAndTerminalGeometryAndDismiss() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let ids = fixture.store.state.layout.currentTabs.map(\.id)
        let before = try ids.map { id in
            let view = try XCTUnwrap(region("workspace-tab-" + id, in: fixture.hosting))
            return view.convert(view.bounds, to: fixture.hosting)
        }
        let closeBefore = try ids.map { id in
            let view = try XCTUnwrap(region("tab-close-" + id, in: fixture.hosting))
            return view.convert(view.bounds, to: fixture.hosting)
        }
        let workspace = try XCTUnwrap(region("terminal-workspace", in: fixture.hosting))
        let viewport = workspace.bounds
        let layout = fixture.store.state.layout
        XCTAssertFalse(fixture.delegate.handle(try flags(.command, window: fixture.window)))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(fixture.store.tabShortcutHintsVisible)
        try await Task.sleep(for: .milliseconds(350))
        fixture.hosting.layoutSubtreeIfNeeded()
        XCTAssertTrue(fixture.store.tabShortcutHintsVisible)
        for (index, id) in ids.enumerated() {
            let hint = try XCTUnwrap(region("tab-shortcut-" + id, in: fixture.hosting))
            XCTAssertEqual(hint.accessibilityLabel(), "⌘\(index + 1)")
            let close = try XCTUnwrap(region("tab-close-" + id, in: fixture.hosting))
            let closeRect = close.convert(close.bounds, to: fixture.hosting)
            XCTAssertEqual(closeRect, closeBefore[index])
            XCTAssertFalse(hint.convert(hint.bounds, to: fixture.hosting).intersects(closeRect))
            let tab = try XCTUnwrap(region("workspace-tab-" + id, in: fixture.hosting))
            XCTAssertEqual(tab.convert(tab.bounds, to: fixture.hosting), before[index])
        }
        XCTAssertEqual(workspace.bounds, viewport)
        XCTAssertEqual(fixture.store.state.layout, layout)
        XCTAssertFalse(fixture.delegate.handle(try flags([], window: fixture.window)))
        XCTAssertFalse(fixture.store.tabShortcutHintsVisible)
        fixture.delegate.commandHintWindowIsActive = { _ in false }
        XCTAssertFalse(fixture.delegate.handle(try flags(.command, window: fixture.window)))
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(fixture.store.tabShortcutHintsVisible)
    }

    // Implements: FR-NAV-2, U03, U09
    @MainActor func testNativeTextEditingAndIMECompositionSuppressHints() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let field = NSTextField(string: "Find")
        field.frame = NSRect(x: 100, y: 100, width: 200, height: 24)
        fixture.hosting.addSubview(field)
        XCTAssertTrue(fixture.window.makeFirstResponder(field))
        _ = fixture.delegate.handle(try flags(.command, window: fixture.window))
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(fixture.store.tabShortcutHintsVisible)
        _ = fixture.delegate.handle(try flags([], window: fixture.window))
        field.removeFromSuperview()
        let terminal = try XCTUnwrap(fixture.store.focusedID.flatMap { fixture.store.terminalViews[$0] })
        XCTAssertTrue(fixture.window.makeFirstResponder(terminal))
        terminal.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(terminal.hasMarkedText())
        _ = fixture.delegate.handle(try flags(.command, window: fixture.window))
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(fixture.store.tabShortcutHintsVisible)
        terminal.unmarkText()
    }

    // Implements: FR-NAV-2, U03, U09
    @MainActor func testNativeOwnerLossAndPickerOpeningCancelVisibleHints() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        for cancel in [
            { fixture.delegate.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: fixture.window)) },
            { fixture.delegate.applicationDidResignActive(Notification(name: NSApplication.didResignActiveNotification)) },
            { fixture.store.picker = .sessions },
            { fixture.store.showSettings = true }
        ] {
            _ = fixture.delegate.handle(try flags([], window: fixture.window))
            _ = fixture.delegate.handle(try flags(.command, window: fixture.window))
            try await Task.sleep(for: .milliseconds(450))
            XCTAssertTrue(fixture.store.tabShortcutHintsVisible)
            cancel()
            XCTAssertFalse(fixture.store.tabShortcutHintsVisible)
            fixture.store.picker = nil
            fixture.store.showSettings = false
        }
    }

    @MainActor private func flags(_ flags: NSEvent.ModifierFlags, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
    }

    @MainActor private func region(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.region(id, in: $0) }.first
    }

    @MainActor private func makeFixture() async throws -> Fixture {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-hints-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let store = AppStore(runtime: runtime)
        let deadline = Date().addingTimeInterval(3)
        while store.loading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.loading)
        for index in 1...3 {
            let id = UUID().uuidString.lowercased()
            store.state.layout.addTab(paneID: id)
            store.sessions.append(TerminalSession(id: id, title: "Tab \(index)", cwd: root.path, pid: 0, alive: false))
            store.terminalViews[id] = TranoView(frame: .zero)
        }
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 700), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let hosting = NSHostingView(rootView: WorkspaceView(store: store))
        window.contentView = hosting
        window.orderFrontRegardless()
        let delegate = ApplicationDelegate()
        delegate.window = window; delegate.store = store; delegate.windows[window] = store
        delegate.commandHintWindowIsActive = { _ in true }
        store.isActiveWindow = { true }
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        return Fixture(root: root, store: store, window: window, hosting: hosting, delegate: delegate)
    }

    @MainActor private func dispose(_ fixture: Fixture) {
        fixture.store.commandKeyHints.cancel()
        fixture.store.terminalViews.removeAll()
        fixture.window.close()
        try? FileManager.default.removeItem(at: fixture.root)
    }

    private struct Fixture {
        let root: URL
        let store: AppStore
        let window: NSWindow
        let hosting: NSHostingView<WorkspaceView>
        let delegate: ApplicationDelegate
    }
}

@MainActor private final class HintScheduler {
    final class Job {
        let delay: TimeInterval
        let action: () -> Void
        var cancelled = false
        init(delay: TimeInterval, action: @escaping () -> Void) { self.delay = delay; self.action = action }
        func fire() { action() }
    }
    var jobs: [Job] = []
    func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void {
        let job = Job(delay: delay, action: action)
        jobs.append(job)
        return { job.cancelled = true }
    }
}
