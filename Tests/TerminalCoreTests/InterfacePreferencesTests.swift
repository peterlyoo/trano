import Foundation
import XCTest
@testable import TerminalCore

final class InterfacePreferencesTests: XCTestCase {
    // Implements: FR-SET-30, FR-SET-31, FR-SET-40, FR-SET-45, FR-SET-46, FR-SET-61
    func testDefaultsKeepExistingDarkChromeAndTerminalGeometry() throws {
        let prefs = InterfacePreferences()
        let plan = prefs.resolve(InterfaceContext())
        XCTAssertEqual(prefs.colorScheme, .dark)
        XCTAssertEqual(prefs.style, .classic)
        XCTAssertEqual(plan.headerHeight, 40)
        XCTAssertEqual(plan.paneHeaderHeight, 28)
        XCTAssertEqual(plan.dividerWidth, 5)
        XCTAssertEqual(plan.padding, InterfaceInsets())
        XCTAssertEqual(prefs.sidebarWidth, 216)
        XCTAssertTrue(prefs.preserveWindowWidth)
        XCTAssertTrue(prefs.showWindowOnLaunch)
        XCTAssertEqual(try JSONDecoder().decode(InterfacePreferences.self, from: Data("{}".utf8)), prefs)
    }

    // Implements: FR-SET-30, FR-SET-31, FR-SET-32, FR-SET-33
    func testAppearanceUsesLiveSystemAndThemeColorsWithoutEnablingUnrequestedGlass() {
        var prefs = InterfacePreferences()
        var context = InterfaceContext()
        context.systemIsDark = false
        prefs.colorScheme = .automatic
        XCTAssertFalse(prefs.resolve(context).isDark)
        XCTAssertEqual(prefs.resolve(context).chromeBackground, "#F5F5F7")
        prefs.colorScheme = .dark
        prefs.style = .glass
        prefs.glassForPanes = true
        prefs.tintWithTheme = true
        context.themeBackground = "#162C30"
        context.themeForeground = "#F0FFF9"
        context.themeAccent = "#88E0BC"
        let plan = prefs.resolve(context)
        XCTAssertTrue(plan.isDark)
        XCTAssertTrue(plan.glassChrome)
        XCTAssertTrue(plan.glassPanes)
        XCTAssertEqual(plan.chromeBackground, context.themeBackground)
        XCTAssertEqual(plan.chromeForeground, context.themeForeground)
        XCTAssertEqual(plan.accent, context.themeAccent)
        prefs.style = .classic
        XCTAssertFalse(prefs.resolve(context).glassPanes)
    }

    // Implements: FR-SET-34, FR-SET-35
    func testToolbarHoverAndExplicitRevealOverlayWithoutReservingTerminalSpace() {
        var prefs = InterfacePreferences()
        var context = InterfaceContext()
        prefs.toolbarBehavior = .onHover
        let hidden = prefs.resolve(context)
        XCTAssertFalse(hidden.toolbarVisible)
        XCTAssertEqual(hidden.reservedHeaderHeight, 0)
        context.toolbarHovered = true
        let hovered = prefs.resolve(context)
        XCTAssertTrue(hovered.toolbarVisible)
        XCTAssertTrue(hovered.toolbarOverlaysContent)
        XCTAssertEqual(hovered.reservedHeaderHeight, hidden.reservedHeaderHeight)
        prefs.toolbarBehavior = .hidden
        XCTAssertFalse(prefs.resolve(context).toolbarVisible)
        context.toolbarRevealed = true
        XCTAssertTrue(prefs.resolve(context).toolbarVisible)
        prefs.toolbarLayout = .right
        context.sidebarVisible = true
        XCTAssertEqual(prefs.resolve(context).toolbarLayout, .right)
        XCTAssertEqual(prefs.resolve(context).sidebarWidth, 216)
        context.sidebarVisible = false
        XCTAssertFalse(prefs.resolve(context).toolbarVisible)
        context.sidebarVisible = true
        XCTAssertTrue(prefs.resolve(context).toolbarVisible)
    }

