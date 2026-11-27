import Foundation
import Darwin

public enum InterfaceColorScheme: String, Codable, CaseIterable, Sendable { case automatic, light, dark }
public enum InterfaceSurfaceStyle: String, Codable, CaseIterable, Sendable { case classic, glass }
public enum InterfaceToolbarLayout: String, Codable, CaseIterable, Sendable { case above, left, right }
public enum InterfaceToolbarItem: String, CaseIterable, Sendable {
    case resume
    case workspaceActions = "workspace-actions"
    case remoteHosts = "remote-hosts"
    case decisions, supervisor, activity
    case resetTickets = "reset-tickets"
    case commandPalette = "command-palette"
}
public enum InterfaceVisibility: String, Codable, CaseIterable, Sendable { case always, onHover, hidden }
public enum InterfaceIconColor: String, Codable, CaseIterable, Sendable { case always, activePanes, activeTabs, never }
public enum InterfaceShellIconTheme: String, Codable, CaseIterable, Sendable { case artwork, theme, accent }
public enum InterfacePaneStyle: String, Codable, CaseIterable, Sendable { case comfortable, compact }
public enum InterfaceSidebarGesture: String, Codable, CaseIterable, Sendable { case swipe, optionSwipe, off }
public enum InterfacePaddingFill: String, Codable, CaseIterable, Sendable { case off, automatic, always }
public enum InterfaceHighlightColor: String, Codable, CaseIterable, Sendable { case accent, terminalPalette, terminalText }
public enum InterfaceHighlightAnimation: String, Codable, CaseIterable, Sendable { case fade, move, instant }
public enum InterfaceFade: String, Codable, CaseIterable, Sendable { case neither, surface, content, surfaceAndContent }
public enum InterfaceAnimation: String, Codable, CaseIterable, Sendable { case snappy, natural, off }
public enum InterfaceAppIcon: String, Codable, CaseIterable, Sendable { case defaultDynamic, bright, twilight }
public enum InterfaceIconVisibility: String, Codable, CaseIterable, Sendable { case dockAndMenuBar, dockOnly, menuBarWhenNoWindows }
public enum InterfaceGesture: Equatable, Sendable { case swipe(delta: Double, option: Bool), magnify(Double) }
public enum InterfaceGestureAction: Equatable, Sendable { case showSidebar, hideSidebar, zoomPane, restorePane }

public struct InterfaceInsets: Equatable, Sendable {
    public var top: Double = 0
    public var leading: Double = 0
    public var bottom: Double = 0
    public var trailing: Double = 0
    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = top; self.leading = leading; self.bottom = bottom; self.trailing = trailing
    }
}

public struct InterfaceContext: Equatable, Sendable {
    public var systemIsDark = true
    public var backgroundOpacity = 1.0
    public var systemSidebarTextSize: Double = 11
    public var toolbarHovered = false
    public var toolbarRevealed = false
    public var paneHovered = false
    public var sidebarVisible = false
    public var isActivePane = true
    public var isActiveTab = true
    public var isActiveWindow = true
    public var inputIsProtected = false
    public var reduceMotion = false
    public var alternateScreen = false
    public var visibleWindowCount = 1
    public var tabCount = 1
    public var themeBackground = "#0B0B0C"
    public var themeForeground = "#ECECEE"
    public var themeAccent = "#85D7C1"
    public var themePaletteHighlight = "#82AAFF"
    public var programBackground: String?
    public init() {}
}

