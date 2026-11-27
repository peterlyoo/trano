import AppKit
import SwiftUI

@MainActor final class OutsideClickDismissalRegistry {
    static let shared = OutsideClickDismissalRegistry()
    private final class Entry {
        weak var surface: NSView?
        let order: UInt64
        var canDismiss: () -> Bool
        var perform: () -> Void
        init(surface: NSView, order: UInt64, canDismiss: @escaping () -> Bool, perform: @escaping () -> Void) {
            self.surface = surface; self.order = order; self.canDismiss = canDismiss; self.perform = perform
        }
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var order: UInt64 = 0
    private var dispatching = false

    func register(surface: NSView, id: String, canDismiss: @escaping () -> Bool = { true }, perform: @escaping () -> Void) {
        let key = ObjectIdentifier(surface)
        if let entry = entries[key], entry.surface === surface {
            entry.canDismiss = canDismiss; entry.perform = perform
        } else {
            order &+= 1
            entries[key] = Entry(surface: surface, order: order, canDismiss: canDismiss, perform: perform)
        }
    }
    func remove(surface: NSView) { entries.removeValue(forKey: ObjectIdentifier(surface)) }

    @discardableResult func handle(_ event: NSEvent, modalWindow: NSWindow? = nil) -> Bool {
        let cancelling = event.type == .keyDown && event.keyCode == 53 && event.window is WorkspaceToolPanelWindow &&
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        guard event.type == .leftMouseDown || cancelling, let eventWindow = event.window, !dispatching else { return false }
        if cancelling, (eventWindow.firstResponder as? NSTextInputClient)?.hasMarkedText() == true { return false }
        if cancelling, let recorder = eventWindow.firstResponder as? ShortcutButton, recorder.recording {
            recorder.capture(event); return true
        }
        entries = entries.filter { $0.value.surface != nil }
        let eligible = entries.values.filter { entry in
            guard let view = entry.surface, let window = view.window,
                  !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.intersection(view.bounds).isEmpty,
                  !window.isMiniaturized, window.attachedSheet == nil,
                  let owners = Self.owners(window), owners.contains(where: { $0 === eventWindow }),
                  modalWindow == nil || owners.contains(where: { $0 === modalWindow }) else { return false }
            return true
        }
        guard let entry = eligible.max(by: { Self.isAbove($1, $0) }), let surface = entry.surface else { return false }
        if !cancelling, surface.window === eventWindow, surface.visibleRect.intersection(surface.bounds).contains(surface.convert(event.locationInWindow, from: nil)) { return false }
        guard entry.canDismiss() else { return true }
        dispatching = true
        defer { dispatching = false }
        entry.perform()
        return true
    }
    private static func owners(_ window: NSWindow) -> [NSWindow]? {
        var result: [NSWindow] = [], seen = Set<ObjectIdentifier>(), current: NSWindow? = window
        while let window = current {
            guard result.count < 32, seen.insert(ObjectIdentifier(window)).inserted else { return nil }
            result.append(window); current = window.sheetParent ?? window.parent
        }
        return result
    }
    private static func isAbove(_ lhs: Entry, _ rhs: Entry) -> Bool {
        guard let first = lhs.surface, let second = rhs.surface else { return lhs.order > rhs.order }
        let firstDepth = first.window.flatMap(owners)?.count ?? 0
        let secondDepth = second.window.flatMap(owners)?.count ?? 0
        if firstDepth != secondDepth { return firstDepth > secondDepth }
        func ancestry(_ view: NSView) -> [NSView] {
            var views = [view], current = view.superview
            while let parent = current { views.append(parent); current = parent.superview }
            return views.reversed()
        }
        let a = ancestry(first), b = ancestry(second)
        for index in 0..<min(a.count, b.count) where a[index] !== b[index] {
            guard index > 0, a[index - 1] === b[index - 1],
                  let ai = a[index - 1].subviews.firstIndex(where: { $0 === a[index] }),
                  let bi = a[index - 1].subviews.firstIndex(where: { $0 === b[index] }) else { return lhs.order > rhs.order }
            return ai > bi
        }
        return a.count != b.count ? a.count > b.count : lhs.order > rhs.order
    }
}

@MainActor private struct OutsideClickDismissalRegion: NSViewRepresentable {
    let id: String
    let canDismiss: () -> Bool
    let perform: () -> Void
    func makeNSView(context: Context) -> OutsideClickDismissalView { OutsideClickDismissalView() }
    func updateNSView(_ view: OutsideClickDismissalView, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier("outside-dismissal-" + id)
        view.canDismiss = canDismiss; view.perform = perform; view.updateRegistration()
    }
    static func dismantleNSView(_ view: OutsideClickDismissalView, coordinator: ()) {
        OutsideClickDismissalRegistry.shared.remove(surface: view)
    }
}

@MainActor private final class OutsideClickDismissalView: NSView {
    var canDismiss: () -> Bool = { false }
    var perform: () -> Void = {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateRegistration() }
    func updateRegistration() {
        guard window != nil else { OutsideClickDismissalRegistry.shared.remove(surface: self); return }
        OutsideClickDismissalRegistry.shared.register(surface: self, id: identifier?.rawValue ?? "", canDismiss: canDismiss, perform: perform)
    }
}

extension View {
    @MainActor func dismissOnOutsideClick(_ id: String, canDismiss: @escaping () -> Bool = { true }, perform: @escaping () -> Void) -> some View {
        background(OutsideClickDismissalRegion(id: id, canDismiss: canDismiss, perform: perform))
    }
}

@MainActor final class WorkspaceToolPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor private final class WorkspaceToolPanelAnchor: NSView {
    var onWindowChange: (NSWindow?) -> Void = { _ in }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindowChange(window) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor private final class WorkspaceToolPanelHostingView<Panel: View>: NSHostingView<Panel> {
    var onSizeChange: () -> Void = {}
    override func invalidateIntrinsicContentSize() { super.invalidateIntrinsicContentSize(); onSizeChange() }
}

@MainActor private struct WorkspaceToolPanelPresenter<Panel: View>: NSViewRepresentable {
    let isPresented: Bool
    let panel: Panel
    @Environment(\.toolPanelTheme) private var theme
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WorkspaceToolPanelAnchor {
        let anchor = WorkspaceToolPanelAnchor()
        anchor.onWindowChange = { [weak coordinator = context.coordinator] in coordinator?.attach(to: $0) }
        return anchor
    }
    func updateNSView(_ anchor: WorkspaceToolPanelAnchor, context: Context) {
        context.coordinator.update(isPresented: isPresented, content: panel, owner: anchor.window, theme: theme)
    }
    static func dismantleNSView(_ anchor: WorkspaceToolPanelAnchor, coordinator: Coordinator) { coordinator.close() }

