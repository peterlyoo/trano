import AppKit
import SwiftUI
import TerminalCore

struct InterfaceSettingsForm: NSViewRepresentable {
    @Binding var value: InterfacePreferences
    func makeNSView(context: Context) -> InterfaceSettingsControls {
        InterfaceSettingsControls(value: value) { value = $0 }
    }
    func updateNSView(_ view: InterfaceSettingsControls, context: Context) { view.update(value) }
}

@MainActor final class InterfaceSettingsControls: NSScrollView {
    static let settingIDs = [
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

    private(set) var value: InterfacePreferences
    private let changed: (InterfacePreferences) -> Void
    private var synchronizers: [(InterfacePreferences) -> Void] = []
    private let stack = NSStackView()

    init(value: InterfacePreferences, changed: @escaping (InterfacePreferences) -> Void) {
        self.value = value
        self.changed = changed
        super.init(frame: .zero)
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        borderType = .noBorder
        let document = InterfaceSettingsDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        documentView = document
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])
        build()
        update(value)
    }

    required init?(coder: NSCoder) { return nil }

    func update(_ value: InterfacePreferences) {
        self.value = value
        for synchronize in synchronizers { synchronize(value) }
    }

    private func set<Value>(_ keyPath: WritableKeyPath<InterfacePreferences, Value>, to newValue: Value) {
        var next = value
        next[keyPath: keyPath] = newValue
        update(next)
        changed(next)
    }

    private func build() {
        section("Appearance", [
            menu("appearance-color-scheme", "Color scheme", \.colorScheme, [("Auto", .automatic), ("Light", .light), ("Dark", .dark)]),
            menu("appearance-interface-style", "Interface style", \.style, [("Glass", .glass), ("Classic", .classic)]),
            toggle("appearance-tint-with-theme", "Tint with theme", \.tintWithTheme),
            toggle("appearance-use-glass-for-panes", "Use glass for panes", \.glassForPanes, enabled: { $0.style == .glass })
        ])
        section("Toolbar", [
            menu("toolbar-toolbar-layout", "Toolbar layout", \.toolbarLayout, [("Above", .above), ("Left Side", .left), ("Right Side", .right)]),
            menu("toolbar-toolbar-behavior", "Toolbar behavior", \.toolbarBehavior, visibilityChoices),
            toggle("tab-behavior-tabs-fill-available-space", "Tabs fill available space", \.tabsFillAvailableSpace, enabled: { $0.toolbarLayout == .above })
        ])
        section("Tab Icons", [
            menu("tab-icons-use-color-for-tab-icons", "Use color for tab icons", \.iconColor, [("Always", .always), ("For active panes", .activePanes), ("For active tabs", .activeTabs), ("Never", .never)]),
            menu("tab-icons-shell-icon-theme", "Shell icon theme", \.shellIconTheme, [("Default", .artwork), ("Use theme", .theme), ("Use theme accent", .accent)]),
            iconCounts()
        ])
        section("Panes", [
            menu("panes-pane-style", "Pane style", \.paneStyle, [("Comfortable", .comfortable), ("Compact", .compact)]),
            menu("panes-pane-header-behavior", "Pane header behavior", \.paneHeaderBehavior, visibilityChoices)
        ])
        section("Window", [
            menu("window-sidebar-text-size", "Sidebar text size", \.sidebarTextSize, [("System", nil)] + (9...24).map { ("\($0) pt", Optional(Double($0))) }, enabled: { $0.toolbarLayout != .above }),
            toggle("window-preserve-width-when-resizing-sidebar", "Preserve width when resizing sidebar", \.preserveWindowWidth, enabled: { $0.toolbarLayout != .above }),
            menu("window-use-a-gesture-to-toggle-the-sidebar", "Use a gesture to toggle the sidebar", \.sidebarGesture, [("Swipe", .swipe), ("Option-swipe", .optionSwipe), ("Off", .off)], enabled: { $0.toolbarLayout != .above && $0.trackpadGestures })
        ])
        section("Padding", [
            slider("padding-padding-x", "Padding X", \.paddingX, range: 0...64, step: 1, format: { "\(Int($0)) pt" }),
            slider("padding-padding-y", "Padding Y", \.paddingY, range: 0...64, step: 1, format: { "\(Int($0)) pt" }),
            menu("padding-fill-with-program-colors", "Fill with program colors", \.paddingFill, [("Off", .off), ("Automatic", .automatic), ("Always", .always)]),
            toggle("padding-include-pane-header", "Include pane header", \.includePaneHeaderInPaddingFill, enabled: { $0.paddingFill != .off })
        ])
        section("Active Pane", [
            toggle("active-pane-highlight-active-pane-edges", "Highlight active pane edges", \.highlightActivePaneEdges),
            menu("active-pane-highlight-color", "Highlight color", \.highlightColor, [("Accent", .accent), ("Terminal palette color", .terminalPalette), ("Terminal text color", .terminalText)], enabled: { $0.highlightActivePaneEdges }),
            slider("active-pane-highlight-opacity", "Highlight opacity", \.highlightOpacity, range: 0...1, step: 0.01, format: { "\(Int(($0 * 100).rounded()))%" }, enabled: { $0.highlightActivePaneEdges }),
            menu("active-pane-animate-active-pane-highlight", "Animate active pane highlight", \.highlightAnimation, [("Fade", .fade), ("Move", .move), ("Instant", .instant)], enabled: { $0.highlightActivePaneEdges }),
            menu("active-pane-fade-inactive-panes", "Fade inactive panes", \.fadeInactivePanes, [("Neither", .neither), ("Surface", .surface), ("Content", .content), ("Surface & content", .surfaceAndContent)]),
            toggle("active-pane-fade-panes-for-inactive-windows", "Fade panes for inactive windows", \.fadePanesForInactiveWindows, enabled: { $0.fadeInactivePanes != .neither })
        ])
        section("Splits & Focus", [
            toggle("splits-focus-autobalance-splits", "Autobalance splits", \.autobalanceSplits),
            toggle("splits-focus-focus-follows-mouse", "Focus follows mouse", \.focusFollowsMouse)
        ])
        section("Gestures & Animation", [
            toggle("gestures-use-trackpad-gestures", "Use trackpad gestures", \.trackpadGestures),
            menu("animation-animation-style", "Animation style", \.animationStyle, [("Snappy", .snappy), ("Natural", .natural), ("Off", .off)])
        ])
        section("App Icon", [
            menu("app-icon-app-icon", "App Icon", \.appIcon, [("Default — Dynamic", .defaultDynamic), ("Bright", .bright), ("Twilight", .twilight)]),
            menu("app-icon-show-app-icon", "Show app icon", \.iconVisibility, [("Dock and menu bar", .dockAndMenuBar), ("Dock only", .dockOnly), ("Menu bar only while no window is open", .menuBarWhenNoWindows)])
        ])
        section("Launch", [toggle("launch-show-window-on-launch", "Show window on launch", \.showWindowOnLaunch)])
    }

    private var visibilityChoices: [(String, InterfaceVisibility)] {
        [("Always show", .always), ("Show on hover", .onHover), ("Hidden", .hidden)]
    }

    private func section(_ title: String, _ rows: [NSView]) {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 12
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        group.addArrangedSubview(heading)
        for row in rows {
            group.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        }
        stack.addArrangedSubview(group)
        group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func row(_ suffix: String, _ title: String, control: NSView) -> NSView {
        let label = NSTextField(wrappingLabelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.maximumNumberOfLines = 2
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.identifier = NSUserInterfaceItemIdentifier("setting-" + suffix + "-row")
        control.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: 246).isActive = true
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.setCustomSpacing(16, after: label)
        return row
    }

    private func menu<Value: Equatable>(_ suffix: String, _ title: String, _ keyPath: WritableKeyPath<InterfacePreferences, Value>, _ choices: [(String, Value)], enabled: @escaping (InterfacePreferences) -> Bool = { _ in true }) -> NSView {
        let control = InterfaceMenuControl(choices: choices.map(\.0)) { [weak self] index in
            guard choices.indices.contains(index) else { return }
            self?.set(keyPath, to: choices[index].1)
        }
        control.identifier = NSUserInterfaceItemIdentifier("setting-" + suffix)
        control.setAccessibilityLabel(title)
        synchronizers.append { [weak control] value in
            control?.selectItem(at: choices.firstIndex { $0.1 == value[keyPath: keyPath] } ?? -1)
            control?.isEnabled = enabled(value)
        }
        return row(suffix, title, control: control)
    }

    private func toggle(_ suffix: String, _ title: String, _ keyPath: WritableKeyPath<InterfacePreferences, Bool>, enabled: @escaping (InterfacePreferences) -> Bool = { _ in true }) -> NSView {
        let control = InterfaceToggleControl { [weak self] isOn in self?.set(keyPath, to: isOn) }
        control.identifier = NSUserInterfaceItemIdentifier("setting-" + suffix)
        control.setAccessibilityLabel(title)
        synchronizers.append { [weak control] value in
            control?.state = value[keyPath: keyPath] ? .on : .off
            control?.isEnabled = enabled(value)
        }
        return row(suffix, title, control: control)
    }

    private func slider(_ suffix: String, _ title: String, _ keyPath: WritableKeyPath<InterfacePreferences, Double>, range: ClosedRange<Double>, step: Double, format: @escaping (Double) -> String, enabled: @escaping (InterfacePreferences) -> Bool = { _ in true }) -> NSView {
        let control = InterfaceSliderControl(range: range, step: step) { [weak self] number in self?.set(keyPath, to: number) }
        control.identifier = NSUserInterfaceItemIdentifier("setting-" + suffix)
        control.setAccessibilityLabel(title)
        let text = NSTextField(labelWithString: "")
        text.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        text.textColor = .secondaryLabelColor
        text.alignment = .right
        text.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let container = NSStackView(views: [control, text])
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 8
        synchronizers.append { [weak control, weak text] value in
            let number = value[keyPath: keyPath]
            control?.doubleValue = number
            control?.isEnabled = enabled(value)
            text?.stringValue = format(number)
            text?.textColor = enabled(value) ? .secondaryLabelColor : .disabledControlTextColor
        }
        return row(suffix, title, control: container)
    }

    private func iconCounts() -> NSView {
        let horizontal = InterfaceMenuControl(choices: (0...5).map(String.init)) { [weak self] in self?.set(\.horizontalIconCount, to: $0) }
        let vertical = InterfaceMenuControl(choices: (0...3).map(String.init)) { [weak self] in self?.set(\.verticalIconCount, to: $0) }
        horizontal.identifier = NSUserInterfaceItemIdentifier("setting-tab-icons-show-tab-icons-horizontal")
        vertical.identifier = NSUserInterfaceItemIdentifier("setting-tab-icons-show-tab-icons-vertical")
        horizontal.setAccessibilityLabel("Horizontal tab icons")
        vertical.setAccessibilityLabel("Vertical tab icons")
        let hLabel = NSTextField(labelWithString: "Above")
        let vLabel = NSTextField(labelWithString: "Side")
        for label in [hLabel, vLabel] { label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor }
        let container = NSStackView(views: [hLabel, horizontal, vLabel, vertical])
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 6
        container.identifier = NSUserInterfaceItemIdentifier("setting-tab-icons-show-tab-icons")
        synchronizers.append { [weak horizontal, weak vertical] value in
            horizontal?.selectItem(at: value.horizontalIconCount)
            vertical?.selectItem(at: value.verticalIconCount)
        }
        return row("tab-icons-show-tab-icons", "Show tab icons", control: container)
    }
}

