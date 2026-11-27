import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import SwiftTerm
@testable import TranoApp

@MainActor final class ActivityNativeEventTests: XCTestCase {
    func testApplicationEscapePreservesActivityBehindSettingsAndMarkedEditor() async throws {
        for settings in [true, false] {
            let f = try Fixture(); defer { f.close() }
            _ = try await f.focusSearchEditor()
            f.delegate.performMenuAction(try f.activityMenuItem())
            await f.layout()
            _ = try f.activityOwner()
            if settings { f.store.showSettings = true }
            else {
                XCTAssertTrue(f.window.makeFirstResponder(f.search))
                let editor = try XCTUnwrap(f.search.currentEditor() as? NSTextView)
                editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                XCTAssertTrue(editor.hasMarkedText())
            }
            try f.installEventMonitor()
            NSApp.sendEvent(f.event(53, text: "\u{1b}"))
            XCTAssertGreaterThan(f.observedEvents, 0)
            XCTAssertEqual(f.activityAfterMonitor, [true], "The application handler must leave Activity open before native editor Escape handling")
            XCTAssertEqual(f.consumedEvents, 0, "Activity must yield Escape to the higher input owner")
            XCTAssertTrue(f.store.showActivity)
        }
    }

    func testApplicationNavigationYieldsToUnmarkedSearchEditorAheadOfActiveUnderlyingURLHints() async throws {
        let f = try Fixture(); defer { f.close() }
        await f.layout()
        let (terminal, bytes) = try f.installInertTerminal()
        terminal.keyDown(with: f.event(7, text: "x"))
        XCTAssertEqual(bytes.withLock { $0 }, Array("x".utf8))
        bytes.withLock { $0.removeAll() }
        terminal.feed(text: "\u{1b}[2J\u{1b}[Hhttps://example.test/activity-editor-owner")
        let deadline = Date().addingTimeInterval(2)
        while terminal.terminalContentSnapshot(region: .viewport)?.rows.first?.text.contains("https://") != true,
              Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(terminal.terminalContentSnapshot(region: .viewport)?.rows.first?.text.contains("https://") == true)
        f.delegate.performMenuAction(try f.activityMenuItem())
        await f.layout()
        _ = try f.activityOwner()
        let editor = try await f.focusSearchEditor()
        XCTAssertTrue(f.window.firstResponder === editor)
        XCTAssertTrue(editor.isFieldEditor)
        XCTAssertFalse(editor.hasMarkedText())
        var opened: [URL] = []
        terminal.urlHints.openURL = { opened.append($0) }
        XCTAssertTrue(terminal.urlHints.start())
        XCTAssertEqual(terminal.urlHints.matches.count, 1)
        XCTAssertTrue(terminal.urlHints.handle(f.event(36, text: "\r")))
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.test/activity-editor-owner"], "The competing hint callback must actually work before the safety check")
        opened.removeAll()
        XCTAssertTrue(terminal.urlHints.start())
        let selected = f.store.selectedActivityID
        try f.installEventMonitor()
        NSApp.sendEvent(f.event(125, text: "\u{f701}"))
        NSApp.sendEvent(f.event(36, text: "\r"))
        XCTAssertEqual(f.observedEvents, 2)
        XCTAssertEqual(f.consumedEvents, 0, "Activity and underlying URL hints must yield both keys to the current native editor")
        XCTAssertEqual(f.activityAfterMonitor, [true, true])
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(f.store.selectedActivityID, selected)
        XCTAssertTrue(f.store.showActivity)
        XCTAssertTrue(f.window.firstResponder === editor)
        XCTAssertTrue(bytes.withLock { $0.isEmpty })
        XCTAssertFalse(terminal.started)
        XCTAssertFalse(terminal.process.running)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.runtime.host.socketPath))
    }

    func testWindowlessNativeKeysNavigateAndEscapeReturnsTerminalTyping() async throws {
        let f = try Fixture(); defer { f.close() }
        await f.layout()
        let (terminal, bytes) = try f.installInertTerminal()
        terminal.keyDown(with: f.event(7, text: "x"))
        XCTAssertEqual(bytes.withLock { $0 }, Array("x".utf8))
        bytes.withLock { $0.removeAll() }
        f.delegate.performMenuAction(try f.activityMenuItem())
        await f.layout()
        let owner = try f.activityOwner()

        let down = f.event(125, text: "\u{f701}", inWindow: false)
        let up = f.event(126, text: "\u{f700}", inWindow: false)
        let escape = f.event(53, text: "\u{1b}", inWindow: false)
        XCTAssertNil(down.window)
        XCTAssertNil(up.window)
        XCTAssertNil(escape.window)
        owner.keyDown(with: down)
        XCTAssertEqual(f.store.selectedActivityID, f.rows[1].id)
        owner.keyDown(with: up)
        XCTAssertEqual(f.store.selectedActivityID, f.rows[0].id)
        owner.keyDown(with: escape)
        XCTAssertFalse(f.store.showActivity)
        await f.layout()
        XCTAssertTrue(f.window.firstResponder === terminal)
        XCTAssertTrue(bytes.withLock { $0.isEmpty })
        if f.window.firstResponder === terminal { terminal.keyDown(with: f.event(7, text: "x")) }
        XCTAssertEqual(bytes.withLock { $0 }, Array("x".utf8))
        XCTAssertFalse(terminal.started)
        XCTAssertFalse(terminal.process.running)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.runtime.host.socketPath))
    }

    func testMountedActivityResponderHandlesNativeArrowsTabsAndEnterWithoutGlobalMonitor() async throws {
        let f = try Fixture(); defer { f.close() }
        await f.layout()
        let (target, bytes) = try f.installInertTerminal(paneID: f.rows[2].id)
        target.keyDown(with: f.event(7, text: "x"))
        XCTAssertEqual(bytes.withLock { $0 }, Array("x".utf8), "Native target input must work before Activity opens")
        bytes.withLock { $0.removeAll() }
        let editor = try await f.focusSearchEditor()
        XCTAssertTrue(f.window.firstResponder === editor)
        let item = try f.activityMenuItem()
        XCTAssertTrue(f.delegate.validateMenuItem(item))
        f.delegate.performMenuAction(item)
        await f.layout()
        XCTAssertTrue(f.store.showActivity)
        let owner = try f.activityOwner()

        owner.keyDown(with: f.event(125, text: "\u{f701}"))
        XCTAssertEqual(f.store.selectedActivityID, f.rows[1].id, "The real native Activity responder must handle Down itself")
        await f.layout()
        let selected = try XCTUnwrap(f.region("activity-selected-" + f.rows[1].id))
        let rect = selected.convert(selected.bounds, to: f.hosting)
        XCTAssertTrue(f.hosting.bounds.contains(rect))
        XCTAssertGreaterThan(rect.width, 200)
        XCTAssertGreaterThan(rect.height, 40)
        owner.keyDown(with: f.event(126, text: "\u{f700}"))
        XCTAssertEqual(f.store.selectedActivityID, f.rows[0].id)
        for control: NSEvent.ModifierFlags in [[], .control] {
            owner.keyDown(with: f.event(48, flags: control, text: "\t"))
            XCTAssertEqual(f.store.selectedActivityID, f.rows[1].id)
            owner.keyDown(with: f.event(48, flags: control.union(.shift), text: "\u{19}"))
            XCTAssertEqual(f.store.selectedActivityID, f.rows[0].id)
        }
        owner.keyDown(with: f.event(125, text: "\u{f701}"))
        owner.keyDown(with: f.event(125, text: "\u{f701}"))
        XCTAssertEqual(f.store.selectedActivityID, f.rows[2].id)
        owner.keyDown(with: f.event(36, text: "\r"))
        XCTAssertFalse(f.store.showActivity)
        await f.drain()
        XCTAssertEqual(f.store.state.layout.selectedWorkspaceID, f.targetWorkspace)
        XCTAssertEqual(f.store.focusedID, f.rows[2].id)
        XCTAssertTrue(f.window.firstResponder === target)
        XCTAssertTrue(bytes.withLock { $0.isEmpty }, "Activity navigation must not leak keys into the target terminal")
        if f.window.firstResponder === target { target.keyDown(with: f.event(7, text: "x")) }
        XCTAssertEqual(bytes.withLock { $0 }, Array("x".utf8))
        XCTAssertFalse(target.started)
        XCTAssertFalse(target.process.running)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.runtime.host.socketPath))
    }

    func testApplicationSendEventWithLocalMonitorOpensActivityAndMovesEachKeyExactlyOnce() async throws {
        let f = try Fixture(); defer { f.close() }
        await f.layout()
        let (source, sourceBytes) = try f.installInertTerminal()
        source.keyDown(with: f.event(7, text: "x"))
        XCTAssertEqual(sourceBytes.withLock { $0 }, Array("x".utf8))
        sourceBytes.withLock { $0.removeAll() }
        let (target, targetBytes) = try f.installInertTerminal(paneID: f.rows[2].id)
        target.keyDown(with: f.event(7, text: "x"))
        XCTAssertEqual(targetBytes.withLock { $0 }, Array("x".utf8))
        targetBytes.withLock { $0.removeAll() }
        XCTAssertTrue(f.window.makeFirstResponder(source))
        try f.installEventMonitor()
        NSApp.sendEvent(f.event(47, flags: .command, text: "."))
        XCTAssertGreaterThan(f.observedEvents, 0, "NSApp.sendEvent must reach the configured local monitor before this fixture counts as event-delivery evidence")
        XCTAssertEqual(f.consumedEvents, 1)
        XCTAssertTrue(f.store.showActivity)
        await f.layout()
        _ = try f.activityOwner()
        let originalTab = f.store.state.layout.selectedTabID
        let initialObserved = f.observedEvents
        let initialConsumed = f.consumedEvents
        for (index, key) in [(1, UInt16(125)), (0, UInt16(126)), (1, UInt16(48))] {
            let text = key == 125 ? "\u{f701}" : key == 126 ? "\u{f700}" : "\t"
            NSApp.sendEvent(f.event(key, text: text))
            XCTAssertEqual(f.store.selectedActivityID, f.rows[index].id, "One native event must cause exactly one Activity row movement")
        }
        NSApp.sendEvent(f.event(48, flags: .control, text: "\t"))
        XCTAssertEqual(f.store.selectedActivityID, f.rows[2].id)
        XCTAssertEqual(f.store.state.layout.selectedTabID, originalTab)
        XCTAssertEqual(f.observedEvents, initialObserved + 4)
        XCTAssertEqual(f.consumedEvents, initialConsumed + 4)
        NSApp.sendEvent(f.event(36, text: "\r"))
        await f.drain()
        XCTAssertFalse(f.store.showActivity)
        XCTAssertEqual(f.store.state.layout.selectedWorkspaceID, f.targetWorkspace)
        XCTAssertEqual(f.store.focusedID, f.rows[2].id)
        XCTAssertTrue(f.window.firstResponder === target)
        XCTAssertTrue(sourceBytes.withLock { $0.isEmpty })
        XCTAssertTrue(targetBytes.withLock { $0.isEmpty })
        if f.window.firstResponder === target { target.keyDown(with: f.event(7, text: "x")) }
        XCTAssertEqual(targetBytes.withLock { $0 }, Array("x".utf8))
        XCTAssertFalse(source.started)
        XCTAssertFalse(target.started)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.runtime.host.socketPath))
    }

    func testRetainedActivityResponderYieldsToHigherOverlayAndNewMarkedEditor() async throws {
        let f = try Fixture(); defer { f.close() }
        _ = try await f.focusSearchEditor()
        f.delegate.performMenuAction(try f.activityMenuItem())
        await f.layout()
        let owner = try f.activityOwner()
        let selection = f.store.selectedActivityID
        f.store.showSettings = true
        owner.keyDown(with: f.event(125, text: "\u{f701}"))
        owner.keyDown(with: f.event(36, text: "\r"))
        owner.keyDown(with: f.event(53, text: "\u{1b}"))
        XCTAssertTrue(f.store.showActivity)
        XCTAssertEqual(f.store.selectedActivityID, selection)
        f.store.showSettings = false
        XCTAssertTrue(f.window.makeFirstResponder(f.search))
        let editor = try XCTUnwrap(f.search.currentEditor() as? NSTextView)
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        let text = editor.string
        let range = editor.markedRange()
        owner.keyDown(with: f.event(125, text: "\u{f701}"))
        owner.keyDown(with: f.event(36, text: "\r"))
        owner.keyDown(with: f.event(53, text: "\u{1b}"))
        XCTAssertTrue(f.window.firstResponder === editor)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.string, text)
        XCTAssertEqual(editor.markedRange(), range)
        XCTAssertTrue(f.store.showActivity)
        XCTAssertEqual(f.store.selectedActivityID, selection)
        editor.unmarkText()
    }

    @MainActor private struct Host: View {
        @ObservedObject var store: AppStore
        var body: some View {
            ZStack {
                Color.clear
                if store.showActivity { ActivityListView(store: store) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @MainActor private final class Fixture {
        let root = URL(fileURLWithPath: "/tmp/trano-act-event-" + UUID().uuidString.prefix(8))
        let runtime: TerminalRuntime
        let store: AppStore
        let rows: [TerminalSession]
        let targetWorkspace: String
        let hosting: NSHostingView<Host>
        let window: NSWindow
        let delegate = ApplicationDelegate()
        let search = PickerSearchTextField(frame: NSRect(x: 12, y: 12, width: 350, height: 24))
        let previousMenu: NSMenu?
        var monitor: Any?
        var observedEvents = 0
        var consumedEvents = 0
        var activityAfterMonitor: [Bool] = []

        init() throws {
            _ = NSApplication.shared
            previousMenu = NSApp.mainMenu
            runtime = try TerminalRuntime(root: root)
            let cwd = root.path
            rows = [ActivityState.blocked, .done, .running].map { activity in
                var row = TerminalSession(id: UUID().uuidString.lowercased(), title: activity.rawValue, cwd: cwd, pid: 0, alive: false)
                row.activity.state = activity
                row.activity.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
                return row
            }
            var layout = WorkspaceLayout()
            let first = layout.addWorkspace(title: "source")
            layout.addTab(paneID: rows[0].id)
            targetWorkspace = layout.addWorkspace(title: "target")
            let split = layout.addTab(paneID: rows[1].id)
            try layout.split(tabID: split, paneID: rows[2].id, axis: .horizontal)
            try layout.selectWorkspace(first)
            let values = rows
            try runtime.update { $0.sessions = values; $0.layout = layout; $0.settings.automaticRestore = false }
            store = AppStore(runtime: runtime, startServices: false)
            store.state = try runtime.state(); store.sessions = rows
            store.notificationPreferences.showEachProcessInTabs = true
            hosting = NSHostingView(rootView: Host(store: store))
            hosting.frame = NSRect(x: 0, y: 48, width: 440, height: 600)
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 648))
            container.addSubview(search)
            container.addSubview(hosting)
            search.delegate = search
            window = WorkspaceWindow.make(contentRect: NSRect(x: -12000, y: -12000, width: 440, height: 648), contentView: container)
            window.animationBehavior = .none
            window.orderFrontRegardless()
            delegate.window = window; delegate.store = store; delegate.windows[window] = store
            delegate.observeSettings(store, window: window)
            delegate.configureMenu()
        }

        func focusSearchEditor() async throws -> NSTextView {
            await layout()
            XCTAssertTrue(window.makeFirstResponder(search))
            let editor = try XCTUnwrap(search.currentEditor() as? NSTextView)
            XCTAssertTrue(window.firstResponder === editor)
            editor.insertText("retained search", replacementRange: editor.selectedRange())
            XCTAssertEqual(search.stringValue, "retained search")
            XCTAssertFalse(editor.hasMarkedText())
            return editor
        }

        func activityMenuItem() throws -> NSMenuItem {
            func find(_ menu: NSMenu) -> NSMenuItem? {
                for item in menu.items {
                    if item.identifier?.rawValue == ActionID.activity.rawValue { return item }
                    if let submenu = item.submenu, let found = find(submenu) { return found }
                }
                return nil
            }
            return try XCTUnwrap(NSApp.mainMenu.flatMap(find))
        }

        func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [], text: String = "") -> Bool {
            delegate.handle(event(code, flags: flags, text: text))
        }

        func event(_ code: UInt16, flags: NSEvent.ModifierFlags = [], text: String = "", inWindow: Bool = true) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: inWindow ? window.windowNumber : 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        }

        func installInertTerminal(paneID: String? = nil) throws -> (TranoView, SwiftTerm.Locked<[UInt8]>) {
            let container = try XCTUnwrap(window.contentView)
            let terminal = TranoView(frame: container.bounds)
            terminal.frameDriver.invalidate()
            terminal.paneID = paneID ?? rows[0].id; terminal.store = store
            terminal.configure(TerminalSettings())
            store.terminalViews[terminal.paneID] = terminal
            container.addSubview(terminal, positioned: .below, relativeTo: hosting)
            XCTAssertTrue(window.makeFirstResponder(terminal))
            let bytes = SwiftTerm.Locked<[UInt8]>([])
            terminal.setProcessInputHandler { input, origin, _ in
                if case .user = origin { bytes.withLock { $0.append(contentsOf: input) } }
            }
            XCTAssertFalse(terminal.started)
            XCTAssertFalse(terminal.process.running)
            return (terminal, bytes)
        }

        func closeActivityButton() throws -> ToolPanelCloseNativeButton {
            func find(_ view: NSView) -> ToolPanelCloseNativeButton? {
                if let button = view as? ToolPanelCloseNativeButton { return button }
                return view.subviews.lazy.compactMap { find($0) }.first
            }
            return try XCTUnwrap(find(hosting))
        }

        func region(_ id: String) -> NSView? {
            func find(_ view: NSView) -> NSView? {
                if view.identifier?.rawValue == id { return view }
                return view.subviews.lazy.compactMap { find($0) }.first
            }
            return find(hosting)
        }

        func layout() async {
            for _ in 0..<6 {
                window.contentView?.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(15))
            }
        }

        func drain() async {
            for _ in 0..<4 {
                await withCheckedContinuation { continuation in
                    store.queue.async { DispatchQueue.main.async { continuation.resume() } }
                }
            }
            await layout()
        }

        func installEventMonitor() throws {
            monitor = try XCTUnwrap(NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self else { return event }
                self.observedEvents += 1
                let handled = self.delegate.handle(event)
                self.activityAfterMonitor.append(self.store.showActivity)
                if handled {
                    self.consumedEvents += 1
                    return nil
                }
                return event
            })
        }

        func activityOwner() throws -> NSView {
            let owner = try XCTUnwrap(window.firstResponder as? NSView)
            XCTAssertTrue(owner === hosting || owner.isDescendant(of: hosting))
            XCTAssertFalse(ActivityKeyboardInput.ownsFieldEditor(owner), "The Activity list, not the filter field, owns native keyboard focus")
            XCTAssertFalse(owner is NSTextView)
            XCTAssertFalse(owner is TranoView)
            return owner
        }

        func close() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            (search.currentEditor() as? NSTextView)?.unmarkText()
            for terminal in store.terminalViews.values {
                terminal.urlHints.dismiss()
                terminal.setProcessInputHandler(nil)
                terminal.invalidateTerminalInteractions()
            }
            store.terminalViews.removeAll()
            window.makeFirstResponder(nil)
            window.contentView = nil; window.close()
            NSApp.mainMenu = previousMenu
            try? FileManager.default.removeItem(at: root)
        }
    }
}
