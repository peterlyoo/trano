import AppKit
import XCTest
@testable import TerminalCore
@testable import SwiftTerm
@testable import TranoApp

@MainActor final class SplitPanePointerCopyTests: XCTestCase {
    func testWheelHitTestingUsesThePaneUnderPointerInFlippedContent() throws {
        let f = try Fixture(); defer { f.close() }
        for view in [f.upper, f.lower] {
            let point = view.convert(NSPoint(x: 100, y: 80), to: nil)
            XCTAssertTrue(TerminalPointerInput.historyWheelTarget(in: f.window, location: point, store: f.store) === view)
        }
    }

    func testWheelDoesNotRetargetAControlOverlayToThePaneBehindIt() throws {
        let f = try Fixture(); defer { f.close() }
        let button = NSButton(frame: NSRect(x: 10, y: 250, width: 150, height: 30))
        f.content.addSubview(button)
        let point = button.convert(NSPoint(x: 40, y: 10), to: nil)
        XCTAssertNil(TerminalPointerInput.historyWheelTarget(in: f.window, location: point, store: f.store))
    }

    func testDragSelectionThenCommandCCopiesOnlyTheLowerPane() throws {
        let f = try Fixture(); defer { f.close() }
        f.upper.feed(text: "UPPER_ALPHA_BETA")
        f.lower.feed(text: "LOWER_GAMMA_DELTA")
        XCTAssertTrue(f.window.makeFirstResponder(f.lower))
        let down = try f.mouse(.leftMouseDown, view: f.lower, column: 0.1)
        XCTAssertFalse(f.delegate.handle(down))
        f.lower.mouseDown(with: down)
        f.lower.mouseDragged(with: try f.mouse(.leftMouseDragged, view: f.lower, column: 5.5))
        f.lower.mouseUp(with: try f.mouse(.leftMouseUp, view: f.lower, column: 5.5))
        let selected = try XCTUnwrap(f.lower.getSelection())
        XCTAssertTrue(selected.hasPrefix("LOWER"), selected)
        XCTAssertEqual(f.store.focusedID, f.lower.paneID)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 2, windowNumber: f.window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        XCTAssertTrue(f.delegate.handle(key))
        XCTAssertEqual(f.pasteboard.string(forType: .string), selected)
        XCTAssertEqual(f.lower.getSelection(), selected)
        XCTAssertNil(f.upper.getSelection())
    }

    func testCommandClickOSC8WebLinkInLowerPaneUsesActualTarget() throws {
        let f = try Fixture(); defer { f.close() }
        f.lower.feed(text: "한글 \u{1b}]8;;https://example.com/target?q=1\u{1b}\\문서\u{1b}]8;;\u{1b}\\")
        let point = f.cellPoint(column: 5.5, in: f.lower)
        XCTAssertEqual(f.lower.link(atViewPoint: point), "https://example.com/target?q=1")
        XCTAssertTrue(f.window.makeFirstResponder(f.lower))
        let down = try f.mouse(.leftMouseDown, view: f.lower, column: 5.5, flags: .command)
        XCTAssertFalse(f.delegate.handle(down))
        f.lower.mouseDown(with: down)
        f.lower.mouseUp(with: try f.mouse(.leftMouseUp, view: f.lower, column: 5.5, flags: .command))
        XCTAssertEqual(f.opened.map(\.absoluteString), ["https://example.com/target?q=1"])
    }

    func testCommandClickImplicitWebLinkInLowerPaneUsesNativeGrid() throws {
        let f = try Fixture(); defer { f.close() }
        f.lower.feed(text: "한글 https://example.com/implicit")
        XCTAssertTrue(f.window.makeFirstResponder(f.lower))
        let down = try f.mouse(.leftMouseDown, view: f.lower, column: 8.5, flags: .command)
        XCTAssertFalse(f.delegate.handle(down))
        f.lower.mouseDown(with: down)
        f.lower.mouseUp(with: try f.mouse(.leftMouseUp, view: f.lower, column: 8.5, flags: .command))
        XCTAssertEqual(f.opened.map(\.absoluteString), ["https://example.com/implicit"])
    }

    func testPlainDragAndCopyInAlternateScreenWithoutMouseReporting() throws {
        let f = try Fixture(); defer { f.close() }
        f.lower.feed(text: "\u{1b}[?1049hLOWER_GAMMA_DELTA")
        try dragAndCopy(f)
    }