@MainActor private final class InterfaceSettingsDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private final class InterfaceMenuControl: NSPopUpButton {
    private let invoke: (Int) -> Void
    init(choices: [String], invoke: @escaping (Int) -> Void) {
        self.invoke = invoke
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: choices)
        font = .systemFont(ofSize: 12)
        target = self
        action = #selector(invokeInterfaceMenu(_:))
    }
    required init?(coder: NSCoder) { return nil }
    @objc private func invokeInterfaceMenu(_ sender: NSPopUpButton) { invoke(indexOfSelectedItem) }
}

@MainActor private final class InterfaceToggleControl: NSButton {
    private let invoke: (Bool) -> Void
    init(invoke: @escaping (Bool) -> Void) {
        self.invoke = invoke
        super.init(frame: .zero)
        setButtonType(.switch)
        title = ""
        target = self
        action = #selector(invokeInterfaceToggle(_:))
    }
    required init?(coder: NSCoder) { return nil }
    @objc private func invokeInterfaceToggle(_ sender: NSButton) { invoke(state == .on) }
}

@MainActor private final class InterfaceSliderControl: NSSlider {
    private let step: Double
    private let invoke: (Double) -> Void
    init(range: ClosedRange<Double>, step: Double, invoke: @escaping (Double) -> Void) {
        self.step = step
        self.invoke = invoke
        super.init(frame: .zero)
        minValue = range.lowerBound
        maxValue = range.upperBound
        isContinuous = true
        target = self
        action = #selector(invokeInterfaceSlider(_:))
    }
    required init?(coder: NSCoder) { return nil }
    @objc private func invokeInterfaceSlider(_ sender: NSSlider) {
        let number = min(maxValue, max(minValue, (doubleValue / step).rounded() * step))
        doubleValue = number
        invoke(number)
    }
}