public struct InterfacePresentation: Equatable, Sendable {
    public var isDark = true
    public var glassChrome = false
    public var glassPanes = false
    public var chromeBackground = "#141416"
    public var chromeOpacity = 1.0
    public var paneOpacity = 1.0
    public var chromeForeground = "#ECECEE"
    public var accent = "#85D7C1"
    public var toolbarLayout = InterfaceToolbarLayout.above
    public var toolbarVisible = true
    public var toolbarOverlaysContent = false
    public var headerHeight: Double = 40
    public var reservedHeaderHeight: Double = 40
    public var sidebarWidth: Double = 216
    public var sidebarFontSize: Double = 11
    public var paneHeaderHeight: Double = 28
    public var paneHeaderVisible = true
    public var paneHeaderOverlaysContent = false
    public var reservedPaneHeaderHeight: Double = 28
    public var dividerWidth: Double = 5
    public var padding = InterfaceInsets()
    public var paddingBackground = "#0B0B0C"
    public var paneHeaderBackground = "#0B0B0C"
    public var tabIconCount = 5
    public var colorTabIcons = true
    public var shellIconTheme = InterfaceShellIconTheme.artwork
    public var fillTabs = false
    public var tabCount = 1
    public var tabBackgroundVisible = true
    public var highlightColor = "#85D7C1"
    public var highlightOpacity: Double = 0.35
    public var highlightAnimation = InterfaceHighlightAnimation.instant
    public var animationStyle = InterfaceAnimation.off
    public var fadeSurface = false
    public var backgroundMultiplier: Double = 1
    public var contentOpacity: Double = 1
    public var appIcon = InterfaceAppIcon.defaultDynamic
    public var showDockIcon = true
    public var showMenuBarIcon = false
    public var showWindowOnLaunch = true
    public init() {}
    public func equalTabWidth(available: Double, minimum: Double = 0) -> Double? {
        guard toolbarLayout == .above, available.isFinite, available > 0, tabCount > 0 else { return nil }
        let usable = max(0, available - (fillTabs ? 0 : min(24, available)))
        let width = usable / Double(tabCount)
        return max(minimum, fillTabs ? width : min(240, width))
    }
}

