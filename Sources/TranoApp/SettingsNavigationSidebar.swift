import AppKit
import SwiftUI

struct SettingsCategory: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let systemImage: String
    static let all: [SettingsCategory] = [
        .init(id: "interface", title: "Interface", systemImage: "rectangle.3.group"),
        .init(id: "themes", title: "Themes", systemImage: "swatchpalette"),
        .init(id: "terminal", title: "Terminal", systemImage: "terminal"),
        .init(id: "profiles", title: "Profiles", systemImage: "rectangle.stack"),
        .init(id: "shortcuts", title: "Shortcuts", systemImage: "keyboard"),
        .init(id: "notifications", title: "Notifications", systemImage: "bell"),
        .init(id: "server", title: "Server", systemImage: "server.rack"),
        .init(id: "integrations", title: "Integrations", systemImage: "puzzlepiece.extension"),
        .init(id: "developer", title: "Developer", systemImage: "hammer"),
        .init(id: "general", title: "General", systemImage: "gearshape"),
        .init(id: "updates", title: "Updates", systemImage: "arrow.down.circle"),
        .init(id: "appearance", title: "Appearance", systemImage: "paintpalette"),
    ]
}

struct SettingsNavigationSidebar: NSViewRepresentable {
    @Binding var selection: String
    var canNavigate: (String) -> Bool = { _ in true }
    var visibleCategoryIDs: Set<String>? = nil

    func makeNSView(context: Context) -> SettingsNavigationSidebarView {
        makeNativeView(enabled: context.environment.isEnabled, theme: context.environment.toolPanelTheme)
    }

    func updateNSView(_ view: SettingsNavigationSidebarView, context: Context) {
        updateNativeView(view, enabled: context.environment.isEnabled, theme: context.environment.toolPanelTheme)
    }

    func makeNativeView(enabled: Bool = true, theme: ToolPanelTheme = .defaultDark) -> SettingsNavigationSidebarView {
        let view = SettingsNavigationSidebarView(frame: .zero)
        updateNativeView(view, enabled: enabled, theme: theme)
        return view
    }

    func updateNativeView(_ view: SettingsNavigationSidebarView, enabled: Bool = true, theme: ToolPanelTheme = .defaultDark) {
        view.apply(theme: theme)
        view.update(selection: selection, enabled: enabled, visibleCategoryIDs: visibleCategoryIDs) { id in
            guard selection != id, canNavigate(id) else { return selection }
            selection = id
            return selection
        }
    }
}

final class SettingsNavigationSidebarView: NSView {
    private var panelTheme = ToolPanelTheme.defaultDark
    func apply(theme: ToolPanelTheme) {
        panelTheme = theme; appearance = theme.appearance
        for button in buttons { button.panelTheme = theme }
        needsDisplay = true
    }
    private let scrollView = NSScrollView()
    private let document = SettingsSidebarDocumentView()
    let buttons = SettingsCategory.all.map { SettingsCategoryButton($0) }
    private(set) var selectedID = ""
    private var requestSelection: ((String) -> String)?
    private var enabled = true
    private let rowHeight: CGFloat = 30
    private let rowSpacing: CGFloat = 2
    private let inset: CGFloat = 8

    override var acceptsFirstResponder: Bool { false }
    override var isOpaque: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 148, height: contentHeight) }
    private var visibleButtons: [SettingsCategoryButton] { buttons.filter { !$0.isHidden } }
    private var contentHeight: CGFloat {
        let count = visibleButtons.count
        return inset * 2 + CGFloat(count) * rowHeight + CGFloat(max(0, count - 1)) * rowSpacing
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = document
        addSubview(scrollView)
        for button in buttons {
            button.onPress = { [weak self, id = button.categoryID] in self?.activate(id) }
            document.addSubview(button)
        }
        setAccessibilityLabel("Settings categories")
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let size = scrollView.contentSize
        document.frame = NSRect(x: 0, y: 0, width: size.width, height: max(size.height, contentHeight))
        for button in buttons where button.isHidden { button.frame = .zero }
        for (index, button) in visibleButtons.enumerated() {
            button.frame = NSRect(x: inset, y: inset + CGFloat(index) * (rowHeight + rowSpacing),
                                  width: max(0, size.width - inset * 2), height: rowHeight)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        panelTheme.backgroundNS.setFill()
        bounds.intersection(dirtyRect).fill()
    }

    func update(selection: String, enabled: Bool, visibleCategoryIDs: Set<String>?, requestSelection: @escaping (String) -> String) {
        self.requestSelection = requestSelection
        self.enabled = enabled
        selectedID = selection
        var visibilityChanged = false
        for button in buttons {
            let hidden = visibleCategoryIDs.map { !$0.contains(button.categoryID) } ?? false
            if button.isHidden != hidden {
                button.isHidden = hidden
                visibilityChanged = true
            }
        }
        if visibilityChanged {
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
        refreshButtons()
    }

    private func activate(_ id: String) {
        defer { refreshButtons() }
        guard enabled, id != selectedID, buttons.contains(where: { $0.categoryID == id && !$0.isHidden }) else { return }
        if let editor = window?.firstResponder as? NSTextInputClient, editor.hasMarkedText() { return }
        if let actual = requestSelection?(id) { selectedID = actual }
    }

    private func refreshButtons() {
        for (button, category) in zip(buttons, SettingsCategory.all) {
            if button.title != category.title { button.title = category.title }
            button.isEnabled = enabled && !button.isHidden
            button.isCurrent = button.categoryID == selectedID
        }
    }
}

final class SettingsCategoryButton: NSButton {
    let categoryID: String
    var onPress: (() -> Void)?
    var panelTheme = ToolPanelTheme.defaultDark { didSet { updateTint() } }
    private func updateTint() {
        contentTintColor = isCurrent ? panelTheme.foregroundNS : panelTheme.secondaryNS
        needsDisplay = true
    }
    var isCurrent = false {
        didSet {
            state = isCurrent ? .on : .off
            updateTint()
        }
    }

    override var acceptsFirstResponder: Bool { false }

    init(_ category: SettingsCategory) {
        categoryID = category.id
        super.init(frame: .zero)
        setButtonType(.pushOnPushOff)
        isBordered = false
        bezelStyle = .rounded
        focusRingType = .none
        alignment = .left
        font = .systemFont(ofSize: ToolPanelMetrics.bodySize)
        title = category.title
        image = NSImage(systemSymbolName: category.systemImage, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        target = self
        action = #selector(pressed)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(category.title)
        setAccessibilityIdentifier("settings.category." + category.id)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        if isCurrent {
            panelTheme.accentNS.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }

    @objc private func pressed() { onPress?() }
}

private final class SettingsSidebarDocumentView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
}
