import AppKit
import XCTest
@testable import SwiftTerm
@testable import TerminalCore
@testable import TranoApp

@MainActor final class SplitPaneClickFocusTests: XCTestCase {
    func testActivityDispatchAcceptsNativeNonKeyboardMonitorEvents() throws {
        let f = try Fixture(); defer { f.close() }
        try f.select(f.upper)
        let point = f.content.convert(NSPoint(x: 10, y: 10), to: nil)
        for activityVisible in [false, true] {
            f.store.showActivity = activityVisible
            for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved] {
                for modifiers in [NSEvent.ModifierFlags(), .command] {
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                        modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: f.window.windowNumber, context: nil, eventNumber: 1,
                        clickCount: type == .mouseMoved ? 0 : 1, pressure: 0))
                    XCTAssertFalse(f.delegate.handle(event),
                        "Native \(type) must reach pointer dispatch without reading keyboard-only properties")
                    XCTAssertEqual(f.store.showActivity, activityVisible)
                    XCTAssertEqual(f.store.focusedID, f.upper.paneID)
                    XCTAssertTrue(f.window.firstResponder === f.upper)
                }
            }
        }
        try f.assertNoJobs()
    }

    func testNativeInputPositiveControlCapturesBothInertRenderers() throws {
        let f = try Fixture(); defer { f.close() }
        for view in [f.upper, f.lower] {
            try f.select(view)
            XCTAssertTrue(f.window.firstResponder === view)
            try f.assertFirstKeyReaches(view)
        }
        try f.assertNoJobs()
    }

    func testNativeClickPositiveControlReachesOppositePaneSelection() throws {
        let f = try Fixture(); defer { f.close() }
        f.lower.feed(text: "LOWER_SELECTION_CONTROL")
        try f.select(f.upper)
        let point = f.lower.convert(NSPoint(x: f.lower.cellDimension.width * 2.5,
            y: f.lower.bounds.height - f.lower.cellDimension.height * 0.5), to: nil)
        XCTAssertTrue(try XCTUnwrap(f.hit(point)) === f.lower)
        f.window.sendEvent(try f.event(.leftMouseDown, point: point, clickCount: 2))
        f.window.sendEvent(try f.event(.leftMouseUp, point: point, clickCount: 2))
        XCTAssertTrue(try XCTUnwrap(f.lower.getSelection()).contains("LOWER"),
                      "An empty opposite-pane native selection invalidates click delivery")
        try f.assertNoJobs()
    }

    func testOppositePaneClicksAcquireLogicalNativeAndFirstByteOwnershipBothWays() async throws {
        let f = try Fixture(); defer { f.close() }
        for (source, target) in [(f.upper, f.lower), (f.lower, f.upper)] {
            try f.select(source)
            let point = f.center(target)
            XCTAssertTrue(try XCTUnwrap(f.hit(point)) === target)
            try f.click(point)
            XCTAssertEqual(f.store.focusedID, target.paneID)
            XCTAssertTrue(f.window.firstResponder === target,
                          "The actual opposite-pane click must transfer native input before the next key")
            try f.assertFirstKeyReaches(target)
            await f.drain()
            XCTAssertEqual(f.store.focusedID, target.paneID)
            XCTAssertTrue(f.window.firstResponder === target)
            XCTAssertEqual(try f.runtime.state().layout.tabs.first?.focusedPaneID, target.paneID)
        }
        try f.assertNoJobs()
    }

    func testPaneHeaderClickTransfersNativeAndFirstByteOwnershipImmediately() async throws {
        let f = try Fixture(); defer { f.close() }
        try f.select(f.upper)
        let header = PaneDragView(frame: NSRect(x: 40, y: 455, width: 300, height: 28))
        header.store = f.store; header.paneID = f.lower.paneID; header.title = "Lower pane"
        f.content.addSubview(header)
        let point = header.convert(NSPoint(x: 100, y: 14), to: nil)
        XCTAssertTrue(try XCTUnwrap(f.hit(point)) === header)
        try f.click(point)
        XCTAssertEqual(f.store.focusedID, f.lower.paneID)
        XCTAssertTrue(f.window.firstResponder === f.lower)
        try f.assertFirstKeyReaches(f.lower)
        await f.drain()
        XCTAssertEqual(try f.runtime.state().layout.focusedPaneID, f.lower.paneID)
        try f.assertNoJobs()
    }

    func testControlOverlayClickCannotFocusTerminalBehindIt() async throws {
        let f = try Fixture(); defer { f.close() }
        try f.select(f.upper)
        let control = ClickControl(frame: NSRect(x: 25, y: 25, width: 140, height: 40))
        f.lower.addSubview(control)
        let point = control.convert(NSPoint(x: 50, y: 20), to: nil)
        XCTAssertTrue(try XCTUnwrap(f.hit(point)) === control)
        try f.click(point)
        XCTAssertEqual(control.clicks, 1, "The native control must receive the click")
        XCTAssertEqual(f.store.focusedID, f.upper.paneID)
        XCTAssertTrue(f.window.firstResponder === f.upper)
        await f.drain()
        XCTAssertEqual(f.store.focusedID, f.upper.paneID)
        try f.assertNoJobs()
    }

    func testHiddenCachedOverlapCannotClaimVisiblePaneClick() async throws {
        let f = try Fixture(); defer { f.close() }
        try f.select(f.upper)
        let hiddenParent = FlippedContent(frame: f.content.bounds)
        hiddenParent.isHidden = true
        f.content.addSubview(hiddenParent)
        f.cached.removeFromSuperview()
        f.cached.frame = hiddenParent.bounds
        hiddenParent.addSubview(f.cached)
        let point = NSPoint(x: 10, y: 10)
        let windowPoint = f.content.convert(point, to: nil)
        XCTAssertFalse(f.hit(windowPoint) === f.cached)
        try f.click(windowPoint)
        XCTAssertEqual(f.store.focusedID, f.upper.paneID,
                       "A retained renderer hidden by its ancestor cannot select its cached tab")
        await f.drain()
        XCTAssertEqual(f.store.selectedTab?.id, f.selectedTabID)
        XCTAssertTrue(f.window.firstResponder === f.upper)
        try f.assertNoJobs()
    }

    func testVisibleCachedPaneOutsideSelectedTabCannotClaimClick() async throws {
        let f = try Fixture(); defer { f.close() }
        try f.select(f.upper)
        f.cached.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        f.content.addSubview(f.cached)
        let point = f.center(f.cached)
        XCTAssertTrue(try XCTUnwrap(f.hit(point)) === f.cached)
        XCTAssertFalse(f.store.selectedTab?.panes.contains(f.cached.paneID) == true)
        XCTAssertFalse(f.delegate.handle(try f.event(.leftMouseDown, point: point)))
        XCTAssertEqual(f.store.focusedID, f.upper.paneID)
        await f.drain()
        XCTAssertEqual(f.store.selectedTab?.id, f.selectedTabID)
        try f.assertNoJobs()
    }

    func testComposingNativeEditorRetainsPaneAndResponderDuringPointerMonitor() async throws {
        let f = try Fixture(); defer { f.close() }
        try f.select(f.upper)
        let editor = NSTextView(frame: NSRect(x: 20, y: 450, width: 200, height: 35))
        f.content.addSubview(editor)
        XCTAssertTrue(f.window.makeFirstResponder(editor))
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        defer { editor.unmarkText() }
        let marked = editor.markedRange(), text = editor.string
        XCTAssertFalse(f.delegate.handle(try f.event(.leftMouseDown, point: f.center(f.lower))))
        XCTAssertEqual(f.store.focusedID, f.upper.paneID)
        await f.drain()
        XCTAssertTrue(f.window.firstResponder === editor)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertEqual(editor.string, text)
        try f.assertNoJobs()
    }

    func testHigherOverlayRetainsInputOwnerBeforeOutsideDismissal() async throws {
        for overlay in ["activity", "picker", "decision", "queue", "settings", "voice", "remote", "accounts", "extensions"] {
            let f = try Fixture(); defer { f.close() }
            try f.select(f.upper)
            switch overlay {
            case "activity": f.store.showActivity = true
            case "picker": f.store.picker = .sessions
            case "decision": f.store.decisionPaneID = f.upper.paneID
            case "queue": f.store.followUpPaneID = f.upper.paneID
            case "settings": f.store.showSettings = true
            case "voice": f.store.showVoice = true
            case "remote": f.store.showRemoteHosts = true
            case "accounts": f.store.showAccounts = true
            default: f.store.showExtensions = true
            }
            _ = f.delegate.handle(try f.event(.leftMouseDown, point: f.center(f.lower)))
            XCTAssertEqual(f.store.focusedID, f.upper.paneID, overlay)
            XCTAssertTrue(f.window.firstResponder === f.upper, overlay)
            await f.drain()
            XCTAssertEqual(f.store.focusedID, f.upper.paneID, overlay)
            try f.assertNoJobs()
        }
    }

    func testAttachedSheetRetainsPaneDuringPointerMonitor() async throws {
        let f = try Fixture(); defer { f.close() }
        try f.select(f.upper)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        f.window.beginSheet(sheet, completionHandler: nil)
        defer { f.window.endSheet(sheet); sheet.close() }
        XCTAssertTrue(f.window.attachedSheet === sheet)
        XCTAssertFalse(f.delegate.handle(try f.event(.leftMouseDown, point: f.center(f.lower))))
        XCTAssertEqual(f.store.focusedID, f.upper.paneID)
        await f.drain()
        XCTAssertEqual(f.store.focusedID, f.upper.paneID)
        try f.assertNoJobs()
    }

    @MainActor private final class FlippedContent: NSView {
        override var isFlipped: Bool { true }
    }

    @MainActor private final class ClickControl: NSControl {
        var clicks = 0
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { clicks += 1 }
    }

    @MainActor private final class Fixture {
        let root: URL
        let backend = FakePaneBackend()
        let runtime: TerminalRuntime
        let store: AppStore
        let window: NSWindow
        let content: NSView
        let upper: TranoView
        let lower: TranoView
        let cached: TranoView
        let selectedTabID: String
        let sessions: [TerminalSession]
        let delegate = ApplicationDelegate()

        var views: [TranoView] { [upper, lower, cached] }

        init() throws {
            _ = NSApplication.shared
            let directory = URL(fileURLWithPath: "/tmp/t-pane-click-" + UUID().uuidString.prefix(8))
            root = directory
            runtime = try TerminalRuntime(root: directory)
            runtime.host = backend
            sessions = (0..<3).map { TerminalSession(id: UUID().uuidString.lowercased(),
                title: "Inert click \($0)", cwd: directory.path, pid: 0, alive: false) }
            var snapshot = RuntimeState()
            snapshot.settings.automaticRestore = false
            snapshot.sessions = sessions
            snapshot.layout.addWorkspace(title: "Inert pane click fixture")
            selectedTabID = snapshot.layout.addTab(paneID: sessions[0].id)
            try snapshot.layout.split(tabID: selectedTabID, paneID: sessions[1].id, axis: .vertical)
            _ = snapshot.layout.addTab(paneID: sessions[2].id)
            try snapshot.layout.focusPane(sessions[0].id)
            try runtime.update { $0 = snapshot }
            store = AppStore(runtime: runtime, startServices: false)
            store.state = snapshot; store.sessions = sessions
            store.interfacePreferences.animationStyle = .off
            content = FlippedContent(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
            let nested = FlippedContent(frame: NSRect(x: 30, y: 40, width: 740, height: 400))
            content.addSubview(nested)
            upper = TranoView.makeClipboardTerminal(frame: NSRect(x: 0, y: 0, width: 740, height: 190))
            lower = TranoView.makeClipboardTerminal(frame: NSRect(x: 0, y: 210, width: 740, height: 190))
            cached = TranoView.makeClipboardTerminal(frame: .zero)
            for (view, row) in zip([upper, lower, cached], sessions) {
                view.store = store; view.paneID = row.id
                view.frameDriver.invalidate()
                store.terminalViews[row.id] = view
            }
            nested.addSubview(upper); nested.addSubview(lower)
            window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 800, height: 500),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.animationBehavior = .none
            window.contentView = content; window.orderFrontRegardless()
            delegate.window = window; delegate.store = store; delegate.windows[window] = store
            delegate.observeSettings(store, window: window)
        }

        func select(_ view: TranoView) throws {
            try runtime.update { try $0.layout.focusPane(view.paneID) }
            try store.state.layout.focusPane(view.paneID)
            XCTAssertTrue(window.makeFirstResponder(view))
        }

        func center(_ view: NSView) -> NSPoint {
            view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        }

        func hit(_ point: NSPoint) -> NSView? {
            guard let frame = content.superview else { return nil }
            return frame.hitTest(frame.convert(point, from: nil))
        }

        func event(_ type: NSEvent.EventType, point: NSPoint, clickCount: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1))
        }

        func click(_ point: NSPoint) throws {
            let down = try event(.leftMouseDown, point: point)
            if !delegate.handle(down) { window.sendEvent(down) }
            window.sendEvent(try event(.leftMouseUp, point: point))
        }

        func assertFirstKeyReaches(_ target: TranoView) throws {
            let recorders = views.map { view in
                let bytes = SwiftTerm.Locked<[UInt8]>([])
                view.setProcessInputHandler { input, origin, _ in
                    if case .user = origin { bytes.withLock { $0.append(contentsOf: input) } }
                }
                return bytes
            }
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
            XCTAssertFalse(delegate.handle(event))
            window.firstResponder?.keyDown(with: event)
            for (view, bytes) in zip(views, recorders) {
                XCTAssertEqual(bytes.withLock { $0 }, view === target ? Array("a".utf8) : [],
                    "Only clicked pane \(target.paneID) may receive first native bytes; checked \(view.paneID)")
            }
        }

        func drain() async {
            for _ in 0..<3 {
                await withCheckedContinuation { continuation in
                    store.queue.async { DispatchQueue.main.async { continuation.resume() } }
                }
            }
        }

        func assertNoJobs(file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertTrue(views.allSatisfy { !$0.started && !$0.process.running }, file: file, line: line)
            XCTAssertEqual(try runtime.state().sessions, sessions, file: file, line: line)
            XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.host.socketPath), file: file, line: line)
            XCTAssertNil(store.message, file: file, line: line)
        }

        func close() {
            views.forEach { $0.frameDriver.invalidate(); $0.invalidateTerminalInteractions(); $0.terminalDelegate = nil }
            store.terminalViews.removeAll()
            window.contentView = nil; window.close()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