public struct InterfacePreferences: Codable, Equatable, Sendable {
    public var colorScheme = InterfaceColorScheme.dark
    public var style = InterfaceSurfaceStyle.classic
    public var tintWithTheme = false
    public var glassForPanes = false
    public var toolbarLayout = InterfaceToolbarLayout.above
    public var toolbarBehavior = InterfaceVisibility.always
    public var hiddenToolbarItems: Set<String> = []
    public func showsToolbarItem(_ item: InterfaceToolbarItem) -> Bool { !hiddenToolbarItems.contains(item.rawValue) }
    public var tabsFillAvailableSpace = false
    public var iconColor = InterfaceIconColor.always
    public var shellIconTheme = InterfaceShellIconTheme.artwork
    public var horizontalIconCount = 5
    public var verticalIconCount = 3
    public var paneStyle = InterfacePaneStyle.comfortable
    public var paneHeaderBehavior = InterfaceVisibility.always
    public var sidebarTextSize: Double? = 11
    public var sidebarWidth: Double = 216
    public var preserveWindowWidth = true
    public var sidebarGesture = InterfaceSidebarGesture.off
    public var paddingX: Double = 0
    public var paddingY: Double = 0
    public var paddingFill = InterfacePaddingFill.off
    public var includePaneHeaderInPaddingFill = false
    public var highlightActivePaneEdges = true
    public var highlightColor = InterfaceHighlightColor.accent
    public var highlightOpacity: Double = 0.35
    public var highlightAnimation = InterfaceHighlightAnimation.instant
    public var fadeInactivePanes = InterfaceFade.neither
    public var fadePanesForInactiveWindows = false
    public var autobalanceSplits = false
    public var focusFollowsMouse = false
    public var trackpadGestures = false
    public var animationStyle = InterfaceAnimation.off
    public var appIcon = InterfaceAppIcon.defaultDynamic
    public var iconVisibility = InterfaceIconVisibility.dockOnly
    public var showWindowOnLaunch = true
    public init() {}
    private enum CodingKeys: String, CodingKey { case colorScheme, style, tintWithTheme, glassForPanes, toolbarLayout, toolbarBehavior, hiddenToolbarItems, tabsFillAvailableSpace, iconColor, shellIconTheme, horizontalIconCount, verticalIconCount, paneStyle, paneHeaderBehavior, sidebarTextSize, sidebarWidth, preserveWindowWidth, sidebarGesture, paddingX, paddingY, paddingFill, includePaneHeaderInPaddingFill, highlightActivePaneEdges, highlightColor, highlightOpacity, highlightAnimation, fadeInactivePanes, fadePanesForInactiveWindows, autobalanceSplits, focusFollowsMouse, trackpadGestures, animationStyle, appIcon, iconVisibility, showWindowOnLaunch }
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        colorScheme = try box.decodeIfPresent(type(of: colorScheme), forKey: .colorScheme) ?? colorScheme
        style = try box.decodeIfPresent(type(of: style), forKey: .style) ?? style
        tintWithTheme = try box.decodeIfPresent(type(of: tintWithTheme), forKey: .tintWithTheme) ?? tintWithTheme
        glassForPanes = try box.decodeIfPresent(type(of: glassForPanes), forKey: .glassForPanes) ?? glassForPanes
        toolbarLayout = try box.decodeIfPresent(type(of: toolbarLayout), forKey: .toolbarLayout) ?? toolbarLayout
        toolbarBehavior = try box.decodeIfPresent(type(of: toolbarBehavior), forKey: .toolbarBehavior) ?? toolbarBehavior
        hiddenToolbarItems = try box.decodeIfPresent(Set<String>.self, forKey: .hiddenToolbarItems) ?? []
        tabsFillAvailableSpace = try box.decodeIfPresent(type(of: tabsFillAvailableSpace), forKey: .tabsFillAvailableSpace) ?? tabsFillAvailableSpace
        iconColor = try box.decodeIfPresent(type(of: iconColor), forKey: .iconColor) ?? iconColor
        shellIconTheme = try box.decodeIfPresent(type(of: shellIconTheme), forKey: .shellIconTheme) ?? shellIconTheme
        horizontalIconCount = try box.decodeIfPresent(type(of: horizontalIconCount), forKey: .horizontalIconCount) ?? horizontalIconCount
        verticalIconCount = try box.decodeIfPresent(type(of: verticalIconCount), forKey: .verticalIconCount) ?? verticalIconCount
        paneStyle = try box.decodeIfPresent(type(of: paneStyle), forKey: .paneStyle) ?? paneStyle
        paneHeaderBehavior = try box.decodeIfPresent(type(of: paneHeaderBehavior), forKey: .paneHeaderBehavior) ?? paneHeaderBehavior
        if box.contains(.sidebarTextSize) { sidebarTextSize = try box.decodeIfPresent(Double.self, forKey: .sidebarTextSize) }
        sidebarWidth = try box.decodeIfPresent(type(of: sidebarWidth), forKey: .sidebarWidth) ?? sidebarWidth
        preserveWindowWidth = try box.decodeIfPresent(type(of: preserveWindowWidth), forKey: .preserveWindowWidth) ?? preserveWindowWidth
        sidebarGesture = try box.decodeIfPresent(type(of: sidebarGesture), forKey: .sidebarGesture) ?? sidebarGesture
        paddingX = try box.decodeIfPresent(type(of: paddingX), forKey: .paddingX) ?? paddingX
        paddingY = try box.decodeIfPresent(type(of: paddingY), forKey: .paddingY) ?? paddingY
        paddingFill = try box.decodeIfPresent(type(of: paddingFill), forKey: .paddingFill) ?? paddingFill
        includePaneHeaderInPaddingFill = try box.decodeIfPresent(type(of: includePaneHeaderInPaddingFill), forKey: .includePaneHeaderInPaddingFill) ?? includePaneHeaderInPaddingFill
        highlightActivePaneEdges = try box.decodeIfPresent(type(of: highlightActivePaneEdges), forKey: .highlightActivePaneEdges) ?? highlightActivePaneEdges
        highlightColor = try box.decodeIfPresent(type(of: highlightColor), forKey: .highlightColor) ?? highlightColor
        highlightOpacity = try box.decodeIfPresent(type(of: highlightOpacity), forKey: .highlightOpacity) ?? highlightOpacity
        highlightAnimation = try box.decodeIfPresent(type(of: highlightAnimation), forKey: .highlightAnimation) ?? highlightAnimation
        fadeInactivePanes = try box.decodeIfPresent(type(of: fadeInactivePanes), forKey: .fadeInactivePanes) ?? fadeInactivePanes
        fadePanesForInactiveWindows = try box.decodeIfPresent(type(of: fadePanesForInactiveWindows), forKey: .fadePanesForInactiveWindows) ?? fadePanesForInactiveWindows
        autobalanceSplits = try box.decodeIfPresent(type(of: autobalanceSplits), forKey: .autobalanceSplits) ?? autobalanceSplits
        focusFollowsMouse = try box.decodeIfPresent(type(of: focusFollowsMouse), forKey: .focusFollowsMouse) ?? focusFollowsMouse
        trackpadGestures = try box.decodeIfPresent(type(of: trackpadGestures), forKey: .trackpadGestures) ?? trackpadGestures
        animationStyle = try box.decodeIfPresent(type(of: animationStyle), forKey: .animationStyle) ?? animationStyle
        appIcon = try box.decodeIfPresent(type(of: appIcon), forKey: .appIcon) ?? appIcon
        iconVisibility = try box.decodeIfPresent(type(of: iconVisibility), forKey: .iconVisibility) ?? iconVisibility
        showWindowOnLaunch = try box.decodeIfPresent(type(of: showWindowOnLaunch), forKey: .showWindowOnLaunch) ?? showWindowOnLaunch
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(colorScheme, forKey: .colorScheme)
        try box.encode(style, forKey: .style)
        try box.encode(tintWithTheme, forKey: .tintWithTheme)
        try box.encode(glassForPanes, forKey: .glassForPanes)
        try box.encode(toolbarLayout, forKey: .toolbarLayout)
        try box.encode(toolbarBehavior, forKey: .toolbarBehavior)
        try box.encode(hiddenToolbarItems.sorted(), forKey: .hiddenToolbarItems)
        try box.encode(tabsFillAvailableSpace, forKey: .tabsFillAvailableSpace)
        try box.encode(iconColor, forKey: .iconColor)
        try box.encode(shellIconTheme, forKey: .shellIconTheme)
        try box.encode(horizontalIconCount, forKey: .horizontalIconCount)
        try box.encode(verticalIconCount, forKey: .verticalIconCount)
        try box.encode(paneStyle, forKey: .paneStyle)
        try box.encode(paneHeaderBehavior, forKey: .paneHeaderBehavior)
        try box.encode(sidebarTextSize, forKey: .sidebarTextSize)
        try box.encode(sidebarWidth, forKey: .sidebarWidth)
        try box.encode(preserveWindowWidth, forKey: .preserveWindowWidth)
        try box.encode(sidebarGesture, forKey: .sidebarGesture)
        try box.encode(paddingX, forKey: .paddingX)
        try box.encode(paddingY, forKey: .paddingY)
        try box.encode(paddingFill, forKey: .paddingFill)
        try box.encode(includePaneHeaderInPaddingFill, forKey: .includePaneHeaderInPaddingFill)
        try box.encode(highlightActivePaneEdges, forKey: .highlightActivePaneEdges)
        try box.encode(highlightColor, forKey: .highlightColor)
        try box.encode(highlightOpacity, forKey: .highlightOpacity)
        try box.encode(highlightAnimation, forKey: .highlightAnimation)
        try box.encode(fadeInactivePanes, forKey: .fadeInactivePanes)
        try box.encode(fadePanesForInactiveWindows, forKey: .fadePanesForInactiveWindows)
        try box.encode(autobalanceSplits, forKey: .autobalanceSplits)
        try box.encode(focusFollowsMouse, forKey: .focusFollowsMouse)
        try box.encode(trackpadGestures, forKey: .trackpadGestures)
        try box.encode(animationStyle, forKey: .animationStyle)
        try box.encode(appIcon, forKey: .appIcon)
        try box.encode(iconVisibility, forKey: .iconVisibility)
        try box.encode(showWindowOnLaunch, forKey: .showWindowOnLaunch)
    }
    public func validate() throws {
        guard hiddenToolbarItems.count <= 64, hiddenToolbarItems.allSatisfy({
            !$0.isEmpty && $0.utf8.count <= 64 && $0.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { throw TerminalError.invalid("Invalid toolbar item visibility") }
        let bounded: [(Double, ClosedRange<Double>)] = [(paddingX, 0...64), (paddingY, 0...64), (sidebarWidth, 140...480), (highlightOpacity, 0...1)]
        guard bounded.allSatisfy({ $0.0.isFinite && $0.1.contains($0.0) }),
              sidebarTextSize.map({ $0.isFinite && (9...24).contains($0) }) ?? true,
              (0...5).contains(horizontalIconCount), (0...3).contains(verticalIconCount) else {
            throw TerminalError.invalid("Interface settings contain an out-of-range value")
        }
    }
    public func resolve(_ context: InterfaceContext) -> InterfacePresentation {
        var plan = InterfacePresentation()
        plan.isDark = colorScheme == .dark || (colorScheme == .automatic && context.systemIsDark)
        plan.glassChrome = style == .glass
        plan.glassPanes = style == .glass && glassForPanes
        let opacity = context.backgroundOpacity.isFinite ? min(1, max(AppearancePreferences.opacityRange.lowerBound, context.backgroundOpacity)) : 1
        plan.chromeOpacity = opacity < 1 ? opacity : (plan.glassChrome ? 0.72 : 1)
        plan.paneOpacity = opacity < 1 ? opacity : (plan.glassPanes ? 0.72 : 1)
        plan.chromeBackground = tintWithTheme ? context.themeBackground : (plan.isDark ? "#141416" : "#F5F5F7")
        plan.chromeForeground = tintWithTheme ? context.themeForeground : (plan.isDark ? "#ECECEE" : "#242426")
        plan.accent = tintWithTheme ? context.themeAccent : "#85D7C1"
        plan.toolbarLayout = toolbarLayout
        plan.toolbarVisible = toolbarBehavior == .always || (toolbarBehavior == .onHover && context.toolbarHovered) || context.toolbarRevealed
        if toolbarLayout != .above && !context.sidebarVisible { plan.toolbarVisible = false }
        plan.toolbarOverlaysContent = toolbarBehavior != .always
        plan.reservedHeaderHeight = toolbarBehavior == .always ? plan.headerHeight : 0
        plan.sidebarWidth = sidebarWidth
        plan.sidebarFontSize = sidebarTextSize ?? min(24, max(9, context.systemSidebarTextSize))
        plan.paneHeaderHeight = paneStyle == .compact ? 22 : 28
        plan.dividerWidth = paneStyle == .compact ? 1 : 5
        plan.paneHeaderVisible = paneHeaderBehavior == .always || (paneHeaderBehavior == .onHover && context.paneHovered)
        plan.paneHeaderOverlaysContent = paneHeaderBehavior == .onHover
        plan.reservedPaneHeaderHeight = paneHeaderBehavior == .always ? plan.paneHeaderHeight : 0
        plan.padding = InterfaceInsets(top: paneHeaderBehavior == .always ? 0 : paddingY, leading: paddingX, bottom: paddingY, trailing: paddingX)
        let useProgram = paddingFill == .always || (paddingFill == .automatic && context.alternateScreen)
        plan.paddingBackground = useProgram ? context.programBackground ?? context.themeBackground : context.themeBackground
        plan.paneHeaderBackground = includePaneHeaderInPaddingFill ? plan.paddingBackground : context.themeBackground
        plan.tabIconCount = toolbarLayout == .above ? horizontalIconCount : verticalIconCount
        switch iconColor {
        case .always: plan.colorTabIcons = true
        case .activePanes: plan.colorTabIcons = context.isActivePane
        case .activeTabs: plan.colorTabIcons = context.isActiveTab
        case .never: plan.colorTabIcons = false
        }
        plan.shellIconTheme = shellIconTheme
        plan.fillTabs = tabsFillAvailableSpace && toolbarLayout == .above
        plan.tabCount = max(0, context.tabCount)
        plan.tabBackgroundVisible = !plan.fillTabs || context.tabCount > 1
        switch highlightColor {
        case .accent: plan.highlightColor = plan.accent
        case .terminalPalette: plan.highlightColor = context.themePaletteHighlight
        case .terminalText: plan.highlightColor = context.themeForeground
        }
        plan.highlightOpacity = highlightActivePaneEdges ? highlightOpacity : 0
        plan.highlightAnimation = context.reduceMotion ? .instant : highlightAnimation
        plan.animationStyle = context.reduceMotion ? .off : animationStyle
        let inactive = !context.isActivePane || (fadePanesForInactiveWindows && !context.isActiveWindow)
        plan.fadeSurface = inactive && (fadeInactivePanes == .surface || fadeInactivePanes == .surfaceAndContent)
        plan.backgroundMultiplier = plan.fadeSurface ? 0.82 : 1
        plan.contentOpacity = inactive && (fadeInactivePanes == .content || fadeInactivePanes == .surfaceAndContent) ? 0.65 : 1
        plan.appIcon = appIcon
        switch iconVisibility {
        case .dockAndMenuBar: plan.showDockIcon = true; plan.showMenuBarIcon = true
        case .dockOnly: plan.showDockIcon = true; plan.showMenuBarIcon = false
        case .menuBarWhenNoWindows: plan.showDockIcon = context.visibleWindowCount > 0; plan.showMenuBarIcon = context.visibleWindowCount == 0
        }
        plan.showWindowOnLaunch = showWindowOnLaunch
        return plan
    }
    public func canFollowPointer(_ context: InterfaceContext) -> Bool {
        focusFollowsMouse && context.isActiveWindow && !context.inputIsProtected
    }
    public func gesture(_ gesture: InterfaceGesture, context: InterfaceContext) -> InterfaceGestureAction? {
        guard trackpadGestures, context.isActiveWindow, !context.inputIsProtected else { return nil }
        switch gesture {
        case .magnify(let delta):
            guard delta.isFinite, abs(delta) >= 0.08 else { return nil }
            return delta > 0 ? .zoomPane : .restorePane
        case .swipe(let delta, let option):
            guard toolbarLayout != .above, sidebarGesture != .off, delta.isFinite, abs(delta) >= 0.1,
                  (sidebarGesture == .optionSwipe) == option else { return nil }
            let show = toolbarLayout == .right ? delta < 0 : delta > 0
            return show ? .showSidebar : .hideSidebar
        }
    }
    public func windowWidthAfterSidebarChange(current: Double, showing: Bool, available: Double, fullScreen: Bool) -> Double {
        guard toolbarLayout != .above, !preserveWindowWidth, !fullScreen, current.isFinite, available.isFinite, available > 0 else { return current }
        return min(available, max(min(900, available), current + (showing ? 1 : -1) * (sidebarWidth + 1)))
    }
    public func treeAfterTopologyChange(previous: PaneTree, current: PaneTree, manuallyResizedSplits: Set<String>) -> PaneTree {
        guard autobalanceSplits, Set(previous.panes) != Set(current.panes) else { return current }
        func balance(_ tree: PaneTree) -> PaneTree {
            switch tree {
            case .pane: return tree
            case .split(let id, let axis, let ratio, let first, let second):
                return .split(id: id, axis: axis, ratio: manuallyResizedSplits.contains(id) ? ratio : 0.5, first: balance(first), second: balance(second))
            }
        }
        return balance(current)
    }
}

public struct InterfacePreferencesDraft {
    public let baseline: InterfacePreferences
    public var value: InterfacePreferences
    public init(_ value: InterfacePreferences) { baseline = value; self.value = value }
    public mutating func cancel() { value = baseline }
    public func applying(to current: InterfacePreferences) throws -> InterfacePreferences {
        var result = current
        func merge<T: Equatable>(_ key: WritableKeyPath<InterfacePreferences, T>) {
            if value[keyPath: key] != baseline[keyPath: key] { result[keyPath: key] = value[keyPath: key] }
        }
        merge(\.colorScheme)
        merge(\.style)
        merge(\.tintWithTheme)
        merge(\.glassForPanes)
        merge(\.toolbarLayout)
        merge(\.toolbarBehavior)
        for item in value.hiddenToolbarItems.symmetricDifference(baseline.hiddenToolbarItems) {
            if value.hiddenToolbarItems.contains(item) { result.hiddenToolbarItems.insert(item) }
            else { result.hiddenToolbarItems.remove(item) }
        }
        merge(\.tabsFillAvailableSpace)
        merge(\.iconColor)
        merge(\.shellIconTheme)
        merge(\.horizontalIconCount)
        merge(\.verticalIconCount)
        merge(\.paneStyle)
        merge(\.paneHeaderBehavior)
        merge(\.sidebarTextSize)
        merge(\.sidebarWidth)
        merge(\.preserveWindowWidth)
        merge(\.sidebarGesture)
        merge(\.paddingX)
        merge(\.paddingY)
        merge(\.paddingFill)
        merge(\.includePaneHeaderInPaddingFill)
        merge(\.highlightActivePaneEdges)
        merge(\.highlightColor)
        merge(\.highlightOpacity)
        merge(\.highlightAnimation)
        merge(\.fadeInactivePanes)
        merge(\.fadePanesForInactiveWindows)
        merge(\.autobalanceSplits)
        merge(\.focusFollowsMouse)
        merge(\.trackpadGestures)
        merge(\.animationStyle)
        merge(\.appIcon)
        merge(\.iconVisibility)
        merge(\.showWindowOnLaunch)
        try result.validate()
        return result
    }
}

private struct InterfaceEnvelope: Codable {
    var schemaVersion = 1
    var preferences = InterfacePreferences()
    var manuallyResizedSplits: Set<String> = []
}

public struct InterfacePreferencesStore {
    public let root: URL
    public init(root: URL) { self.root = root }
    private let name = "interface-preferences.json"
    private let maximum = 65_536

    private func withRoot<T>(_ action: (Int32) throws -> T) throws -> T {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TerminalError.invalid("Cannot open private interface settings directory") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw TerminalError.invalid("Interface settings directory must be private and owned")
        }
        return try action(fd)
    }
    private func readEnvelope(_ directory: Int32) throws -> InterfaceEnvelope {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return InterfaceEnvelope() }
        guard fd >= 0 else { throw TerminalError.invalid("Cannot open private interface settings") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o077 == 0, info.st_size >= 0, info.st_size <= maximum else {
            throw TerminalError.invalid("Interface settings must be a private owned regular file of at most 64 KiB")
        }
        var bytes = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while true {
            let count = read(fd, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw TerminalError.runtime("Cannot read interface settings") }
            if count == 0 { break }
            guard data.count + count <= maximum else { throw TerminalError.invalid("Interface settings exceed 64 KiB") }
            data.append(contentsOf: bytes.prefix(count))
        }
        let envelope = try JSONDecoder().decode(InterfaceEnvelope.self, from: data)
        guard envelope.schemaVersion == 1, envelope.manuallyResizedSplits.count <= 4096 else {
            throw TerminalError.invalid("Unsupported interface settings schema")
        }
        try envelope.preferences.validate()
        return envelope
    }
    private var rootMissing: Bool {
        var info = stat()
        return lstat(root.path, &info) < 0 && errno == ENOENT
    }
    private func mutate(_ action: (inout InterfaceEnvelope) throws -> Void) throws {
        if rootMissing, mkdir(root.path, 0o700) != 0, errno != EEXIST { throw TerminalError.runtime("Cannot create private interface settings directory") }
        try withRoot { directory in
            let lock = openat(directory, "interface-preferences.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lock >= 0 else { throw TerminalError.runtime("Cannot lock interface settings") }
            defer { close(lock) }
            var info = stat()
            guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
                  info.st_mode & 0o077 == 0, flock(lock, LOCK_EX) == 0 else { throw TerminalError.invalid("Interface settings lock is unsafe") }
            defer { _ = flock(lock, LOCK_UN) }
            var envelope = try readEnvelope(directory)
            try action(&envelope)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(envelope)
            guard data.count <= maximum else { throw TerminalError.invalid("Interface settings exceed 64 KiB") }
            let temporary = ".interface-write-" + UUID().uuidString
            let output = openat(directory, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw TerminalError.runtime("Cannot create interface settings") }
            defer { close(output); _ = unlinkat(directory, temporary, 0) }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw TerminalError.runtime("Cannot write interface settings") }
                    offset += count
                }
            }
            guard fsync(output) == 0, renameat(directory, temporary, directory, name) == 0 else { throw TerminalError.runtime("Cannot replace interface settings") }
        }
    }
    public func load() throws -> InterfacePreferences {
        if rootMissing { return InterfacePreferences() }
        return try withRoot { try readEnvelope($0).preferences }
    }
    public func save(_ value: InterfacePreferences, baseline: InterfacePreferences?) throws {
        try value.validate()
        try mutate { envelope in
            if let baseline {
                var draft = InterfacePreferencesDraft(baseline)
                draft.value = value
                envelope.preferences = try draft.applying(to: envelope.preferences)
            } else { envelope.preferences = value }
        }
    }
    public func manuallyResizedSplits() throws -> Set<String> {
        if rootMissing { return [] }
        return try withRoot { try readEnvelope($0).manuallyResizedSplits }
    }
    public func markManuallyResizedSplit(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 128, id.rangeOfCharacter(from: .controlCharacters) == nil else { throw TerminalError.invalid("Invalid split identifier") }
        try mutate { envelope in
            envelope.manuallyResizedSplits.insert(id)
            guard envelope.manuallyResizedSplits.count <= 4096 else { throw TerminalError.invalid("Too many manually resized splits") }
        }
    }
}

