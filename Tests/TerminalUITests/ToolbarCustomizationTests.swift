import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

@MainActor final class ToolbarCustomizationTests: XCTestCase {
    private let items = ["resume", "workspace-actions", "remote-hosts", "decisions", "supervisor", "activity", "reset-tickets", "command-palette"]

    // Implements: FR-TOOLBAR-1, FR-TOOLBAR-2
    func testEveryIconOpensDirectCheckedMenuAndLeavesOrdinaryClicksUntouched() async throws {
        let f = try fixture()
        defer { dispose(f) }
        try await settle(f)
        let original = f.hosting.bounds
        for id in items where id != "reset-tickets" {
            let region = try XCTUnwrap(find("toolbar-customize-" + id, in: f.hosting) as? HeaderContextMenuView, id)
            XCTAssertNil(region.hitTest(NSPoint(x: region.bounds.midX, y: region.bounds.midY)))
            for (type, flags) in [(NSEvent.EventType.rightMouseDown, NSEvent.ModifierFlags()), (.leftMouseDown, .control)] {
                let menu = try XCTUnwrap(region.menu(for: event(type, flags: flags, in: region)))
                XCTAssertEqual(menu.title, "Customize View")
                for itemID in items {
                    let item = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "header-toolbar-" + itemID })
                    XCTAssertTrue(item.isEnabled, itemID)
                    XCTAssertEqual(item.state, .on, itemID)
                    XCTAssertNil(item.submenu, itemID)
                }
            }
        }
        XCTAssertEqual(f.hosting.bounds, original)
        XCTAssertTrue(f.store.terminalViews.isEmpty)
    }

    // Implements: FR-TOOLBAR-1
    func testIconMenuContainsOnlyImmediateVisibilityActions() throws {
        let f = try fixture()
        defer { dispose(f) }
        let menu = f.store.headerContextMenu(customizeViewOnly: true)
        XCTAssertEqual(menu.items.map { $0.identifier?.rawValue ?? "separator" }, items.map { "header-toolbar-" + $0 })
        XCTAssertTrue(menu.items.allSatisfy { $0.submenu == nil && $0.action != nil })
    }

    // Implements: FR-TOOLBAR-2, FR-TOOLBAR-3, FR-TOOLBAR-4
    func testHideAllAndRestoreViaExistingHeaderMenuPersistsWithoutSessionMutation() async throws {
        let f = try fixture()
        defer { dispose(f) }
        try await settle(f)
        let original = f.store.state
        for id in items {
            let menu = try customize(f.store)
            try invoke("header-toolbar-" + id, in: menu)
            try await wait { try self.hidden(f.runtime.interfacePreferences()).contains(id) }
        }
        try await settle(f)
        for id in items { XCTAssertNil(find("toolbar-customize-" + id, in: f.hosting), id) }
        XCTAssertNotNil(find("workspace-context-menu", in: f.hosting))
        XCTAssertEqual(try hidden(f.runtime.interfacePreferences()), Set(items))
        XCTAssertEqual(try encoded(f.store.state), try encoded(original))
        XCTAssertEqual(try encoded(f.runtime.state()), try encoded(RuntimeState()))
        let restore = try customize(f.store)
        for id in items { XCTAssertEqual(try item("header-toolbar-" + id, in: restore).state, .off) }
        try invoke("header-toolbar-command-palette", in: restore)
        try await wait { try !self.hidden(f.runtime.interfacePreferences()).contains("command-palette") }
        try await settle(f)
        XCTAssertNotNil(find("toolbar-customize-command-palette", in: f.hosting))
        XCTAssertEqual(try hidden(InterfacePreferencesStore(root: f.root).load()), Set(items).subtracting(["command-palette"]))
        XCTAssertTrue(f.store.terminalViews.isEmpty)
    }

    // Implements: FR-TOOLBAR-1, FR-TOOLBAR-2
    func testVerticalToolbarAndConditionalTicketShareVisibilityAndDirectMenu() async throws {
        let f = try fixture()
        defer { dispose(f) }
        let account = AccountProfile(provider: .codex, label: "Synthetic")
        f.store.state.accounts = [account]
        f.store.accountUsageSnapshots = [try AccountUsageAdapter.codex(accountID: account.id,
            data: Data("{\"ordinaryUsageAllowed\":true,\"rateLimits\":{},\"rateLimitResetCredits\":{\"availableCount\":2}}".utf8), now: Date())]
        f.store.interfacePreferences.toolbarLayout = .left
        f.store.showSessionsSidebar = true
        try await settle(f)
        let region = try XCTUnwrap(find("toolbar-customize-reset-tickets", in: f.hosting) as? HeaderContextMenuView)
        let menu = try XCTUnwrap(region.menu(for: event(.rightMouseDown, in: region)))
        XCTAssertEqual(menu.title, "Customize View")
        XCTAssertNotNil(find("reset-ticket-button", in: f.hosting))
        f.store.interfacePreferences = try JSONDecoder().decode(InterfacePreferences.self,
            from: Data("{\"toolbarLayout\":\"left\",\"hiddenToolbarItems\":[\"reset-tickets\",\"activity\"]}".utf8))
        try await settle(f)
        XCTAssertNil(find("toolbar-customize-reset-tickets", in: f.hosting))
        XCTAssertNil(find("reset-ticket-button", in: f.hosting))
        XCTAssertNil(find("toolbar-customize-activity", in: f.hosting))
        XCTAssertNotNil(find("toolbar-customize-command-palette", in: f.hosting))
        XCTAssertEqual(f.store.accountUsageSnapshots.first?.resetCredits?.availableCount, 2)
    }

    // Implements: FR-TOOLBAR-4
    func testUnavailableAndStaleOwnerMenusCannotWriteVisibility() async throws {
        let f = try fixture()
        defer { dispose(f) }
        f.store.loading = true
        let unavailable = try customize(f.store)
        let action = try item("header-toolbar-activity", in: unavailable)
        XCTAssertFalse(action.isEnabled)
        f.store.loading = false
        let captured = try customize(f.store, owner: f.window)
        f.window.orderOut(nil)
        try invoke("header-toolbar-activity", in: captured)
        await withCheckedContinuation { continuation in f.store.queue.async { continuation.resume() } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("interface-preferences.json").path))
    }

    private struct Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let store: AppStore
        let hosting: NSHostingView<WorkspaceView>
        let window: NSWindow
    }
    private func fixture() throws -> Fixture {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-toolbar-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let binding = SupervisorBinding(paneID: UUID().uuidString, backendPID: 4711,
            configuration: SupervisorConfiguration(provider: .claude, cwd: root.path))
        let store = AppStore(runtime: runtime, externalBinding: binding)
        let hosting = NSHostingView(rootView: WorkspaceView(store: store))
        let window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 1100, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        return Fixture(root: root, runtime: runtime, store: store, hosting: hosting, window: window)
    }
    private func settle(_ f: Fixture) async throws {
        for _ in 0..<4 { f.hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    }
    private func wait(_ condition: () throws -> Bool) async throws {
        let end = Date().addingTimeInterval(3)
        while !(try condition()) && Date() < end { try await Task.sleep(for: .milliseconds(15)) }
        XCTAssertTrue(try condition())
    }
    private func dispose(_ f: Fixture) {
        f.window.contentView = nil
        f.window.close()
        try? FileManager.default.removeItem(at: f.root)
    }
    private func find(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.find(id, in: $0) }.first
    }
    private func customize(_ store: AppStore, owner: NSWindow? = nil) throws -> NSMenu {
        try XCTUnwrap(store.headerContextMenu(sourceWindow: owner).items.first { $0.identifier?.rawValue == "header-customize-view" }?.submenu)
    }
    private func item(_ id: String, in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == id }, id)
    }
    private func invoke(_ id: String, in menu: NSMenu) throws {
        let value = try item(id, in: menu)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(value.action), to: value.target, from: value))
    }
    private func encoded(_ state: RuntimeState) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(state)
    }
    private func hidden(_ prefs: InterfacePreferences) throws -> Set<String> {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(prefs)) as? [String: Any])
        return Set(try XCTUnwrap(object["hiddenToolbarItems"] as? [String]))
    }
    private func event(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = [], in view: NSView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil),
            modifierFlags: flags, timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
}
