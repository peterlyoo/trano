import AppKit
import CoreText
import SwiftUI
import XCTest
import TerminalCore
@testable import TranoApp

final class FontSelectionTests: XCTestCase {
    // Implements: U05, U21
    @MainActor func testSettingsNativeColorWellsStayInsideHorizontalBounds() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-font-bounds-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let store = AppStore(runtime: runtime)
        let hosting = NSHostingView(rootView: SettingsView(store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 570), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close(); try? FileManager.default.removeItem(at: root) }
        try await Task.sleep(for: .milliseconds(200))
        hosting.layoutSubtreeIfNeeded()
        func colorWells(in view: NSView) -> [NSColorWell] {
            (view as? NSColorWell).map { [$0] } ?? view.subviews.flatMap { colorWells(in: $0) }
        }
        let wells = colorWells(in: hosting).filter { !$0.isHiddenOrHasHiddenAncestor }
        XCTAssertGreaterThanOrEqual(wells.count, 4)
        for well in wells {
            let frame = well.convert(well.bounds, to: hosting)
            XCTAssertGreaterThanOrEqual(frame.minX, hosting.bounds.minX - 1)
            XCTAssertLessThanOrEqual(frame.maxX, hosting.bounds.maxX + 1)
        }
    }

    // Implements: U05, U21
    @MainActor func testNativeDropdownSelectionsUpdateDraftBindings() async throws {
        _ = NSApplication.shared
        let draft = SettingsDraft(settings: TerminalSettings(), automaticallyChecksForUpdates: true, automaticallyDownloadsUpdates: false)
        let hosting = NSHostingView(rootView: FontPickerFixture(draft: draft))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 130), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()

        func menus(in view: NSView) -> [NSPopUpButton] {
            (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap { menus(in: $0) }
        }
        let controls = menus(in: hosting)
        XCTAssertEqual(controls.count, 2)
        let terminal = try XCTUnwrap(controls.first { $0.title.contains("Menlo") })
        let fallback = try XCTUnwrap(controls.first { $0 !== terminal })
        XCTAssertEqual(terminal.title, "Menlo Regular · Default")
        XCTAssertFalse(terminal.title.contains("Menlo-Regular"))
        XCTAssertTrue(hosting.bounds.contains(terminal.convert(terminal.bounds, to: hosting)))
        XCTAssertTrue(hosting.bounds.contains(fallback.convert(fallback.bounds, to: hosting)))
        let monaco = try XCTUnwrap(NSFont(name: "Monaco", size: 14))
        let monacoItem = try XCTUnwrap(terminal.item(withTitle: monaco.displayName ?? "Monaco"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(monacoItem.action), to: monacoItem.target, from: monacoItem))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(draft.settings.fontName, "Monaco")
        XCTAssertEqual(InstalledFontCatalog.previewFont(draft.settings).fontName, "Monaco")

        let automaticItem = try XCTUnwrap(fallback.item(withTitle: "Automatic"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(automaticItem.action), to: automaticItem.target, from: automaticItem))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(draft.settings.appearance.fallbackFontName, "")
        draft.cancel()
        XCTAssertEqual(draft.settings, TerminalSettings())
    }

    // Implements: U05, U21
    @MainActor func testDefaultTypefaceResolvesToInstalledMenlo() throws {
        _ = NSApplication.shared
        let menlo = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 14))
        XCTAssertEqual(menlo.fontName, "Menlo-Regular")
        let selected = try XCTUnwrap(SettingsDraft.font(named: TerminalSettings().fontName, size: 14))
        XCTAssertEqual(selected.fontName, menlo.fontName)
        XCTAssertTrue(selected.isFixedPitch)
    }

    // Implements: U05, U21
    @MainActor func testCachedCatalogContainsInstalledMonospacedChoicesAndPreservesCustomSelection() throws {
        let catalog = InstalledFontCatalog.shared
        XCTAssertTrue(catalog === InstalledFontCatalog.shared)
        XCTAssertEqual(catalog.monospaced.first?.id, "Menlo-Regular")
        XCTAssertTrue(catalog.monospaced.first?.label.contains("Menlo") == true)
        XCTAssertEqual(Set(catalog.all.map(\.id)).count, catalog.all.count)
        for choice in catalog.monospaced {
            XCTAssertTrue(try XCTUnwrap(NSFont(name: choice.id, size: 14)).isFixedPitch)
        }
        let proportional = try XCTUnwrap(catalog.all.first { NSFont(name: $0.id, size: 14)?.isFixedPitch == false })
        XCTAssertTrue(catalog.choices(monospacedOnly: true, selected: proportional.id).contains(proportional))
        XCTAssertEqual(catalog.choices(monospacedOnly: false, selected: ""), catalog.all)
    }

    // Implements: U05, U21
    @MainActor func testFontSelectionDraftCancelAndSavePreserveFallbackAndSize() throws {
        var original = TerminalSettings()
        original.appearance.fallbackFontName = "AppleSDGothicNeo-Regular"
        let draft = SettingsDraft(settings: original, automaticallyChecksForUpdates: true, automaticallyDownloadsUpdates: false)
        draft.settings.fontName = "Monaco"
        draft.settings.fontSize = 17
        draft.settings.appearance.fallbackFontName = ""
        XCTAssertEqual(InstalledFontCatalog.previewFont(draft.settings).fontName, "Monaco")
        draft.cancel()
        XCTAssertEqual(draft.settings, original)
        draft.settings.fontName = "Monaco"
        draft.settings.appearance.fallbackFontName = ""
        var saved: TerminalSettings?
        try draft.save(persist: { saved = $0; XCTAssertEqual($1, original) },
                       updateChecks: { _ in XCTFail("Unchanged update setting") },
                       updateDownloads: { _ in XCTFail("Unchanged update setting") })
        XCTAssertEqual(saved?.fontName, "Monaco")
        XCTAssertEqual(saved?.fontSize, 14)
        XCTAssertEqual(saved?.appearance.fallbackFontName, "")
    }

    // Implements: U05, U06, U21
    @MainActor func testPreviewShapesHangulWithSelectedFallback() throws {
        var settings = TerminalSettings()
        settings.appearance.fallbackFontName = "AppleSDGothicNeo-Regular"
        let preview = InstalledFontCatalog.previewFont(settings)
        XCTAssertEqual(preview.fontName, "Menlo-Regular")
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "한글 Aa 0123", attributes: [.font: preview]))
        let runs = CTLineGetGlyphRuns(line) as NSArray
        var names: [String] = []
        for item in runs {
            let run = item as! CTRun
            let attributes = CTRunGetAttributes(run) as NSDictionary
            if let font = attributes[kCTFontAttributeName] {
                names.append(CTFontCopyPostScriptName(font as! CTFont) as String)
            }
        }
        XCTAssertTrue(names.contains("AppleSDGothicNeo-Regular"))
        XCTAssertTrue(names.contains("Menlo-Regular"))
    }
}

@MainActor private struct FontPickerFixture: View {
    @ObservedObject var draft: SettingsDraft
    var body: some View {
        VStack(spacing: 14) {
            FontChoicePicker(title: "Terminal font", selection: $draft.settings.fontName)
            FontChoicePicker(title: "Hangul fallback font", selection: $draft.settings.appearance.fallbackFontName, fallback: true)
        }.padding(20).frame(width: 440, height: 130).preferredColorScheme(.dark)
    }
}
