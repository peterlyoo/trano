import AppKit
import SwiftUI
import XCTest
import TerminalCore
@testable import TranoApp

final class FontMenuLoadingTests: XCTestCase {
    // Implements: U05, U21
    @MainActor func testMountDoesNotMaterializeUnopenedFontMenus() async throws {
        let f = try await fixture()
        defer { f.window.close() }
        let controls = popups(in: f.hosting)
        XCTAssertEqual(controls.count, 2)
        for control in controls {
            XCTAssertGreaterThan(control.numberOfItems, 0)
            XCTAssertLessThanOrEqual(control.numberOfItems, 2, "Unopened font menus must not build the installed-font list")
            XCTAssertTrue(f.hosting.bounds.contains(control.convert(control.bounds, to: f.hosting)))
        }
        XCTAssertTrue(controls.contains { $0.title == "Menlo Regular · Default" })
        let fallback = try XCTUnwrap(NSFont(name: TerminalSettings().appearance.fallbackFontName, size: 14))
        XCTAssertTrue(controls.contains { $0.title == (fallback.displayName ?? fallback.fontName) })
        XCTAssertEqual(f.draft.settings, TerminalSettings())
    }

    // Implements: U05, U21
    @MainActor func testOpeningMenusLoadsChoicesAndNativeActionsPreserveDraftCancel() async throws {
        let f = try await fixture()
        defer { f.window.close() }
        let controls = popups(in: f.hosting)
        let terminal = try XCTUnwrap(controls.first { $0.title.contains("Menlo") })
        let fallback = try XCTUnwrap(controls.first { $0 !== terminal })
        for control in controls {
            let menu = try XCTUnwrap(control.menu)
            menu.delegate?.menuNeedsUpdate?(menu)
            XCTAssertGreaterThan(control.numberOfItems, 2)
        }
        let monaco = try XCTUnwrap(NSFont(name: "Monaco", size: 14))
        let item = try XCTUnwrap(terminal.item(withTitle: monaco.displayName ?? "Monaco"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        try await layout(f)
        XCTAssertEqual(f.draft.settings.fontName, "Monaco")
        let automatic = try XCTUnwrap(fallback.item(withTitle: "Automatic"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(automatic.action), to: automatic.target, from: automatic))
        XCTAssertEqual(f.draft.settings.appearance.fallbackFontName, "")
        f.draft.cancel()
        try await layout(f)
        XCTAssertEqual(f.draft.settings, TerminalSettings())
        XCTAssertEqual(terminal.title, "Menlo Regular · Default")
    }

    // Implements: U05, U21
    @MainActor func testUnrelatedDraftUpdatesKeepLoadedMenuItemsAndUnavailableSelection() async throws {
        let f = try await fixture()
        defer { f.window.close() }
        let terminal = try XCTUnwrap(popups(in: f.hosting).first { $0.title.contains("Menlo") })
        let menu = try XCTUnwrap(terminal.menu)
        menu.delegate?.menuNeedsUpdate?(menu)
        let monaco = try XCTUnwrap(NSFont(name: "Monaco", size: 14))
        let item = try XCTUnwrap(terminal.item(withTitle: monaco.displayName ?? "Monaco"))
        f.draft.settings.fontSize = 18
        f.draft.settings.background = "#151519"
        try await layout(f)
        XCTAssertTrue(terminal.menu === menu)
        XCTAssertTrue(terminal.item(withTitle: monaco.displayName ?? "Monaco") === item)
        f.draft.settings.fontName = "TranoFixtureUnavailableFont"
        try await layout(f)
        XCTAssertTrue(terminal.title.contains("TranoFixtureUnavailableFont"))
        XCTAssertTrue(terminal.title.contains("Unavailable"))
        XCTAssertEqual(f.draft.settings.fontName, "TranoFixtureUnavailableFont")
    }

    private struct Fixture {
        let draft: SettingsDraft
        let hosting: NSHostingView<FontMenuFixture>
        let window: NSWindow
    }

    @MainActor private func fixture() async throws -> Fixture {
        _ = NSApplication.shared
        let draft = SettingsDraft(settings: TerminalSettings(), automaticallyChecksForUpdates: true, automaticallyDownloadsUpdates: false)
        let hosting = NSHostingView(rootView: FontMenuFixture(draft: draft))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 130), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -14000, y: -14000))
        let f = Fixture(draft: draft, hosting: hosting, window: window)
        try await layout(f)
        return f
    }

    @MainActor private func layout(_ f: Fixture) async throws {
        f.hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        f.hosting.layoutSubtreeIfNeeded()
    }

    @MainActor private func popups(in view: NSView) -> [NSPopUpButton] {
        (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap { popups(in: $0) }
    }
}

@MainActor private struct FontMenuFixture: View {
    @ObservedObject var draft: SettingsDraft
    var body: some View {
        VStack(spacing: 14) {
            FontChoicePicker(title: "Terminal font", selection: $draft.settings.fontName)
            FontChoicePicker(title: "Hangul fallback font", selection: $draft.settings.appearance.fallbackFontName, fallback: true)
        }.padding(20).frame(width: 440, height: 130)
    }
}