    @MainActor final class Coordinator {
        private weak var owner: NSWindow?
        private var window: WorkspaceToolPanelWindow?
        private var hosting: WorkspaceToolPanelHostingView<AnyView>?
        private var content: Panel?
        private var theme = ToolPanelTheme.defaultDark
        private var isPresented = false
        private var observers: [NSObjectProtocol] = []
        private var layoutPending = false
        private var layingOut = false

        func update(isPresented: Bool, content: Panel, owner: NSWindow?, theme: ToolPanelTheme) {
            self.isPresented = isPresented; self.content = content; self.theme = theme
            if !isPresented { close(); return }
            window?.appearance = theme.appearance
            if let hosting { hosting.rootView = AnyView(content.environment(\.toolPanelTheme, theme)) }
            attach(to: owner)
        }
        func attach(to owner: NSWindow?) {
            guard isPresented, let content, let owner else { close(); return }
            if self.owner === owner, window != nil { layout(); return }
            close()
            self.owner = owner
            let window = WorkspaceToolPanelWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.animationBehavior = .none
            window.hidesOnDeactivate = false; window.isFloatingPanel = false
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
            window.appearance = theme.appearance
            window.level = owner.level; window.collectionBehavior = [.fullScreenAuxiliary]
            let hosting = WorkspaceToolPanelHostingView(rootView: AnyView(content.environment(\.toolPanelTheme, theme)))
            hosting.onSizeChange = { [weak self] in self?.scheduleLayout() }
            let scroll = NSScrollView()
            scroll.scrollerStyle = .overlay
            scroll.drawsBackground = false; scroll.contentView.drawsBackground = false; scroll.backgroundColor = theme.backgroundNS
            scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
            scroll.documentView = hosting
            scroll.wantsLayer = true; scroll.layer?.cornerRadius = ToolPanelMetrics.cornerRadius; scroll.layer?.masksToBounds = true
            window.contentView = scroll
            self.window = window; self.hosting = hosting
            let shouldTakeKey = owner.isKeyWindow || owner.childWindows?.contains(where: { $0.isKeyWindow }) == true
            owner.addChildWindow(window, ordered: .above)
            layout()
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.layout() }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
            if shouldTakeKey { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
        }
        private func scheduleLayout() {
            guard !layoutPending, !layingOut, window != nil else { return }
            layoutPending = true
            DispatchQueue.main.async { [weak self] in self?.layoutPending = false; self?.layout() }
        }
        private func layout() {
            guard !layingOut, let owner, let content = owner.contentView, let window, let hosting else { return }
            layingOut = true
            defer { layingOut = false }
            let ideal = hosting.fittingSize
            guard ideal.width.isFinite, ideal.height.isFinite, ideal.width > 0, ideal.height > 0 else { return }
            if hosting.frame.size != ideal { hosting.setFrameSize(ideal) }
            let bounds = owner.convertToScreen(content.convert(content.bounds, to: nil)).insetBy(dx: 16, dy: 16)
            let size = NSSize(width: min(ideal.width, max(1, bounds.width)), height: min(ideal.height, max(1, bounds.height)))
            let frame = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            if window.frame != frame { window.setFrame(frame, display: true) }
        }
        func close() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            guard let window else { owner = nil; return }
            let parent = owner
            let wasKey = window.isKeyWindow
            hosting?.onSizeChange = {}
            self.window = nil; hosting = nil; owner = nil
            parent?.removeChildWindow(window)
            window.orderOut(nil); window.close()
            if wasKey, NSApp.isActive, NSApp.keyWindow == nil, let parent, parent.isVisible, !parent.isMiniaturized {
                parent.makeKey()
            }
        }
    }
}

extension View {
    @MainActor func workspacePanel<Panel: View>(isPresented: Bool, @ViewBuilder content: () -> Panel) -> some View {
        background(WorkspaceToolPanelPresenter(isPresented: isPresented, panel: content()))
    }
}
