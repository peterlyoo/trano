import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import SwiftTerm
@testable import TranoApp

@MainActor final class ActivityNativeFocusTests: XCTestCase {
    func testCommandPeriodMountTakesTerminalFocusAndDismissalReturnsTypingToThatTerminal() async throws {
        let f = try Fixture(); defer { f.close() }
        await f.layout()
        let (terminal, bytes) = try f.installInertTerminal()
        XCTAssertTrue(f.window.firstResponder === terminal)
        terminal.keyDown(with: f.event(7, text: "x"))
        XCTAssertEqual(bytes.withLock { $0 }, Array("x".utf8), "The initial native typing path must work before Activity is opened")
        bytes.withLock { $0.removeAll() }
        XCTAssertTrue(f.key(47, flags: .command, text: "."))
        XCTAssertTrue(f.store.showActivity)
        await f.layout()
        let owner = try XCTUnwrap(f.window.firstResponder as? NSView)
        XCTAssertFalse(owner === terminal)
        XCTAssertTrue(owner === f.hosting || owner.isDescendant(of: f.hosting))
        XCTAssertTrue(f.key(125))
        XCTAssertEqual(f.store.selectedActivityID, f.rows[1].id)
        let close = try f.closeActivityButton()
        XCTAssertTrue(close.target === close)
        XCTAssertEqual(close.action, #selector(ToolPanelCloseNativeButton.closePanel))
        XCTAssertTrue(close.isEnabled)
        close.performClick(nil)
        XCTAssertFalse(f.store.showActivity)
        await f.layout()
        XCTAssertTrue(f.window.firstResponder === terminal, "Dismissal must return native input to the original selected terminal")
        terminal.keyDown(with: f.event(7, text: "x"))
        XCTAssertEqual(bytes.withLock { $0 }, Array("x".utf8), "The restored terminal must accept actual native keyDown input")
        XCTAssertFalse(terminal.started)
        XCTAssertFalse(terminal.process.running)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.runtime.host.socketPath))
    }

    func testConfiguredMenuOpeningFromNativeSearchEditorAcquiresActivityFocusAndActivatesExactSplitPane() async throws {
        let f = try Fixture(); defer { f.close() }
        await f.layout()
        let (target, targetBytes) = try f.installInertTerminal(paneID: f.rows[2].id)
        target.keyDown(with: f.event(7, text: "x"))
        XCTAssertEqual(targetBytes.withLock { $0 }, Array("x".utf8), "The target renderer's native input path must work before navigation")
        targetBytes.withLock { $0.removeAll() }
        let editor = try await f.focusSearchEditor()
        XCTAssertTrue(editor.isFieldEditor)
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertTrue(f.window.firstResponder === editor)
        XCTAssertFalse(f.store.showActivity)

        let item = try f.activityMenuItem()
        XCTAssertEqual(item.keyEquivalent, ".")
        XCTAssertEqual(item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift]), .command)
        XCTAssertTrue(f.delegate.validateMenuItem(item))
        f.delegate.performMenuAction(item)
        XCTAssertTrue(f.store.showActivity)
        await f.layout()

        let owner = try XCTUnwrap(f.window.firstResponder as? NSView)
        XCTAssertFalse(owner === editor, "Activity appearance must release the previous unmarked search field editor")
        XCTAssertTrue(owner === f.hosting || owner.isDescendant(of: f.hosting), "The mounted Activity subtree must own native keyboard focus")
        XCTAssertTrue(f.key(125))
        XCTAssertEqual(f.store.selectedActivityID, f.rows[1].id)
        await f.layout()
        let selected = try XCTUnwrap(f.region("activity-selected-" + f.rows[1].id))
        let rect = selected.convert(selected.bounds, to: f.hosting)
        XCTAssertTrue(f.hosting.bounds.contains(rect))
        XCTAssertGreaterThan(rect.width, 200)
        XCTAssertGreaterThan(rect.height, 40)
        XCTAssertTrue(f.key(48, flags: .control, text: "\t"))
        XCTAssertEqual(f.store.selectedActivityID, f.rows[2].id)
        XCTAssertTrue(f.key(36, text: "\r"))
        XCTAssertFalse(f.store.showActivity)
        await f.drain()
        XCTAssertEqual(f.store.state.layout.selectedWorkspaceID, f.targetWorkspace)
        XCTAssertEqual(f.store.focusedID, f.rows[2].id)
        XCTAssertTrue(f.store.terminalViews[f.rows[2].id] === target)
        XCTAssertTrue(target.window === f.window)
        XCTAssertTrue(f.window.firstResponder === target, "Enter must deliver native focus to the exact selected split renderer")
        target.keyDown(with: f.event(7, text: "x"))
        XCTAssertEqual(targetBytes.withLock { $0 }, Array("x".utf8), "The activated split renderer must accept native keyDown input")
        XCTAssertFalse(target.started)
        XCTAssertFalse(target.process.running)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.runtime.host.socketPath))
    }

    func testMountedActivityDoesNotStealMarkedSearchEditorOrHigherOverlayFocus() async throws {
        for blockedBySettings in [false, true] {
            let f = try Fixture(); defer { f.close() }
            let editor = try await f.focusSearchEditor()
            if blockedBySettings { f.store.showSettings = true }
            else {
                editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                XCTAssertTrue(editor.hasMarkedText())
            }
            let text = editor.string
            let selection = editor.selectedRange()
            f.store.showActivity = true
            await f.layout()
            XCTAssertTrue(f.window.firstResponder === editor)
            XCTAssertEqual(editor.string, text)
            XCTAssertEqual(editor.selectedRange(), selection)
            XCTAssertEqual(editor.hasMarkedText(), !blockedBySettings)
            XCTAssertFalse(f.key(125))
            XCTAssertEqual(f.store.selectedActivityID, f.rows[0].id)
            editor.unmarkText()
        }
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
        let root = URL(fileURLWithPath: "/tmp/trano-act-focus-" + UUID().uuidString.prefix(8))
        let runtime: TerminalRuntime
        let store: AppStore
        let rows: [TerminalSession]
        let targetWorkspace: String
        let hosting: NSHostingView<Host>
        let window: NSWindow
        let delegate = ApplicationDelegate()
        let search = PickerSearchTextField(frame: NSRect(x: 12, y: 12, width: 350, height: 24))
        let previousMenu: NSMenu?

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

        func event(_ code: UInt16, flags: NSEvent.ModifierFlags = [], text: String = "") -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
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

        func close() {
            (search.currentEditor() as? NSTextView)?.unmarkText()
            for terminal in store.terminalViews.values {
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
