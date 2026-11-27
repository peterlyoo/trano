import AppKit
import SwiftUI
import TerminalCore

extension InterfacePresentation {
    var swiftUIAnimation: Animation? {
        switch animationStyle {
        case .off: nil
        case .snappy: .easeOut(duration: 0.12)
        case .natural: .spring(response: 0.28, dampingFraction: 0.9)
        }
    }
    var insets: EdgeInsets { EdgeInsets(top: padding.top, leading: padding.leading, bottom: padding.bottom, trailing: padding.trailing) }
}

struct InterfaceMaterialBackground: NSViewRepresentable {
    let enabled: Bool
    let dark: Bool
    var opacity = 1.0
    func makeNSView(context: Context) -> NSVisualEffectView { InterfaceMaterialView() }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { apply(to: view) }
    func apply(to view: NSVisualEffectView) {
        let alpha = opacity.isFinite ? min(1, max(0, opacity)) : 1
        view.isHidden = !enabled || alpha == 0
        view.alphaValue = alpha
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .underWindowBackground
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
}

final class InterfaceMaterialView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct InterfacePaddingMask: Shape {
    let insets: EdgeInsets
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        let inner = CGRect(x: rect.minX + insets.leading, y: rect.minY + insets.top,
            width: max(0, rect.width - insets.leading - insets.trailing), height: max(0, rect.height - insets.top - insets.bottom))
        if !inner.isEmpty { path.addRect(inner) }
        return path
    }
}

struct InterfacePaneChrome<Header: View, Content: View>: View {
    let plan: InterfacePresentation
    let active: Bool
    let namespace: Namespace.ID
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            if !plan.paneHeaderOverlaysContent && plan.paneHeaderVisible { headerSurface }
            content().padding(plan.insets)
                .background {
                    InterfacePaddingMask(insets: plan.insets)
                        .fill(Color(nsColor: NSColor(hex: plan.paddingBackground)), style: FillStyle(eoFill: true))
                        .colorMultiply(Color(white: plan.backgroundMultiplier)).opacity(plan.paneOpacity)
                }
        }
        .overlay(alignment: .top) {
            if plan.paneHeaderOverlaysContent && plan.paneHeaderVisible { headerSurface }
        }
        .overlay {
            if active && plan.highlightOpacity > 0 {
                if plan.highlightAnimation == .move {
                    Rectangle().strokeBorder(Color(nsColor: NSColor(hex: plan.highlightColor)).opacity(plan.highlightOpacity), lineWidth: 1)
                        .matchedGeometryEffect(id: "interface-focused-pane", in: namespace)
                        .allowsHitTesting(false)
                } else {
                    Rectangle().strokeBorder(Color(nsColor: NSColor(hex: plan.highlightColor)).opacity(plan.highlightOpacity), lineWidth: 1)
                        .transition(plan.highlightAnimation == .fade ? .opacity : .identity)
                        .allowsHitTesting(false)
                }
            }
        }
        .animation(plan.highlightAnimation == .instant ? nil : (plan.swiftUIAnimation ?? .easeOut(duration: 0.15)), value: active)
    }
    private var headerSurface: some View {
        header().frame(height: plan.paneHeaderHeight)
            .background(Color(nsColor: NSColor(hex: plan.paneHeaderBackground)).colorMultiply(Color(white: plan.backgroundMultiplier)).opacity(plan.paneOpacity))
    }
}

@MainActor enum InterfaceWindowEffects {
    static func apply(_ plan: InterfacePresentation, to window: NSWindow) {
        window.appearance = NSAppearance(named: plan.isDark ? .darkAqua : .aqua)
        WorkspaceWindow.applyInterface(plan, to: window)
        guard !window.styleMask.contains(.fullScreen) else { return }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = !plan.toolbarVisible
        }
    }
    static func resizeSidebar(_ window: NSWindow, preferences: InterfacePreferences, previous: Double, next: Double) {
        guard !preferences.preserveWindowWidth, preferences.toolbarLayout != .above, !window.styleMask.contains(.fullScreen),
              let screen = window.screen, previous.isFinite, next.isFinite else { return }
        var frame = window.frame
        frame.size.width = min(screen.visibleFrame.width, max(window.minSize.width, frame.width + next - previous))
        frame.origin.x = min(max(frame.minX, screen.visibleFrame.minX), screen.visibleFrame.maxX - frame.width)
        window.setFrame(frame, display: true, animate: false)
    }
}

@MainActor final class InterfaceWindowContext: ObservableObject {
    @Published private(set) var isKey = false
    @Published private(set) var systemIsDark = true
    @Published private(set) var reduceMotion = false
    @Published private(set) var systemSidebarFontSize: Double = 11
    private let sidebarSizing = NSOutlineView()
    private var refreshScheduled = false
    private var appearanceObserver: NSKeyValueObservation?
    private weak var window: NSWindow?
    private var notifications: [NSObjectProtocol] = []
    func attach(_ window: NSWindow?) {
        guard self.window !== window else { return }
        for token in notifications {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        notifications = []
        self.window = window
        if appearanceObserver == nil {
            appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
        sidebarSizing.style = .sourceList
        sidebarSizing.rowSizeStyle = .default
        refresh()
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSApplication.didChangeScreenParametersNotification, UserDefaults.didChangeNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: [NSApplication.didChangeScreenParametersNotification, UserDefaults.didChangeNotification].contains(name) ? nil : window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } })
        }
        notifications.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } })
    }
    func refresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.publishCurrentState()
        }
    }
    private func publishCurrentState() {
        let key = window?.isKeyWindow ?? false
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let motion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let size: Double
        switch sidebarSizing.effectiveRowSizeStyle {
        case .small: size = 11
        case .large: size = 15
        default: size = 13
        }
        if isKey != key { isKey = key }
        if systemIsDark != dark { systemIsDark = dark }
        if reduceMotion != motion { reduceMotion = motion }
        if systemSidebarFontSize != size { systemSidebarFontSize = size }
    }
    deinit {
        for token in notifications {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }
}