extension TerminalRuntime {
    public func interfacePreferences() throws -> InterfacePreferences {
        try transaction { try InterfacePreferencesStore(root: root).load() }
    }
    public func saveInterfacePreferences(_ value: InterfacePreferences, baseline: InterfacePreferences? = nil) throws {
        try transaction { try InterfacePreferencesStore(root: root).save(value, baseline: baseline) }
    }
    public func markInterfaceSplitManuallyResized(_ id: String) throws {
        try transaction { try InterfacePreferencesStore(root: root).markManuallyResizedSplit(id) }
    }
    func applyInterfaceTopology(from previous: WorkspaceLayout, to current: inout WorkspaceLayout) throws {
        let changed = current.tabs.filter { tab in previous.tabs.first(where: { $0.id == tab.id }).map { Set($0.panes) != Set(tab.panes) } ?? false }
        guard !changed.isEmpty else { return }
        let preferences = try InterfacePreferencesStore(root: root).load()
        guard preferences.autobalanceSplits else { return }
        let manual = try InterfacePreferencesStore(root: root).manuallyResizedSplits()
        for index in current.tabs.indices {
            guard let before = previous.tabs.first(where: { $0.id == current.tabs[index].id }) else { continue }
            current.tabs[index].tree = preferences.treeAfterTopologyChange(previous: before.tree, current: current.tabs[index].tree, manuallyResizedSplits: manual)
        }
    }
}
