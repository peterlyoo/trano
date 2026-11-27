import AppKit
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class InterfaceControlTests: XCTestCase {
    // Implements: FR-SET-30, FR-SET-31, FR-SET-32, FR-SET-33, FR-SET-34, FR-SET-35,
    // FR-SET-36, FR-SET-37, FR-SET-38, FR-SET-39, FR-SET-40, FR-SET-41, FR-SET-42,
    // FR-SET-43, FR-SET-44, FR-SET-45, FR-SET-46, FR-SET-47, FR-SET-48, FR-SET-49,
    // FR-SET-50, FR-SET-51, FR-SET-52, FR-SET-53, FR-SET-54, FR-SET-55, FR-SET-56,
    // FR-SET-57, FR-SET-58, FR-SET-59, FR-SET-60, FR-SET-61
    @MainActor func testEveryInterfaceSettingHasAnIdentifiedNativeControl() throws {
        let expected = [
            "appearance-color-scheme", "appearance-interface-style", "appearance-tint-with-theme", "appearance-use-glass-for-panes",
            "toolbar-toolbar-layout", "toolbar-toolbar-behavior", "tab-behavior-tabs-fill-available-space",
            "tab-icons-use-color-for-tab-icons", "tab-icons-shell-icon-theme", "tab-icons-show-tab-icons",
            "panes-pane-style", "panes-pane-header-behavior", "window-sidebar-text-size",
            "window-preserve-width-when-resizing-sidebar", "window-use-a-gesture-to-toggle-the-sidebar",
            "padding-padding-x", "padding-padding-y", "padding-fill-with-program-colors", "padding-include-pane-header",
            "active-pane-highlight-active-pane-edges", "active-pane-highlight-color", "active-pane-highlight-opacity",
            "active-pane-animate-active-pane-highlight", "active-pane-fade-inactive-panes", "active-pane-fade-panes-for-inactive-windows",
            "splits-focus-autobalance-splits", "splits-focus-focus-follows-mouse", "gestures-use-trackpad-gestures",
            "animation-animation-style", "app-icon-app-icon", "app-icon-show-app-icon", "launch-show-window-on-launch"
        ].map { "setting-" + $0 }
        XCTAssertEqual(Set(InterfaceSettingsControls.settingIDs), Set(expected))
        let view = InterfaceSettingsControls(value: InterfacePreferences()) { _ in }
        for id in expected { XCTAssertNotNil(find(id, in: view), id) }
    }

    // Implements: FR-SET-30, FR-SET-34, FR-SET-42, FR-SET-45, FR-SET-61
    @MainActor func testNativeControlsBindDraftWithoutWritingFilesOrOpeningWindows() throws {
        var draft = InterfacePreferences()
        let view = InterfaceSettingsControls(value: draft) { draft = $0 }
        let scheme = try XCTUnwrap(find("setting-appearance-color-scheme", in: view) as? NSPopUpButton)
        scheme.selectItem(withTitle: "Light")
        XCTAssertTrue(scheme.sendAction(scheme.action, to: scheme.target))
        XCTAssertEqual(draft.colorScheme, .light)
        let layout = try XCTUnwrap(find("setting-toolbar-toolbar-layout", in: view) as? NSPopUpButton)
        layout.selectItem(withTitle: "Right Side")
        XCTAssertTrue(layout.sendAction(layout.action, to: layout.target))
        XCTAssertEqual(draft.toolbarLayout, .right)
        let text = try XCTUnwrap(find("setting-window-sidebar-text-size", in: view) as? NSPopUpButton)
        text.selectItem(withTitle: "System")
        XCTAssertTrue(text.sendAction(text.action, to: text.target))
        XCTAssertNil(draft.sidebarTextSize)
        let padding = try XCTUnwrap(find("setting-padding-padding-x", in: view) as? NSSlider)
        padding.doubleValue = 12
        XCTAssertTrue(padding.sendAction(padding.action, to: padding.target))
        XCTAssertEqual(draft.paddingX, 12)
        let launch = try XCTUnwrap(find("setting-launch-show-window-on-launch", in: view) as? NSButton)
        launch.state = .off
        XCTAssertTrue(launch.sendAction(launch.action, to: launch.target))
        XCTAssertFalse(draft.showWindowOnLaunch)
        XCTAssertNil(view.window)
    }

    // Implements: FR-SET-33, FR-SET-39, FR-SET-49, FR-SET-51
    @MainActor func testDependentControlsAndOrientationSpecificIconCountsStayBounded() throws {
        let view = InterfaceSettingsControls(value: InterfacePreferences()) { _ in }
        XCTAssertFalse(try XCTUnwrap(find("setting-appearance-use-glass-for-panes", in: view) as? NSControl).isEnabled)
        var prefs = InterfacePreferences()
        prefs.style = .glass
        prefs.highlightActivePaneEdges = false
        view.update(prefs)
        XCTAssertTrue(try XCTUnwrap(find("setting-appearance-use-glass-for-panes", in: view) as? NSControl).isEnabled)
        XCTAssertFalse(try XCTUnwrap(find("setting-active-pane-highlight-opacity", in: view) as? NSControl).isEnabled)
        let horizontal = try XCTUnwrap(find("setting-tab-icons-show-tab-icons-horizontal", in: view) as? NSPopUpButton)
        let vertical = try XCTUnwrap(find("setting-tab-icons-show-tab-icons-vertical", in: view) as? NSPopUpButton)
        XCTAssertEqual(horizontal.itemTitles, ["0", "1", "2", "3", "4", "5"])
        XCTAssertEqual(vertical.itemTitles, ["0", "1", "2", "3"])
    }

    @MainActor private func find(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.find(id, in: $0) }.first
    }
}