    // Implements: FR-SET-36, FR-SET-37, FR-SET-38, FR-SET-39
    func testTabSizingAndIconPolicyRespectActivePaneTabAndOrientation() {
        var prefs = InterfacePreferences()
        var context = InterfaceContext()
        prefs.tabsFillAvailableSpace = true
        context.tabCount = 3
        XCTAssertEqual(prefs.resolve(context).equalTabWidth(available: 600), 200)
        context.tabCount = 1
        XCTAssertFalse(prefs.resolve(context).tabBackgroundVisible)
        context.tabCount = 2
        XCTAssertTrue(prefs.resolve(context).tabBackgroundVisible)
        prefs.horizontalIconCount = 4
        prefs.verticalIconCount = 1
        prefs.iconColor = .activePanes
        context.isActivePane = false
        XCTAssertFalse(prefs.resolve(context).colorTabIcons)
        context.isActivePane = true
        XCTAssertTrue(prefs.resolve(context).colorTabIcons)
        prefs.iconColor = .activeTabs
        context.isActiveTab = false
        XCTAssertFalse(prefs.resolve(context).colorTabIcons)
        context.isActiveTab = true
        XCTAssertTrue(prefs.resolve(context).colorTabIcons)
        prefs.iconColor = .never
        XCTAssertFalse(prefs.resolve(context).colorTabIcons)
        prefs.shellIconTheme = .accent
        XCTAssertEqual(prefs.resolve(context).shellIconTheme, .accent)
        XCTAssertEqual(prefs.resolve(context).tabIconCount, 4)
        prefs.toolbarLayout = .left
        XCTAssertNil(prefs.resolve(context).equalTabWidth(available: 600))
        XCTAssertEqual(prefs.resolve(context).tabIconCount, 1)
    }

    // Implements: FR-SET-40, FR-SET-41, FR-SET-45, FR-SET-46
    func testPaneDensityHeadersAndInsetsDoNotResizeOnHover() {
        var prefs = InterfacePreferences()
        var context = InterfaceContext()
        prefs.paneStyle = .compact
        prefs.paddingX = 7
        prefs.paddingY = 9
        var plan = prefs.resolve(context)
        XCTAssertEqual(plan.paneHeaderHeight, 22)
        XCTAssertEqual(plan.dividerWidth, 1)
        XCTAssertEqual(plan.padding, InterfaceInsets(top: 0, leading: 7, bottom: 9, trailing: 7))
        prefs.paneHeaderBehavior = .onHover
        plan = prefs.resolve(context)
        XCTAssertFalse(plan.paneHeaderVisible)
        XCTAssertEqual(plan.reservedPaneHeaderHeight, 0)
        XCTAssertEqual(plan.padding.top, 9)
        context.paneHovered = true
        let hovered = prefs.resolve(context)
        XCTAssertTrue(hovered.paneHeaderVisible)
        XCTAssertTrue(hovered.paneHeaderOverlaysContent)
        XCTAssertEqual(hovered.padding, plan.padding)
        XCTAssertEqual(hovered.reservedPaneHeaderHeight, plan.reservedPaneHeaderHeight)
        prefs.paneHeaderBehavior = .hidden
        XCTAssertFalse(prefs.resolve(context).paneHeaderVisible)
    }

    // Implements: FR-SET-42, FR-SET-43, FR-SET-44
    func testSidebarSizingAndWindowWidthPolicyAreBoundedAndOnlyVertical() {
        var prefs = InterfacePreferences()
        var context = InterfaceContext()
        prefs.toolbarLayout = .left
        prefs.sidebarWidth = 250
        prefs.sidebarTextSize = nil
        context.systemSidebarTextSize = 15
        context.sidebarVisible = true
        XCTAssertEqual(prefs.resolve(context).sidebarFontSize, 15)
        XCTAssertEqual(prefs.windowWidthAfterSidebarChange(current: 1000, showing: true, available: 1600, fullScreen: false), 1000)
        prefs.preserveWindowWidth = false
        XCTAssertEqual(prefs.windowWidthAfterSidebarChange(current: 1000, showing: true, available: 1600, fullScreen: false), 1251)
        XCTAssertEqual(prefs.windowWidthAfterSidebarChange(current: 1251, showing: false, available: 1600, fullScreen: false), 1000)
        XCTAssertEqual(prefs.windowWidthAfterSidebarChange(current: 1500, showing: true, available: 1600, fullScreen: false), 1600)
        XCTAssertEqual(prefs.windowWidthAfterSidebarChange(current: 1000, showing: true, available: 1600, fullScreen: true), 1000)
        prefs.toolbarLayout = .above
        XCTAssertEqual(prefs.windowWidthAfterSidebarChange(current: 1000, showing: true, available: 1600, fullScreen: false), 1000)
    }

    // Implements: FR-SET-47, FR-SET-48
    func testProgramPaddingColorsUseAlternateScreenAndOptionalHeaderFill() {
        var prefs = InterfacePreferences()
        var context = InterfaceContext()
        context.themeBackground = "#101010"
        context.programBackground = "#202060"
        prefs.paddingFill = .automatic
        XCTAssertEqual(prefs.resolve(context).paddingBackground, context.themeBackground)
        context.alternateScreen = true
        XCTAssertEqual(prefs.resolve(context).paddingBackground, context.programBackground)
        XCTAssertEqual(prefs.resolve(context).paneHeaderBackground, context.themeBackground)
        prefs.includePaneHeaderInPaddingFill = true
        XCTAssertEqual(prefs.resolve(context).paneHeaderBackground, context.programBackground)
        prefs.paddingFill = .always
        context.alternateScreen = false
        XCTAssertEqual(prefs.resolve(context).paddingBackground, context.programBackground)
        prefs.paddingFill = .off
        XCTAssertEqual(prefs.resolve(context).paddingBackground, context.themeBackground)
    }

