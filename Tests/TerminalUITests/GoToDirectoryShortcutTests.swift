import AppKit
import XCTest
@testable import SwiftTerm
@testable import TerminalCore
@testable import TranoApp

@MainActor final class GoToDirectoryShortcutTests: XCTestCase {
    func testDefaultDirectoryShortcutAndExplicitOverridesRemainUnambiguous() throws {
        XCTAssertEqual(try KeyBindingMap().action(for: "cmd+shift+g"), .goToDirectory)
        XCTAssertEqual(ActionCatalog.action(for: "cmd+shift+g")?.action, .goToDirectory)
        XCTAssertEqual(ActionCatalog.all.first { $0.action == .goToDirectory }?.shortcut, "⌘⇧G")
        XCTAssertEqual(try KeyBindingMap().action(for: "cmd+g"), .findNext)
        XCTAssertNil(try KeyBindingMap(overrides: [ActionID.goToDirectory.rawValue: []]).action(for: "cmd+shift+g"))
        let custom = try KeyBindingMap(overrides: [ActionID.findPrevious.rawValue: ["cmd+shift+g"]])
        XCTAssertEqual(custom.action(for: "cmd+shift+g"), .findPrevious)
        XCTAssertEqual(custom.bindings[ActionID.goToDirectory.rawValue], [])
        let sequence = try TerminalKeySequenceMap(overrides: [
            ActionID.findPrevious.rawValue: [], ActionID.voice.rawValue: ["cmd+shift+g,cmd+x"]
        ])
        XCTAssertNil(sequence.singles.action(for: "cmd+shift+g"))
        XCTAssertTrue(sequence.hasPrefix(["cmd+shift+g"]))
    }

    func testNativeShortcutOpensDirectoryChooserForTheFocusedPane() throws {
        let f = try Fixture(remote: true); defer { f.close() }
        XCTAssertNotNil(f.view.interactionOwner())
        XCTAssertTrue(f.window.firstResponder === f.view)
        XCTAssertTrue(f.delegate.handle(f.key(shifted: false)))
        XCTAssertNil(f.store.remotePathRequest, "Ordinary Cmd+G remains Find Next")
        XCTAssertTrue(f.delegate.handle(f.key(shifted: true)))
        let request = try XCTUnwrap(f.store.remotePathRequest)
        XCTAssertTrue(request.directoryOnly)
        XCTAssertEqual(request.paneID, f.paneID)
        XCTAssertEqual(request.hostID, "fixture-host")
        XCTAssertEqual(request.path, "/srv/project folder")
        XCTAssertEqual(request.owner, f.view.interactionOwner())
        XCTAssertFalse(f.view.started)
        XCTAssertFalse(f.view.process.running)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.runtime.host.socketPath))
    }

    func testConfiguredMenuShortcutAndLocalChooserOpenOnlyDirectoriesInNewTabs() throws {
        let f = try Fixture(remote: false); defer { f.close() }
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        f.delegate.configureMenu()
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.identifier?.rawValue == ActionID.goToDirectory.rawValue { return item }
                if let submenu = item.submenu, let found = find(submenu) { return found }
            }
            return nil
        }
        let item = try XCTUnwrap(NSApp.mainMenu.flatMap(find))
        XCTAssertEqual(item.keyEquivalent, "g")
        XCTAssertEqual(item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]), [.command, .shift])
        let owner = try XCTUnwrap(f.view.interactionOwner())
        let panel = f.store.makeTerminalPathPanel(directoryOnly: true, directory: f.root.path,
            recentPaths: [], preferences: TerminalPreferences(), owner: owner)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertEqual(panel.prompt, "Open in New Tab")
        XCTAssertEqual(panel.directoryURL?.standardizedFileURL.path, f.root.standardizedFileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.runtime.host.socketPath))
    }

    @MainActor private final class Fixture {
        let root = URL(fileURLWithPath: "/tmp/t-dir-" + UUID().uuidString.prefix(8))
        let paneID = UUID().uuidString.lowercased()
        let runtime: TerminalRuntime
        let store: AppStore
        let view: TranoView
        let window: NSWindow
        let delegate = ApplicationDelegate()

        init(remote: Bool) throws {
            _ = NSApplication.shared
            runtime = try TerminalRuntime(root: root)
            store = AppStore(runtime: runtime, startServices: false)
            var pane = TerminalSession(id: paneID, title: "Shell", cwd: remote ? "/srv/project folder" : root.path, pid: 0, alive: false)
            if remote { pane.remote = RemoteReference(hostID: "fixture-host", sessionID: "fixture-pane") }
            var state = RuntimeState()
            state.settings.automaticRestore = false
            state.sessions = [pane]
            state.layout.addWorkspace(title: "directory-fixture")
            state.layout.addTab(paneID: paneID)
            try runtime.update { $0 = state }
            store.state = state; store.sessions = state.sessions
            view = TranoView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            view.frameDriver.invalidate()
            view.store = store; view.paneID = paneID; view.configure(TerminalSettings())
            store.terminalViews[paneID] = view
            window = WorkspaceWindow.make(contentRect: NSRect(x: -12000, y: -12000, width: 800, height: 600), contentView: view)
            window.animationBehavior = .none; window.orderFrontRegardless()
            XCTAssertTrue(window.makeFirstResponder(view))
            delegate.window = window; delegate.store = store; delegate.windows[window] = store
            delegate.observeSettings(store, window: window)
        }

        func key(shifted: Bool) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shifted ? [.command, .shift] : .command,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: shifted ? "G" : "g",
                charactersIgnoringModifiers: shifted ? "G" : "g", isARepeat: false, keyCode: 5)!
        }

        func close() {
            view.invalidateTerminalInteractions()
            store.terminalViews.removeAll()
            window.makeFirstResponder(nil); window.contentView = nil; window.close()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