struct InterfaceWindowAttachment: NSViewRepresentable {
    let state: InterfaceWindowContext
    let plan: InterfacePresentation
    func makeNSView(context: Context) -> Attachment { Attachment(state: state, plan: plan) }
    func updateNSView(_ view: Attachment, context: Context) {
        view.plan = plan
        state.attach(view.window)
        if let window = view.window { InterfaceWindowEffects.apply(plan, to: window) }
    }
    @MainActor final class Attachment: NSView {
        let state: InterfaceWindowContext
        var plan: InterfacePresentation
        init(state: InterfaceWindowContext, plan: InterfacePresentation) { self.state = state; self.plan = plan; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            state.attach(window)
            if let window { InterfaceWindowEffects.apply(plan, to: window) }
        }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); state.refresh() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

@MainActor final class InterfaceApplicationPolicy: NSObject {
    private var statusItem: NSStatusItem?
    private var originalIcon: NSImage?
    private var lastIcon: String?
    private var appearanceObserver: NSKeyValueObservation?
    private var latestPreferences: InterfacePreferences?
    private var latestWindowCount = 0
    var openWindow: () -> Void = {}
    var openSettings: () -> Void = {}
    func apply(_ preferences: InterfacePreferences, windowCount: Int, systemIsDark: Bool) {
        latestPreferences = preferences
        latestWindowCount = windowCount
        if appearanceObserver == nil {
            appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, let preferences = self.latestPreferences else { return }
                    self.apply(preferences, windowCount: self.latestWindowCount, systemIsDark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
                }
            }
        }
        var context = InterfaceContext()
        context.visibleWindowCount = max(0, windowCount)
        context.systemIsDark = systemIsDark
        let plan = preferences.resolve(context)
        if NSApp.activationPolicy() != (plan.showDockIcon ? .regular : .accessory) {
            NSApp.setActivationPolicy(plan.showDockIcon ? .regular : .accessory)
        }
        if plan.showMenuBarIcon && statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Trano")
            let menu = NSMenu()
            for (title, selector) in [("Open Trano", #selector(openTrano)), ("Settings…", #selector(settings)), ("Quit Trano", #selector(quit))] {
                let action = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                action.target = self
                menu.addItem(action)
            }
            item.menu = menu
            statusItem = item
        } else if !plan.showMenuBarIcon, let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        let key = preferences.appIcon.rawValue + (systemIsDark ? ":dark" : ":light")
        guard lastIcon != key else { return }
        lastIcon = key
        if originalIcon == nil { originalIcon = NSApp.applicationIconImage }
        if preferences.appIcon == .defaultDynamic && systemIsDark {
            NSApp.applicationIconImage = originalIcon
        } else {
            let bright = preferences.appIcon == .bright || (preferences.appIcon == .defaultDynamic && !systemIsDark)
            NSApp.applicationIconImage = Self.icon(bright: bright)
        }
    }
    static func icon(bright: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 256, height: 256))
        image.lockFocus()
        (bright ? NSColor(srgbRed: 0.89, green: 0.97, blue: 0.95, alpha: 1) : NSColor(srgbRed: 0.12, green: 0.13, blue: 0.22, alpha: 1)).setFill()
        NSBezierPath(roundedRect: NSRect(x: 15, y: 15, width: 226, height: 226), xRadius: 48, yRadius: 48).fill()
        (bright ? NSColor(srgbRed: 0.08, green: 0.22, blue: 0.22, alpha: 1) : NSColor(srgbRed: 0.57, green: 0.87, blue: 0.78, alpha: 1)).setStroke()
        let prompt = NSBezierPath()
        prompt.lineWidth = 15
        prompt.lineCapStyle = .round
        prompt.lineJoinStyle = .round
        prompt.move(to: NSPoint(x: 67, y: 165))
        prompt.line(to: NSPoint(x: 109, y: 128))
        prompt.line(to: NSPoint(x: 67, y: 91))
        prompt.move(to: NSPoint(x: 132, y: 91))
        prompt.line(to: NSPoint(x: 190, y: 91))
        prompt.stroke()
        image.unlockFocus()
        return image
    }
    @objc private func openTrano() { openWindow() }
    @objc private func settings() { openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}

struct InterfaceToolbarRevealRegion: NSViewRepresentable {
    let reveal: () -> Void
    func makeNSView(context: Context) -> RevealView { RevealView(reveal: reveal) }
    func updateNSView(_ view: RevealView, context: Context) { view.reveal = reveal }
    @MainActor final class RevealView: NSView {
        var reveal: () -> Void
        private var area: NSTrackingArea?
        init(reveal: @escaping () -> Void) { self.reveal = reveal; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func updateTrackingAreas() {
            if let area { removeTrackingArea(area) }
            let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(next)
            area = next
            super.updateTrackingAreas()
        }
        override func mouseEntered(with event: NSEvent) { reveal() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
