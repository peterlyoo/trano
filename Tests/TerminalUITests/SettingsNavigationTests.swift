import AppKit
import SwiftUI
import XCTest
#if canImport(TranoApp)
@testable import TranoApp
#else
@testable import SettingsNavigation
#endif

// Implements: U21
@MainActor
final class SettingsNavigationTests: XCTestCase {
    @MainActor final class Selection {
        var value: String
        var writes: [String] = []
        init(_ value: String) { self.value = value }
        var binding: Binding<String> {
            Binding(get: { MainActor.assumeIsolated { self.value } },
                    set: { value in MainActor.assumeIsolated { self.value = value; self.writes.append(value) } })
        }
    }

    func testCategoryCatalogPreservesIdsAndUsesExpectedOrder() {
        XCTAssertEqual(SettingsCategory.all.map(\.id), ["interface", "themes", "terminal", "profiles", "shortcuts", "notifications", "server", "integrations", "developer", "general", "updates", "appearance"])
        XCTAssertEqual(SettingsCategory.all.map(\.title), ["Interface", "Themes", "Terminal", "Profiles", "Shortcuts", "Notifications", "Server", "Integrations", "Developer", "General", "Updates", "Appearance"])
        XCTAssertEqual(Set(SettingsCategory.all.map(\.id)).count, SettingsCategory.all.count)
        for category in SettingsCategory.all {
            XCTAssertNotNil(NSImage(systemSymbolName: category.systemImage, accessibilityDescription: nil), category.id)
        }
    }

    func testNativeClickUpdatesBindingAndSelectionImmediately() throws {
        let selection = Selection("appearance")
        let bridge = SettingsNavigationSidebar(selection: selection.binding)
        let view = bridge.makeNativeView()
        let button = try XCTUnwrap(view.buttons.first { $0.categoryID == "profiles" })
        button.performClick(nil)
        XCTAssertEqual(selection.value, "profiles")
        XCTAssertEqual(selection.writes, ["profiles"])
        XCTAssertEqual(view.selectedID, "profiles")
        XCTAssertEqual(button.state, .on)
        XCTAssertEqual(view.buttons.filter { $0.state == .on }.map(\.categoryID), ["profiles"])
    }

    func testRedrawPreservesEveryButtonAndUsesLatestBindingAndGate() throws {
        let old = Selection("appearance")
        var oldGateCalls = 0
        let view = SettingsNavigationSidebar(selection: old.binding, canNavigate: { _ in oldGateCalls += 1; return false }).makeNativeView()
        let identities = view.buttons.map(ObjectIdentifier.init)
        let latest = Selection("themes")
        var latestGateIDs: [String] = []
        let redrawn = SettingsNavigationSidebar(selection: latest.binding, canNavigate: { latestGateIDs.append($0); return true })
        redrawn.updateNativeView(view)
        XCTAssertEqual(view.buttons.map(ObjectIdentifier.init), identities)
        let button = try XCTUnwrap(view.buttons.first { $0.categoryID == "server" })
        XCTAssertTrue(button.target === button)
        button.performClick(nil)
        XCTAssertEqual(old.value, "appearance")
        XCTAssertTrue(old.writes.isEmpty)
        XCTAssertEqual(oldGateCalls, 0)
        XCTAssertEqual(latest.value, "server")
        XCTAssertEqual(latestGateIDs, ["server"])
        XCTAssertEqual(view.selectedID, "server")
    }

    func testMarkedTextGateRefusesNavigationAndCanProceedAfterCompositionEnds() throws {
        let selection = Selection("profiles")
        var hasMarkedText = true
        var checks = 0
        let view = SettingsNavigationSidebar(selection: selection.binding, canNavigate: { _ in checks += 1; return !hasMarkedText }).makeNativeView()
        let button = try XCTUnwrap(view.buttons.first { $0.categoryID == "terminal" })
        XCTAssertFalse(button.acceptsFirstResponder)
        XCTAssertFalse(view.acceptsFirstResponder)
        button.performClick(nil)
        XCTAssertEqual(checks, 1)
        XCTAssertTrue(selection.writes.isEmpty)
        XCTAssertEqual(view.selectedID, "profiles")
        hasMarkedText = false
        button.performClick(nil)
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(selection.writes, ["terminal"])
        XCTAssertEqual(view.selectedID, "terminal")
    }

