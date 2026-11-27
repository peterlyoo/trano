import AppKit
import XCTest
import TerminalCore
@testable import TranoApp

@MainActor final class QuickLookHoverHostTests: XCTestCase {
    // Implements: FR-SET-104
    func testConfiguredCommandYSingleShortcutTakesPrecedenceWithoutPreviewQueries() throws {
        let map = try TerminalKeySequenceMap(overrides: [ActionID.newTab.rawValue: ["cmd+y"]])
        XCTAssertEqual(map.singles.action(for: "cmd+y"), .newTab)
        let owner = NSObject(); var queries = 0, deliveries = 0
        let source = pane("focused", owner: owner, hovered: { _ in queries += 1; return "https://example.com" })
        XCTAssertFalse(QuickLookHoverHost.handle(preferences: enabled(), ownerID: ObjectIdentifier(owner), ownerIsRegistered: true,
            firstResponderPaneID: "focused", focusedPaneID: "focused", hasMarkedText: false, hasModal: false, inputBusy: false,
            configuredSingleAction: map.singles.action(for: "cmd+y"), pointerInOwner: NSPoint(x: 10, y: 10), panes: [source], deliver: { _ in deliveries += 1 }))
        XCTAssertEqual(queries, 0); XCTAssertEqual(deliveries, 0)
    }

    // Implements: FR-SET-104
    func testHoveredPaneWinsAndKeepsItsOwnCWDAndIdentity() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: first.appendingPathComponent("README.md"))
        try Data("two".utf8).write(to: second.appendingPathComponent("README.md"))
        let owner = NSObject(); var selectionQueries = 0; var result: QuickLookHoverResult?
        let hovered = pane("hovered", cwd: first, owner: owner, hovered: { _ in "README.md" })
        let focused = pane("focused", cwd: second, owner: owner, contains: { _ in false }, selected: { selectionQueries += 1; return "README.md" })
        XCTAssertTrue(handle(owner: owner, focused: "focused", panes: [hovered, focused]) { result = $0 })
        XCTAssertEqual(result, QuickLookHoverResult(paneID: "hovered", cwd: first, target: .file(first.appendingPathComponent("README.md"))))
        XCTAssertEqual(selectionQueries, 0)
    }

    // Implements: FR-SET-104
    func testNoHoverFallsBackToFocusedSelectionWithItsCWD() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("한글.txt"); try Data("local".utf8).write(to: file)
        let owner = NSObject(); var result: QuickLookHoverResult?
        let source = pane("focused", cwd: root, owner: owner, hovered: { _ in nil }, selected: { "한글.txt" })
        XCTAssertTrue(handle(owner: owner, focused: "focused", panes: [source]) { result = $0 })
        XCTAssertEqual(result?.paneID, "focused"); XCTAssertEqual(result?.cwd, root); XCTAssertEqual(result?.target, .file(file))
    }

    // Implements: FR-SET-104
    func testHiddenAndForeignWindowPanesCannotSupplyHoverOrSelection() {
        let owner = NSObject(), foreign = NSObject(); var queries = 0; var result: QuickLookHoverResult?
        let bad = pane("foreign", owner: foreign, hovered: { _ in queries += 1; return "https://wrong.example" }, selected: { queries += 1; return "https://wrong.example" })
        let hidden = pane("hidden", owner: owner, visible: false, hovered: { _ in queries += 1; return "https://wrong.example" })
        let focused = pane("focused", owner: owner, contains: { _ in false }, selected: { "https://correct.example" })
        XCTAssertTrue(handle(owner: owner, focused: "focused", panes: [bad, hidden, focused]) { result = $0 })
        XCTAssertEqual(queries, 0); XCTAssertEqual(result?.target, .web(URL(string: "https://correct.example")!))
    }

    // Implements: FR-SET-104
    func testOwnerResponderIMEAndModalGatesPrecedeAllQueriesAndCallbacks() {
        let owner = NSObject(); var queries = 0, deliveries = 0
        let source = pane("focused", owner: owner, hovered: { _ in queries += 1; return "https://example.com" }, selected: { queries += 1; return "https://example.com" })
        for mode in 0..<7 {
            var preferences = enabled(); if mode == 0 { preferences.quickLookLinks = false }
            let accepted = QuickLookHoverHost.handle(preferences: preferences, ownerID: ObjectIdentifier(owner),
                ownerIsRegistered: mode != 1, firstResponderPaneID: mode == 2 ? nil : mode == 3 ? "other" : "focused", focusedPaneID: "focused",
                hasMarkedText: mode == 4, hasModal: mode == 5, inputBusy: mode == 6,
                pointerInOwner: NSPoint(x: 10, y: 10), panes: [source], deliver: { _ in deliveries += 1 })
            XCTAssertFalse(accepted)
        }
        XCTAssertEqual(queries, 0); XCTAssertEqual(deliveries, 0)
    }

    // Implements: FR-SET-104
    func testRemoteFilesAreRefusedEvenWhenSamePathExistsLocallyButHTTPWorks() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("unrelated local file".utf8).write(to: root.appendingPathComponent("README.md"))
        let owner = NSObject(); var result: QuickLookHoverResult?
        let remoteFile = pane("focused", cwd: root, remote: true, owner: owner, hovered: { _ in "README.md" }, selected: { root.appendingPathComponent("README.md").absoluteString })
        XCTAssertFalse(handle(owner: owner, focused: "focused", panes: [remoteFile]) { result = $0 }); XCTAssertNil(result)
        let remoteWeb = pane("focused", cwd: root, remote: true, owner: owner, hovered: { _ in "https://example.com/remote" })
        XCTAssertTrue(handle(owner: owner, focused: "focused", panes: [remoteWeb]) { result = $0 })
        XCTAssertEqual(result?.paneID, "focused"); XCTAssertEqual(result?.cwd, root)
        XCTAssertEqual(result?.target, .web(URL(string: "https://example.com/remote")!))
    }

    private func enabled() -> DeveloperPreferences { var value = DeveloperPreferences(); value.enabled = true; value.quickLookLinks = true; return value }
    private func handle(owner: NSObject, focused: String, panes: [QuickLookHoverPane], deliver: (QuickLookHoverResult) -> Void) -> Bool {
        QuickLookHoverHost.handle(preferences: enabled(), ownerID: ObjectIdentifier(owner), ownerIsRegistered: true,
            firstResponderPaneID: focused, focusedPaneID: focused, hasMarkedText: false, hasModal: false, inputBusy: false,
            pointerInOwner: NSPoint(x: 10, y: 10), panes: panes, deliver: deliver)
    }
    private func pane(_ id: String, cwd: URL = URL(fileURLWithPath: "/tmp"), remote: Bool = false, owner: NSObject,
        visible: Bool = true, contains: @escaping (NSPoint) -> Bool = { _ in true },
        hovered: @escaping (NSPoint) -> String? = { _ in nil }, selected: @escaping () -> String? = { nil }) -> QuickLookHoverPane {
        QuickLookHoverPane(paneID: id, cwd: cwd, isRemote: remote, ownerID: ObjectIdentifier(owner), visible: visible,
            pointInView: { $0 }, containsPoint: contains, hoveredLink: hovered, selectedText: selected)
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-quicklook-unit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }
}
