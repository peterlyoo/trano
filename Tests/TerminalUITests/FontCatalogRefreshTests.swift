import AppKit
import XCTest
import TerminalCore
@testable import TranoApp

final class FontCatalogRefreshTests: XCTestCase {
    // Implements: U05, U21
    @MainActor func testReopeningLoadedMenuDiscoversAddedFontWithoutWritingSelection() async throws {
        _ = NSApplication.shared
        var names = ["Menlo-Regular"]
        let catalog = InstalledFontCatalog(availableFontNames: { names })
        var changes: [String] = []
        let button = makeButton(catalog, selection: "Menlo-Regular") { changes.append($0) }
        open(button)
        XCTAssertFalse(ids(button).contains("Monaco"))

        names.append("Monaco")
        open(button)
        XCTAssertTrue(ids(button).contains("Monaco"))
        XCTAssertEqual(button.selectedItem?.representedObject as? String, "Menlo-Regular")
        XCTAssertTrue(changes.isEmpty)

        let item = try XCTUnwrap(button.itemArray.first { $0.representedObject as? String == "Monaco" })
        XCTAssertTrue(item.target === button)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(changes, ["Monaco"])
        XCTAssertEqual(button.selectedItem?.representedObject as? String, "Monaco")
    }

    // Implements: U05, U21
    @MainActor func testUnchangedMembershipChecksNamesWithoutResolvingOrReplacingItems() async throws {
        _ = NSApplication.shared
        var names = ["Menlo-Regular", "Monaco"]
        var nameChecks = 0
        var resolutions = 0
        let catalog = InstalledFontCatalog(availableFontNames: { nameChecks += 1; return names },
                                           resolveFont: { resolutions += 1; return NSFont(name: $0, size: 14) })
        let button = makeButton(catalog, selection: "Menlo-Regular")
        let checksBeforeMount = nameChecks
        button.configure(selection: "Menlo-Regular", fallback: false) { _ in XCTFail("Query wrote selection") }
        XCTAssertEqual(nameChecks, checksBeforeMount)
        open(button)
        let monaco = try XCTUnwrap(button.itemArray.first { $0.representedObject as? String == "Monaco" })
        let checksAfterOpen = nameChecks
        let resolvedAfterOpen = resolutions

        names = ["Monaco", "Menlo-Regular", "Monaco"]
        open(button)
        XCTAssertEqual(nameChecks, checksAfterOpen + 1)
        XCTAssertEqual(resolutions, resolvedAfterOpen)
        XCTAssertTrue(button.itemArray.contains { $0 === monaco })
        XCTAssertEqual(button.selectedItem?.representedObject as? String, "Menlo-Regular")
    }

    // Implements: U05, U21
    @MainActor func testEveryLoadedMenuFollowsCatalogRevisionAndPreservesItsOwnValue() async throws {
        _ = NSApplication.shared
        var names = ["Menlo-Regular"]
        let catalog = InstalledFontCatalog(availableFontNames: { names })
        let first = makeButton(catalog, selection: "Menlo-Regular")
        let second = makeButton(catalog, selection: "TranoUnavailableFixture")
        open(first)
        open(second)

        names.append("Monaco")
        open(first)
        open(second)
        XCTAssertTrue(ids(first).contains("Monaco"))
        XCTAssertTrue(ids(second).contains("Monaco"))
        XCTAssertEqual(second.selectedItem?.representedObject as? String, "TranoUnavailableFixture")
        XCTAssertTrue(second.title.contains("Unavailable"))

        names.removeAll { $0 == "Monaco" }
        open(second)
        open(first)
        XCTAssertFalse(ids(first).contains("Monaco"))
        XCTAssertFalse(ids(second).contains("Monaco"))
    }

    // Implements: U05, U21
    @MainActor func testBuiltInSystemFontIsLabeledAndSelectableOnlyForPrimaryFont() async throws {
        _ = NSApplication.shared
        let catalog = InstalledFontCatalog(availableFontNames: { ["Menlo-Regular", "Helvetica"] })
        var changes: [String] = []
        let primary = makeButton(catalog, selection: "Menlo-Regular") { changes.append($0) }
        open(primary)
        let system = try XCTUnwrap(primary.item(withTitle: "System Monospaced (macOS)"))
        XCTAssertEqual(system.representedObject as? String, "system-monospace")
        XCTAssertFalse(ids(primary).contains("Helvetica"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(system.action), to: system.target, from: system))
        XCTAssertEqual(changes, ["system-monospace"])
        primary.configure(selection: "system-monospace", fallback: false) { changes.append($0) }
        XCTAssertEqual(primary.title, "System Monospaced (macOS)")

        let fallback = makeButton(catalog, selection: "", fallback: true)
        open(fallback)
        XCTAssertEqual(fallback.item(at: 0)?.title, "Automatic")
        XCTAssertTrue(ids(fallback).contains("Helvetica"))
        XCTAssertFalse(ids(fallback).contains("system-monospace"))
        let allFonts = makeButton(catalog, selection: "Menlo-Regular", allFonts: true)
        open(allFonts)
        XCTAssertTrue(ids(allFonts).contains("Helvetica"))
        XCTAssertTrue(ids(allFonts).contains("system-monospace"))
        XCTAssertFalse(catalog.all.contains { $0.id == "system-monospace" })
    }

    // Implements: U05, U21
    @MainActor func testUnopenedMenuStaysSmallAndCustomFontSelectionSurvivesModeChanges() async throws {
        _ = NSApplication.shared
        var nameChecks = 0
        let catalog = InstalledFontCatalog(availableFontNames: { nameChecks += 1; return ["Menlo-Regular", "Helvetica"] })
        let initialChecks = nameChecks
        let button = makeButton(catalog, selection: "Helvetica")
        XCTAssertEqual(nameChecks, initialChecks)
        XCTAssertEqual(button.numberOfItems, 1)
        open(button)
        XCTAssertEqual(button.selectedItem?.representedObject as? String, "Helvetica")
        button.configure(selection: "Helvetica", fallback: true) { _ in XCTFail("Query wrote selection") }
        open(button)
        XCTAssertEqual(button.item(at: 0)?.title, "Automatic")
        XCTAssertEqual(button.selectedItem?.representedObject as? String, "Helvetica")
    }

    @MainActor private func makeButton(_ catalog: InstalledFontCatalog, selection: String,
                                      fallback: Bool = false, allFonts: Bool = false,
                                      onChange: @escaping (String) -> Void = { _ in XCTFail("Query wrote selection") }) -> FontChoicePopUpButton {
        let button = FontChoicePopUpButton(frame: .zero, pullsDown: false)
        button.fontCatalog = catalog
        button.configure(selection: selection, fallback: fallback, allFonts: allFonts, onChange: onChange)
        return button
    }

    @MainActor private func open(_ button: FontChoicePopUpButton) {
        guard let menu = button.menu else { return XCTFail("Missing menu") }
        menu.delegate?.menuNeedsUpdate?(menu)
    }

    @MainActor private func ids(_ button: FontChoicePopUpButton) -> [String] {
        button.itemArray.compactMap { $0.representedObject as? String }
    }
}
