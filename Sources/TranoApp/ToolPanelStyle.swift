import AppKit
import SwiftUI
import TerminalCore

struct ToolPanelTheme: Equatable, Sendable {
    let backgroundHex: String
    let foregroundHex: String
    let accentHex: String
    let isDark: Bool
    init(background: String, foreground: String, accent: String, isDark: Bool) {
        backgroundHex = background; foregroundHex = foreground; accentHex = accent; self.isDark = isDark
    }
    static let defaultDark = ToolPanelTheme(background: "#141416", foreground: "#ECECEE", accent: "#85D7C1", isDark: true)
    var backgroundNS: NSColor { NSColor(hex: backgroundHex) }
    var foregroundNS: NSColor { NSColor(hex: foregroundHex) }
    var secondaryNS: NSColor { foregroundNS.withAlphaComponent(0.65) }
    var accentNS: NSColor { NSColor(hex: accentHex) }
    var borderNS: NSColor { foregroundNS.withAlphaComponent(0.12) }
    var background: Color { Color(nsColor: backgroundNS) }
    var foreground: Color { Color(nsColor: foregroundNS) }
    var secondary: Color { Color(nsColor: secondaryNS) }
    var accent: Color { Color(nsColor: accentNS) }
    var border: Color { Color(nsColor: borderNS) }
    var colorScheme: ColorScheme { isDark ? .dark : .light }
    var appearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }
}

enum ToolPanelMetrics {
    static let headerHeight: CGFloat = 40
    static let titleSize: CGFloat = 13
    static let bodySize: CGFloat = 12
    static let captionSize: CGFloat = 11
    static let contentInset: CGFloat = 16
    static let sectionSpacing: CGFloat = 12
    static let cornerRadius: CGFloat = 8
    static let closeControlSize: CGFloat = 24
}

private struct ToolPanelThemeKey: EnvironmentKey {
    static let defaultValue = ToolPanelTheme.defaultDark
}

extension EnvironmentValues {
    var toolPanelTheme: ToolPanelTheme {
        get { self[ToolPanelThemeKey.self] }
        set { self[ToolPanelThemeKey.self] = newValue }
    }
}

extension AppStore {
    var toolPanelTheme: ToolPanelTheme {
        let settings = interfaceResolvedSettings(for: focusedID ?? "")
        var context = InterfaceContext()
        context.systemIsDark = interfaceThemeMode == .dark
        context.themeBackground = settings.background
        context.themeForeground = settings.appearance.foreground
        context.themeAccent = settings.appearance.ansiColors.count > 6 ? settings.appearance.ansiColors[6] : "#85D7C1"
        let plan = interfacePreferences.resolve(context)
        return ToolPanelTheme(background: plan.chromeBackground, foreground: plan.chromeForeground, accent: plan.accent, isDark: plan.isDark)
    }
}

struct ToolPanelCloseButton: NSViewRepresentable {
    let label: String
    var enabled = true
    let action: () -> Void
    func makeNSView(context: Context) -> ToolPanelCloseNativeButton {
        let button = ToolPanelCloseNativeButton()
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        button.target = button; button.action = #selector(ToolPanelCloseNativeButton.closePanel)
        return button
    }
    func updateNSView(_ button: ToolPanelCloseNativeButton, context: Context) {
        button.appearance = context.environment.toolPanelTheme.appearance
        button.contentTintColor = context.environment.toolPanelTheme.foregroundNS
        button.isEnabled = enabled && context.environment.isEnabled
        button.toolTip = label; button.setAccessibilityLabel(label); button.onClose = action
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ToolPanelCloseNativeButton, context: Context) -> CGSize? {
        CGSize(width: ToolPanelMetrics.closeControlSize, height: ToolPanelMetrics.closeControlSize)
    }
    static func dismantleNSView(_ button: ToolPanelCloseNativeButton, coordinator: ()) {
        button.onClose = {}; button.target = nil; button.action = nil
    }
}

final class ToolPanelCloseNativeButton: NSButton {
    var onClose: () -> Void = {}
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var intrinsicContentSize: NSSize { NSSize(width: ToolPanelMetrics.closeControlSize, height: ToolPanelMetrics.closeControlSize) }
    @objc func closePanel() { if isEnabled { onClose() } }
}

struct ToolPanelHeader: View {
    let title: String
    var symbol: String?
    var leading: AnyView?
    var trailing: AnyView?
    var canClose = true
    var closeLabel: String?
    let onClose: () -> Void
    @Environment(\.toolPanelTheme) private var theme
    init(_ title: String, symbol: String? = nil, leading: AnyView? = nil, trailing: AnyView? = nil,
         canClose: Bool = true, closeLabel: String? = nil, onClose: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.leading = leading; self.trailing = trailing
        self.canClose = canClose; self.closeLabel = closeLabel; self.onClose = onClose
    }
    var body: some View {
        HStack(spacing: 8) {
            if let leading { leading }
            else if let symbol { Image(systemName: symbol).foregroundStyle(theme.accent) }
            Text(title).font(.system(size: ToolPanelMetrics.titleSize, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            if let trailing { trailing }
            ToolPanelCloseButton(label: closeLabel ?? "Close " + title, enabled: canClose, action: onClose)
        }.padding(.horizontal, ToolPanelMetrics.contentInset).frame(height: ToolPanelMetrics.headerHeight)
            .overlay(alignment: .bottom) { theme.border.frame(height: 1).allowsHitTesting(false) }
            .background(WorkspaceRegion("tool-panel-header", label: title))
    }
}

final class ToolPanelSurfaceView: NSView {
    var theme = ToolPanelTheme.defaultDark { didSet { applyTheme() } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyTheme() }
    private func applyTheme() {
        appearance = theme.appearance
        needsDisplay = true
        if let window = window as? WorkspaceToolPanelWindow {
            window.appearance = theme.appearance
            if let scroll = window.contentView as? NSScrollView {
                scroll.drawsBackground = false; scroll.contentView.drawsBackground = false
                scroll.backgroundColor = theme.backgroundNS
            }
        }
    }
    override func draw(_ dirtyRect: NSRect) { theme.backgroundNS.setFill(); bounds.intersection(dirtyRect).fill() }
}

private struct ToolPanelSurfaceBackground: NSViewRepresentable {
    let theme: ToolPanelTheme
    func makeNSView(context: Context) -> ToolPanelSurfaceView {
        let view = ToolPanelSurfaceView()
        view.identifier = NSUserInterfaceItemIdentifier("tool-panel-surface")
        return view
    }
    func updateNSView(_ view: ToolPanelSurfaceView, context: Context) { view.theme = theme }
}

extension View {
    func toolPanelSurface(_ theme: ToolPanelTheme) -> some View {
        environment(\.toolPanelTheme, theme)
            .font(.system(size: ToolPanelMetrics.bodySize)).controlSize(.small)
            .foregroundStyle(theme.foreground).tint(theme.accent).preferredColorScheme(theme.colorScheme)
            .scrollContentBackground(.hidden)
            .background(ToolPanelSurfaceBackground(theme: theme))
            .clipShape(RoundedRectangle(cornerRadius: ToolPanelMetrics.cornerRadius))
            .overlay { RoundedRectangle(cornerRadius: ToolPanelMetrics.cornerRadius).stroke(theme.border, lineWidth: 1).allowsHitTesting(false) }
            .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }
}