    func testReselectDoesNotRecreateOrWriteCurrentEditorSelection() throws {
        let selection = Selection("shortcuts")
        var checks = 0
        let view = SettingsNavigationSidebar(selection: selection.binding, canNavigate: { _ in checks += 1; return true }).makeNativeView()
        let identities = view.buttons.map(ObjectIdentifier.init)
        let button = try XCTUnwrap(view.buttons.first { $0.categoryID == "shortcuts" })
        button.performClick(nil)
        XCTAssertTrue(selection.writes.isEmpty)
        XCTAssertEqual(checks, 0)
        XCTAssertEqual(view.buttons.map(ObjectIdentifier.init), identities)
    }

    func testCustomBindingRefusalDoesNotShowAnUncommittedSelection() throws {
        let selection = Selection("appearance")
        let binding = Binding(get: { selection.value }, set: { _ in })
        let view = SettingsNavigationSidebar(selection: binding).makeNativeView()
        let button = try XCTUnwrap(view.buttons.first { $0.categoryID == "developer" })
        button.performClick(nil)
        XCTAssertEqual(view.selectedID, "appearance")
        XCTAssertEqual(view.buttons.filter { $0.state == .on }.map(\.categoryID), ["appearance"])
    }

    func testDisablingAndEnablingPreservesTargetsAndSelection() throws {
        let selection = Selection("general")
        let bridge = SettingsNavigationSidebar(selection: selection.binding)
        let view = bridge.makeNativeView()
        let identities = view.buttons.map(ObjectIdentifier.init)
        bridge.updateNativeView(view, enabled: false)
        XCTAssertTrue(view.buttons.allSatisfy { !$0.isEnabled })
        let button = try XCTUnwrap(view.buttons.first { $0.categoryID == "updates" })
        button.performClick(nil)
        XCTAssertTrue(selection.writes.isEmpty)
        bridge.updateNativeView(view, enabled: true)
        button.performClick(nil)
        XCTAssertEqual(selection.writes, ["updates"])
        XCTAssertEqual(view.buttons.map(ObjectIdentifier.init), identities)
    }