    // Implements: FR-SET-49, FR-SET-50, FR-SET-51, FR-SET-52, FR-SET-53, FR-SET-54, FR-SET-58
    func testHighlightFadeAndReducedMotionAreSeparateResolvedBehaviors() {
        var prefs = InterfacePreferences()
        var context = InterfaceContext()
        prefs.highlightColor = .terminalText
        prefs.highlightOpacity = 0.7
        prefs.highlightAnimation = .move
        prefs.animationStyle = .natural
        XCTAssertEqual(prefs.resolve(context).highlightColor, context.themeForeground)
        XCTAssertEqual(prefs.resolve(context).highlightOpacity, 0.7)
        XCTAssertEqual(prefs.resolve(context).highlightAnimation, .move)
        XCTAssertEqual(prefs.resolve(context).animationStyle, .natural)
        prefs.fadeInactivePanes = .surfaceAndContent
        context.isActivePane = false
        XCTAssertLessThan(prefs.resolve(context).contentOpacity, 1)
        XCTAssertTrue(prefs.resolve(context).fadeSurface)
        XCTAssertEqual(prefs.resolve(context).backgroundMultiplier, 0.82)
        XCTAssertEqual(prefs.resolve(context).contentOpacity, 0.65)
        context.isActivePane = true
        context.isActiveWindow = false
        prefs.fadePanesForInactiveWindows = false
        XCTAssertEqual(prefs.resolve(context).contentOpacity, 1)
        prefs.fadePanesForInactiveWindows = true
        XCTAssertLessThan(prefs.resolve(context).contentOpacity, 1)
        context.reduceMotion = true
        XCTAssertEqual(prefs.resolve(context).animationStyle, .off)
        XCTAssertEqual(prefs.resolve(context).highlightAnimation, .instant)
        prefs.highlightActivePaneEdges = false
        XCTAssertEqual(prefs.resolve(context).highlightOpacity, 0)
    }

    // Implements: FR-SET-55
    func testAutobalanceChangesTopologyWithoutOverwritingManuallyDraggedDividers() {
        var prefs = InterfacePreferences()
        prefs.autobalanceSplits = true
        let old = PaneTree.split(id: "manual", axis: .horizontal, ratio: 0.3, first: .pane("a"), second: .pane("b"))
        let new = PaneTree.split(id: "manual", axis: .horizontal, ratio: 0.3, first: .pane("a"),
            second: .split(id: "new", axis: .horizontal, ratio: 0.7, first: .pane("b"), second: .pane("c")))
        let balanced = prefs.treeAfterTopologyChange(previous: old, current: new, manuallyResizedSplits: ["manual"])
        XCTAssertEqual(balanced.ratio(for: "manual"), 0.3)
        XCTAssertEqual(balanced.ratio(for: "new"), 0.5)
        XCTAssertEqual(balanced.panes, new.panes)
        XCTAssertEqual(prefs.treeAfterTopologyChange(previous: old, current: old, manuallyResizedSplits: []), old)
        prefs.autobalanceSplits = false
        XCTAssertEqual(prefs.treeAfterTopologyChange(previous: old, current: new, manuallyResizedSplits: []), new)
    }

    // Implements: FR-SET-44, FR-SET-56, FR-SET-57
    func testPointerAndTrackpadActionsRespectInputOwnershipAndOptionScrolling() {
        var prefs = InterfacePreferences()
        var context = InterfaceContext()
        prefs.focusFollowsMouse = true
        XCTAssertTrue(prefs.canFollowPointer(context))
        context.inputIsProtected = true
        XCTAssertFalse(prefs.canFollowPointer(context))
        context.inputIsProtected = false
        context.isActiveWindow = false
        XCTAssertFalse(prefs.canFollowPointer(context))
        context.isActiveWindow = true
        prefs.trackpadGestures = true
        prefs.toolbarLayout = .left
        prefs.sidebarGesture = .swipe
        XCTAssertEqual(prefs.gesture(.swipe(delta: 1, option: false), context: context), .showSidebar)
        XCTAssertNil(prefs.gesture(.swipe(delta: 1, option: true), context: context))
        prefs.sidebarGesture = .optionSwipe
        XCTAssertEqual(prefs.gesture(.swipe(delta: -1, option: true), context: context), .hideSidebar)
        XCTAssertEqual(prefs.gesture(.magnify(0.2), context: context), .zoomPane)
        XCTAssertEqual(prefs.gesture(.magnify(-0.2), context: context), .restorePane)
        prefs.trackpadGestures = false
        XCTAssertNil(prefs.gesture(.magnify(0.2), context: context))
    }