    func testPlainDragRemainsCopyableWhenApplicationEnablesMouseReporting() async throws {
        for agent in [AgentKind.claude, .codex] {
            for mode in [1000, 1002, 1003] {
                let f = try Fixture(); defer { f.close() }
                f.store.sessions[1].agent = agent
                f.lower.feed(text: "\u{1b}[?1049h\u{1b}[?" + String(mode) + "h\u{1b}[?1006hLOWER_GAMMA_DELTA")
                let reports = SwiftTerm.Locked<[[UInt8]]>([])
                let delivered = expectation(description: "Native mouse press and release")
                delivered.expectedFulfillmentCount = 2
                delivered.assertForOverFulfill = true
                f.lower.setProcessInputHandler { bytes, _, _ in
                    guard String(decoding: bytes, as: UTF8.self).hasPrefix("\u{1b}[<") else { return }
                    reports.withLock { $0.append(bytes) }
                    delivered.fulfill()
                }
                try dragAndCopy(f)
                await fulfillment(of: [delivered], timeout: 2)
                XCTAssertTrue(f.lower.allowMouseReporting)
                XCTAssertNotEqual(f.lower.terminalInputStateSnapshot()?.mouseMode, Terminal.MouseMode.off)
                let mouseReports = reports.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }
                    .filter { $0.hasPrefix("\u{1b}[<") }
                XCTAssertEqual(mouseReports.count, 2)
                XCTAssertTrue(mouseReports.first?.hasSuffix("M") == true)
                XCTAssertTrue(mouseReports.last?.hasSuffix("m") == true)
            }
        }
    }

    func testSubcellLayoutResizePreservesDragSelectionForCommandCopy() throws {
        let f = try Fixture(); defer { f.close() }
        f.lower.feed(text: "LOWER_GAMMA_DELTA")
        try drag(f)
        let selected = try XCTUnwrap(f.lower.getSelection())
        let before = f.lower.terminalStateSnapshot()
        f.lower.setFrameSize(NSSize(width: f.lower.frame.width + 0.25, height: f.lower.frame.height))
        XCTAssertEqual(f.lower.terminalStateSnapshot().dimensions.cols, before.dimensions.cols)
        XCTAssertEqual(f.lower.terminalStateSnapshot().dimensions.rows, before.dimensions.rows)
        XCTAssertEqual(f.lower.getSelection(), selected)
        XCTAssertTrue(f.delegate.handle(try copyKey(f)))
        XCTAssertEqual(f.pasteboard.string(forType: .string), selected)
    }

    func testCopyUsesNativeSelectionOwnerWhenStoredFocusedPaneLags() throws {
        let f = try Fixture(); defer { f.close() }
        f.lower.feed(text: "LOWER_GAMMA_DELTA")
        try drag(f)
        let selected = try XCTUnwrap(f.lower.getSelection())
        try f.store.state.layout.focusPane(f.upper.paneID)
        XCTAssertTrue(f.window.firstResponder === f.lower)
        XCTAssertTrue(f.delegate.handle(try copyKey(f)))
        XCTAssertEqual(f.pasteboard.string(forType: .string), selected)
    }

    func testNativeFieldEditorRetainsCommandCopyInsteadOfTerminalSelection() throws {
        let f = try Fixture(); defer { f.close() }
        f.lower.feed(text: "LOWER_GAMMA_DELTA")
        try drag(f)
        let editor = NSTextView(frame: NSRect(x: 200, y: 250, width: 200, height: 60))
        editor.isFieldEditor = true
        f.content.addSubview(editor)
        XCTAssertTrue(f.window.makeFirstResponder(editor))
        XCTAssertFalse(f.delegate.handle(try copyKey(f)))
        XCTAssertNil(f.pasteboard.string(forType: .string))
    }

    func testGenericK9sMouseReportingStillReceivesPressDragAndRelease() async throws {
        let f = try Fixture(); defer { f.close() }
        f.store.sessions[1].foregroundProgram = .k9s
        f.lower.feed(text: "\u{1b}[?1049h\u{1b}[?1002h\u{1b}[?1006hLOWER_GAMMA_DELTA")
        let reports = SwiftTerm.Locked<[[UInt8]]>([])
        let delivered = expectation(description: "Native application mouse press, drag and release")
        delivered.expectedFulfillmentCount = 3
        delivered.assertForOverFulfill = true
        f.lower.setProcessInputHandler { bytes, _, _ in
            guard String(decoding: bytes, as: UTF8.self).hasPrefix("\u{1b}[<") else { return }
            reports.withLock { $0.append(bytes) }
            delivered.fulfill()
        }
        try drag(f)
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertNil(f.lower.getSelection())
        let packets = reports.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }
        XCTAssertEqual(packets.count, 3)
        XCTAssertTrue(packets.first?.hasSuffix("M") == true)
        XCTAssertTrue(packets.contains { $0.hasPrefix("\u{1b}[<32;") })
        XCTAssertTrue(packets.last?.hasSuffix("m") == true)
        XCTAssertTrue(f.lower.allowMouseReporting)
    }

    func testDisabledCopyBindingDoesNotBypassTheConfiguredShortcutMap() throws {
        let f = try Fixture(); defer { f.close() }
        f.lower.feed(text: "LOWER_GAMMA_DELTA")
        try drag(f)
        f.store.state.settings.keyBindings[ActionID.copy.rawValue] = []
        f.delegate.observeSettings(f.store, window: f.window)
        XCTAssertFalse(f.delegate.handle(try copyKey(f)))
        XCTAssertNil(f.pasteboard.string(forType: .string))
    }

    private func drag(_ f: Fixture) throws {
        XCTAssertTrue(f.window.makeFirstResponder(f.lower))
        let down = try f.mouse(.leftMouseDown, view: f.lower, column: 0.1)
        XCTAssertFalse(f.delegate.handle(down))
        f.lower.mouseDown(with: down)
        f.lower.mouseDragged(with: try f.mouse(.leftMouseDragged, view: f.lower, column: 5.5))
        f.lower.mouseUp(with: try f.mouse(.leftMouseUp, view: f.lower, column: 5.5))
    }

    private func dragAndCopy(_ f: Fixture) throws {
        try drag(f)
        let selected = try XCTUnwrap(f.lower.getSelection())
        XCTAssertTrue(selected.hasPrefix("LOWER"), selected)
        XCTAssertTrue(f.delegate.handle(try copyKey(f)))
        XCTAssertEqual(f.pasteboard.string(forType: .string), selected)
    }

    private func copyKey(_ f: Fixture) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 2, windowNumber: f.window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
    }

    @MainActor private final class FlippedContent: NSView {
        override var isFlipped: Bool { true }
    }
    @MainActor private final class Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let store: AppStore
        let upper: TranoView
        let lower: TranoView
        let content: NSView
        let window: NSWindow
        let delegate = ApplicationDelegate()
        let bridges: [TerminalBridge]
        let pasteboard: NSPasteboard
        var opened: [URL] = []
        init() throws {
            _ = NSApplication.shared
            let directory = URL(fileURLWithPath: "/tmp/trano-split-pointer-" + UUID().uuidString.prefix(8))
            root = directory
            runtime = try TerminalRuntime(root: directory)
            let ids = [UUID().uuidString.lowercased(), UUID().uuidString.lowercased()]
            let rows = ids.map { TerminalSession(id: $0, title: "Fixture", cwd: directory.path, pid: 0, alive: false) }
            var layout = WorkspaceLayout()
            _ = layout.addWorkspace(title: "fixture-session")
            let tab = layout.addTab(paneID: ids[0])
            try layout.split(tabID: tab, paneID: ids[1], axis: .vertical)
            try layout.focusPane(ids[0])
            try runtime.update { $0.sessions = rows; $0.layout = layout; $0.settings.automaticRestore = false }
            store = AppStore(runtime: runtime, startServices: false)
            store.state = try runtime.state(); store.sessions = rows
            store.terminalPreferences.copyOnSelection = false
            store.terminalPreferences.animateCopy = false
            content = FlippedContent(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
            upper = TranoView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
            lower = TranoView(frame: NSRect(x: 0, y: 200, width: 800, height: 200))
            pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.trano.split-copy." + UUID().uuidString))
            for (view, id) in zip([upper, lower], ids) {
                view.paneID = id; view.store = store
                view.frameDriver.invalidate()
                view.terminalInteractionPasteboard = pasteboard
                store.terminalViews[id] = view
                content.addSubview(view)
            }
            bridges = [TerminalBridge(view: upper), TerminalBridge(view: lower)]
            upper.terminalDelegate = bridges[0]; lower.terminalDelegate = bridges[1]
            window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 800, height: 400),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.animationBehavior = .none
            window.contentView = content; window.orderFrontRegardless()
            delegate.window = window; delegate.store = store; delegate.windows[window] = store
            delegate.observeSettings(store, window: window)
            lower.terminalInteractionOpener = { [weak self] in self?.opened.append($0) }
            upper.terminalInteractionOpener = { [weak self] in self?.opened.append($0) }
        }
        func cellPoint(column: CGFloat, in view: TranoView) -> NSPoint {
            NSPoint(x: column * view.cellDimension.width, y: view.bounds.height - view.cellDimension.height * 0.5)
        }
        func mouse(_ type: NSEvent.EventType, view: TranoView, column: CGFloat, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(cellPoint(column: column, in: view), to: nil), modifierFlags: flags,
                timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        func close() {
            for view in [upper, lower] { view.invalidateTerminalInteractions(); view.terminalDelegate = nil }
            store.terminalViews.removeAll(); window.contentView = nil; window.close()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