    func testRowsFitSidebarBoundsWithoutOverlapOrTruncatedTitles() {
        let view = SettingsNavigationSidebar(selection: .constant("appearance")).makeNativeView()
        view.frame = NSRect(x: 0, y: 0, width: 148, height: 430)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.intrinsicContentSize.width, 148)
        XCTAssertEqual(view.buttons.count, 12)
        for button in view.buttons {
            let frame = button.convert(button.bounds, to: view)
            XCTAssertTrue(view.bounds.contains(frame), button.categoryID)
            XCTAssertGreaterThanOrEqual(button.frame.height, 28)
            XCTAssertLessThanOrEqual(button.cell?.cellSize.width ?? .infinity, button.frame.width, button.categoryID)
            XCTAssertEqual(button.accessibilityIdentifier(), "settings.category." + button.categoryID)
        }
        for pair in zip(view.buttons, view.buttons.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.frame.maxY, pair.1.frame.minY)
        }
    }

    func testRefreshUpdatesSelectionWithoutReplacingControlTree() {
        let selection = Selection("appearance")
        let bridge = SettingsNavigationSidebar(selection: selection.binding)
        let view = bridge.makeNativeView()
        let identities = view.buttons.map(ObjectIdentifier.init)
        selection.value = "notifications"
        bridge.updateNativeView(view)
        XCTAssertEqual(view.buttons.map(ObjectIdentifier.init), identities)
        XCTAssertEqual(view.selectedID, "notifications")
        XCTAssertEqual(view.buttons.filter { $0.state == .on }.map(\.categoryID), ["notifications"])
        XCTAssertTrue(selection.writes.isEmpty)
    }

    private var implementedCategoryIDs: Set<String> {
        ["interface", "themes", "profiles", "shortcuts", "notifications", "general", "updates", "appearance"]
    }

    func testFilteredRowsAreCompactAndRemainInCatalogOrder() {
        let selection = Selection("appearance")
        let view = SettingsNavigationSidebar(selection: selection.binding, visibleCategoryIDs: implementedCategoryIDs).makeNativeView()
        view.frame = NSRect(x: 0, y: 0, width: 148, height: 430)
        view.layoutSubtreeIfNeeded()
        let visible = view.buttons.filter { !$0.isHidden }
        XCTAssertEqual(view.buttons.count, 12)
        XCTAssertEqual(visible.map(\.categoryID), ["interface", "themes", "profiles", "shortcuts", "notifications", "general", "updates", "appearance"])
        XCTAssertEqual(view.intrinsicContentSize.height, 270)
        for (index, button) in visible.enumerated() {
            XCTAssertEqual(button.frame.minY, 8 + CGFloat(index) * 32)
            XCTAssertEqual(button.frame.height, 30)
            XCTAssertTrue(view.bounds.contains(button.convert(button.bounds, to: view)))
            XCTAssertLessThanOrEqual(button.cell?.cellSize.width ?? .infinity, button.frame.width)
        }
        XCTAssertTrue(selection.writes.isEmpty)
    }

    func testFilterRedrawKeepsVisibleSelectionAndNativeControlIdentity() {
        let selection = Selection("profiles")
        let view = SettingsNavigationSidebar(selection: selection.binding, visibleCategoryIDs: implementedCategoryIDs).makeNativeView()
        let identities = view.buttons.map(ObjectIdentifier.init)
        view.frame = NSRect(x: 0, y: 0, width: 148, height: 430)
        SettingsNavigationSidebar(selection: selection.binding, visibleCategoryIDs: ["profiles", "updates"]).updateNativeView(view)
        view.layoutSubtreeIfNeeded()
        let visible = view.buttons.filter { !$0.isHidden }
        XCTAssertEqual(visible.map(\.categoryID), ["profiles", "updates"])
        XCTAssertEqual(visible.map(\.frame.minY), [8, 40])
        XCTAssertEqual(view.intrinsicContentSize.height, 78)
        XCTAssertEqual(view.selectedID, "profiles")
        XCTAssertEqual(visible.filter { $0.state == .on }.map(\.categoryID), ["profiles"])
        XCTAssertEqual(view.buttons.map(ObjectIdentifier.init), identities)
        XCTAssertTrue(view.buttons.allSatisfy { $0.target === $0 })
        XCTAssertTrue(selection.writes.isEmpty)
        SettingsNavigationSidebar(selection: selection.binding).updateNativeView(view)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.buttons.filter { !$0.isHidden }.count, 12)
        XCTAssertEqual(view.intrinsicContentSize.height, 398)
        XCTAssertEqual(view.buttons.map(ObjectIdentifier.init), identities)
        XCTAssertEqual(view.selectedID, "profiles")
        XCTAssertTrue(selection.writes.isEmpty)
    }

    func testHidingCurrentCategoryOrAllCategoriesNeverNavigatesOrWritesDraft() throws {
        let selection = Selection("terminal")
        let view = SettingsNavigationSidebar(selection: selection.binding).makeNativeView()
        var gateCalls = 0
        SettingsNavigationSidebar(selection: selection.binding, canNavigate: { _ in gateCalls += 1; return true }, visibleCategoryIDs: implementedCategoryIDs).updateNativeView(view)
        XCTAssertEqual(view.selectedID, "terminal")
        XCTAssertEqual(selection.value, "terminal")
        XCTAssertTrue(view.buttons.filter { !$0.isHidden && $0.state == .on }.isEmpty)
        let hidden = try XCTUnwrap(view.buttons.first { $0.categoryID == "server" })
        XCTAssertTrue(hidden.isHidden)
        XCTAssertFalse(hidden.isEnabled)
        hidden.onPress?()
        XCTAssertEqual(gateCalls, 0)
        XCTAssertEqual(selection.value, "terminal")
        SettingsNavigationSidebar(selection: selection.binding, visibleCategoryIDs: []).updateNativeView(view)
        view.frame = NSRect(x: 0, y: 0, width: 148, height: 430)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.buttons.allSatisfy(\.isHidden))
        XCTAssertEqual(view.intrinsicContentSize.height, 16)
        XCTAssertEqual(view.selectedID, "terminal")
        XCTAssertTrue(selection.writes.isEmpty)
        SettingsNavigationSidebar(selection: selection.binding).updateNativeView(view)
        XCTAssertEqual(view.buttons.filter { !$0.isHidden && $0.state == .on }.map(\.categoryID), ["terminal"])
        XCTAssertTrue(selection.writes.isEmpty)
    }
}