    // Implements: FR-SET-59, FR-SET-60, FR-SET-61
    func testApplicationIconPresenceAndLaunchChoicesHaveDeterministicPolicies() {
        var prefs = InterfacePreferences()
        var context = InterfaceContext()
        prefs.iconVisibility = .menuBarWhenNoWindows
        context.visibleWindowCount = 0
        XCTAssertFalse(prefs.resolve(context).showDockIcon)
        XCTAssertTrue(prefs.resolve(context).showMenuBarIcon)
        context.visibleWindowCount = 1
        XCTAssertTrue(prefs.resolve(context).showDockIcon)
        XCTAssertFalse(prefs.resolve(context).showMenuBarIcon)
        prefs.iconVisibility = .dockAndMenuBar
        XCTAssertTrue(prefs.resolve(context).showMenuBarIcon)
        prefs.appIcon = .bright
        XCTAssertEqual(prefs.resolve(context).appIcon, .bright)
        prefs.appIcon = .twilight
        XCTAssertEqual(prefs.resolve(context).appIcon, .twilight)
        prefs.showWindowOnLaunch = false
        XCTAssertFalse(prefs.resolve(context).showWindowOnLaunch)
    }

    // Implements: FR-SET-30, FR-SET-39, FR-SET-42, FR-SET-45, FR-SET-46, FR-SET-51
    func testValidationRejectsNonfiniteAndUnboundedValuesWithoutClampingSilently() throws {
        for mutate in [
            { (p: inout InterfacePreferences) in p.paddingX = -1 },
            { (p: inout InterfacePreferences) in p.paddingY = .infinity },
            { (p: inout InterfacePreferences) in p.sidebarWidth = 50 },
            { (p: inout InterfacePreferences) in p.sidebarTextSize = .nan },
            { (p: inout InterfacePreferences) in p.horizontalIconCount = 6 },
            { (p: inout InterfacePreferences) in p.verticalIconCount = -1 },
            { (p: inout InterfacePreferences) in p.highlightOpacity = 1.1 }
        ] {
            var value = InterfacePreferences()
            mutate(&value)
            XCTAssertThrowsError(try value.validate())
        }
        XCTAssertNoThrow(try InterfacePreferences().validate())
    }

    // Implements: FR-SET-30, FR-SET-45, FR-SET-61
    func testDraftCancelAndSavePreserveUnrelatedConcurrentChanges() throws {
        let initial = InterfacePreferences()
        var draft = InterfacePreferencesDraft(initial)
        draft.value.paddingX = 12
        draft.value.colorScheme = .light
        var concurrent = initial
        concurrent.showWindowOnLaunch = false
        let result = try draft.applying(to: concurrent)
        XCTAssertEqual(result.paddingX, 12)
        XCTAssertEqual(result.colorScheme, .light)
        XCTAssertFalse(result.showWindowOnLaunch)
        draft.cancel()
        XCTAssertEqual(draft.value, initial)
    }

    // Implements: FR-SET-30, FR-SET-55
    func testSecureSidecarSurvivesPrimaryStateRewriteAndRetainsManualSplitProvenance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-interface-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InterfacePreferencesStore(root: root)
        XCTAssertEqual(try store.load(), InterfacePreferences())
        var prefs = InterfacePreferences()
        prefs.colorScheme = .light
        try store.save(prefs, baseline: InterfacePreferences())
        try store.markManuallyResizedSplit("split-one")
        try Data("{}".utf8).write(to: root.appendingPathComponent("state.json"))
        XCTAssertEqual(try InterfacePreferencesStore(root: root).load(), prefs)
        XCTAssertEqual(try store.manuallyResizedSplits(), ["split-one"])
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("interface-preferences.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // Implements: FR-SET-30
    func testSidecarRefusesSymlinkAndGroupReadableFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-interface-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        let file = root.appendingPathComponent("interface-preferences.json")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try InterfacePreferencesStore(root: root).load())
        XCTAssertThrowsError(try InterfacePreferencesStore(root: root).save(InterfacePreferences(), baseline: nil))
        XCTAssertEqual(try Data(contentsOf: target), Data("{}".utf8))
        try FileManager.default.removeItem(at: file)
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try InterfacePreferencesStore(root: root).load())
    }
}
