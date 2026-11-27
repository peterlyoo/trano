import AppKit
import OSLog
import SwiftUI
import TerminalCore

let hoverLog = Logger(subsystem: "trano.hover", category: "tab")

struct TabActivitySnapshot: Equatable {
    enum Availability: String { case live, closed, disconnected, unavailable }

    struct AgentRow: Identifiable, Equatable {
        let id: String
        let parentID: String?
        let name: String
        let agent: AgentKind?
        let state: ActivityState
        let reason: String
        let source: String
        let updatedAt: Date?
        let depth: Int
    }

    struct Pane: Identifiable, Equatable {
        let id: String
        let title: String
        let host: String
        let availability: Availability
        let root: AgentRow
        let children: [AgentRow]
        var childSummary: String { children.isEmpty ? "No subagents reported" : "\(children.count) reported subagent\(children.count == 1 ? "" : "s")" }
    }

    let id: String
    let title: String
    let panes: [Pane]

    init(tab: TerminalTab, sessions: [TerminalSession], focusedPaneID: String? = nil, preferGeneratedTitles: Bool = false) {
        id = tab.id
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        title = TabPresentation(tab: tab, sessions: sessions, focusedPaneID: focusedPaneID, preferGeneratedTitles: preferGeneratedTitles).title
        panes = tab.panes.map { paneID in
            guard let session = byID[paneID] else {
                return Pane(id: paneID, title: "Unavailable pane", host: "", availability: .unavailable,
                            root: AgentRow(id: paneID, parentID: nil, name: "Root", agent: nil, state: .unknown,
                                           reason: "", source: "unavailable", updatedAt: nil, depth: 0), children: [])
            }
            let activity = session.activity
            return Pane(id: paneID, title: session.displayTitle(preferGeneratedTitles: preferGeneratedTitles), host: session.host,
                        availability: session.alive ? .live : session.remote == nil ? .closed : .disconnected,
                        root: AgentRow(id: paneID, parentID: nil, name: "\(session.agent.rawValue.capitalized) · root", agent: session.agent,
                                       state: activity.state, reason: activity.reason, source: activity.source,
                                       updatedAt: activity.updatedAt, depth: 0),
                        children: Self.childRows(session.agentTasks ?? []))
        }
    }

    private static func childRows(_ tasks: [AgentTask]) -> [AgentRow] {
        var known = Set<String>()
        let tasks = tasks.prefix(64).filter { known.insert($0.id).inserted }
        let ids = Set(tasks.map(\.id))
        var visited = Set<String>()
        var rows: [AgentRow] = []
        func append(_ task: AgentTask, depth: Int) {
            guard visited.insert(task.id).inserted else { return }
            rows.append(AgentRow(id: task.id, parentID: task.parentID,
                                 name: task.name.isEmpty ? task.id : task.name, agent: task.agent,
                                 state: task.activity.state, reason: task.activity.reason, source: task.activity.source,
                                 updatedAt: task.activity.updatedAt, depth: depth))
            for child in tasks where child.parentID == task.id { append(child, depth: depth + 1) }
        }
        for task in tasks where task.parentID == nil || !ids.contains(task.parentID ?? "") { append(task, depth: 1) }
        for task in tasks where !visited.contains(task.id) { append(task, depth: 1) }
        return rows
    }

    /// Fits the longest row: icon, title and state label, plus insets; titles past the cap truncate in the middle.
    var preferredWidth: CGFloat {
        let title = NSFont.systemFont(ofSize: 12, weight: .semibold), row = NSFont.systemFont(ofSize: 11, weight: .medium), state = NSFont.systemFont(ofSize: 10)
        func width(_ text: String, _ font: NSFont) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        var widest = width(self.title, title) + 20
        for pane in panes {
            for entry in [pane.root] + pane.children {
                let label = pane.availability == .live ? entry.state.rawValue.capitalized : pane.availability.rawValue.capitalized
                let name = entry.depth == 0 ? pane.title : entry.name
                widest = max(widest, 20 + CGFloat(min(4, entry.depth)) * 14 + 18 + width(name, row) + 12 + width(label, state))
            }
        }
        return min(300, max(200, ceil(widest)))
    }

    static func showsReason(_ row: AgentRow) -> Bool { !row.reason.isEmpty && (row.state == .blocked || row.state == .error) }

    var preferredHeight: CGFloat {
        min(460, 42 + panes.reduce(0) { total, pane in
            total + ([pane.root] + pane.children).reduce(0) { $0 + (Self.showsReason($1) ? 37 : 22) }
        })
    }
}

enum TabActivityHoverPlacement { case below, trailing }

struct TabActivityHover: ViewModifier {
    let snapshot: TabActivitySnapshot
    let placement: TabActivityHoverPlacement

    func body(content: Content) -> some View {
        content.background { TabActivityHoverAnchor(snapshot: snapshot, placement: placement) }
    }
}

private struct TabActivityHoverAnchor: NSViewRepresentable {
    let snapshot: TabActivitySnapshot
    let placement: TabActivityHoverPlacement

    func makeNSView(context: Context) -> TabActivityHoverTrackingView {
        let view = TabActivityHoverTrackingView(frame: .zero)
        view.update(snapshot: snapshot, placement: placement)
        return view
    }

    func updateNSView(_ view: TabActivityHoverTrackingView, context: Context) {
        view.update(snapshot: snapshot, placement: placement)
    }

    static func dismantleNSView(_ view: TabActivityHoverTrackingView, coordinator: ()) { view.presenter.dismiss() }
}

@MainActor final class TabActivityHoverTrackingView: NSView {
    let presenter: TabActivityHoverPresenter
    private var hoverTrackingArea: NSTrackingArea?

    init(frame: NSRect, delay: TimeInterval = 0.25) {
        presenter = TabActivityHoverPresenter(delay: delay)
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(snapshot: TabActivitySnapshot?, placement: TabActivityHoverPlacement) {
        presenter.update(snapshot: snapshot, placement: placement)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        presenter.attach(to: self)
    }

    override func updateTrackingAreas() {
        hoverLog.debug("updateTrackingAreas window=\(self.window != nil) bounds=\(NSStringFromRect(self.bounds)) visible=\(NSStringFromRect(self.visibleRect))")
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        // SwiftUI scroll and tab insertion move this view without refreshing tracking rects, so the area spans the
        // visible strip and each event is hit-tested against the current bounds.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func layout() {
        super.layout()
        presenter.reposition()
    }

    private var pointerInside = false
    private func track(_ event: NSEvent, exited: Bool = false) {
        let inside = !exited && clippedVisibleBounds.contains(convert(event.locationInWindow, from: nil))
        hoverLog.debug("track type=\(event.type.rawValue) inside=\(inside) was=\(self.pointerInside) bounds=\(NSStringFromRect(self.clippedVisibleBounds)) point=\(NSStringFromPoint(self.convert(event.locationInWindow, from: nil)))")
        guard inside != pointerInside else { return }
        pointerInside = inside
        if inside { presenter.enterAnchor() } else { presenter.exitAnchor() }
    }

    override func mouseEntered(with event: NSEvent) { pointerInside = false; track(event) }
    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseExited(with event: NSEvent) { track(event, exited: true) }
}

@MainActor final class TabActivityHoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor private final class TabActivityHoverHostingView: NSHostingView<TabActivityHoverCard> {
    weak var presenter: TabActivityHoverPresenter?
    private var hoverTrackingArea: NSTrackingArea?
    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { presenter?.enterPanel() }
    override func mouseExited(with event: NSEvent) { presenter?.exitPanel() }
}

@MainActor final class TabActivityHoverPresenter {
    private(set) var panel: TabActivityHoverPanel?
    private(set) var snapshot: TabActivitySnapshot?
    private weak var anchor: NSView?
    private weak var owner: NSWindow?
    private let delay: TimeInterval
    private var placement = TabActivityHoverPlacement.below
    private var overAnchor = false
    private var overPanel = false
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    init(delay: TimeInterval) { self.delay = delay }

    deinit {
        openWork?.cancel()
        closeWork?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func attach(to view: NSView) {
        anchor = view
        guard owner !== view.window else { return }
        dismiss()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        owner = view.window
        guard let owner else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reposition() }
            })
        }
    }

    func update(snapshot: TabActivitySnapshot?, placement: TabActivityHoverPlacement) {
        self.snapshot = snapshot
        self.placement = placement
        guard let snapshot else { dismiss(); return }
        if let hosting = panel?.contentView as? TabActivityHoverHostingView {
            hosting.rootView = TabActivityHoverCard(snapshot: snapshot)
            reposition()
        }
    }

    func enterAnchor() {
        hoverLog.debug("enterAnchor panel=\(self.panel != nil) pendingOpen=\(self.openWork != nil)")
        overAnchor = true
        closeWork?.cancel()
        closeWork = nil
        guard panel == nil, openWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.openWork = nil
            guard self.overAnchor else { return }
            self.show()
        }
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func exitAnchor() {
        overAnchor = false
        openWork?.cancel()
        openWork = nil
        scheduleDismiss()
    }

    func enterPanel() {
        overPanel = true
        closeWork?.cancel()
        closeWork = nil
    }

    func exitPanel() { overPanel = false; scheduleDismiss() }

    private func scheduleDismiss() {
        closeWork?.cancel()
        guard panel != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.overAnchor, !self.overPanel else { return }
            self.dismiss()
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
    }

    private func show() {
        hoverLog.debug("show snapshot=\(self.snapshot != nil) anchor=\(self.anchor != nil) owner=\(self.owner != nil) sameWindow=\(self.anchor?.window === self.owner) key=\(self.owner?.isKeyWindow ?? false) visible=\(NSStringFromRect(self.anchor?.clippedVisibleBounds ?? .zero))")
        guard let snapshot, let anchor, let owner, anchor.window === owner, owner.isKeyWindow,
              !anchor.clippedVisibleBounds.isEmpty else { return }
        let panel = TabActivityHoverPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        let hosting = TabActivityHoverHostingView(rootView: TabActivityHoverCard(snapshot: snapshot))
        hosting.presenter = self
        panel.contentView = hosting
        self.panel = panel
        reposition()
        owner.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }

    func reposition() {
        guard let panel, let snapshot, let anchor, let owner else { return }
        let visibleBounds = anchor.clippedVisibleBounds
        guard anchor.window === owner, !visibleBounds.isEmpty else { dismiss(); return }
        let rect = owner.convertToScreen(anchor.convert(visibleBounds, to: nil))
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) } ?? owner.screen
        let visible = screen?.visibleFrame.insetBy(dx: 8, dy: 8) ?? owner.frame
        let size = NSSize(width: min(snapshot.preferredWidth, visible.width), height: min(snapshot.preferredHeight, visible.height))
        var origin = NSPoint(x: rect.minX, y: rect.minY - size.height - 4)
        if placement == .trailing {
            origin = NSPoint(x: rect.maxX + 4, y: rect.maxY - size.height)
            if origin.x + size.width > visible.maxX { origin.x = rect.minX - size.width - 4 }
        } else if origin.y < visible.minY, rect.maxY + size.height + 4 <= visible.maxY {
            origin.y = rect.maxY + 4
        }
        origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
        origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    func dismiss() {
        openWork?.cancel()
        closeWork?.cancel()
        openWork = nil
        closeWork = nil
        overAnchor = false
        overPanel = false
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.close()
        }
        panel = nil
    }
}

struct TabActivityHoverCard: View {
    let snapshot: TabActivitySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(snapshot.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                .padding(.horizontal, 10).padding(.top, 9).padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(snapshot.panes) { pane in
                        let historical = pane.availability == .live ? nil : pane.availability.rawValue.capitalized
                        row(pane.root, title: pane.title, historical: historical)
                        ForEach(pane.children) { child in row(child, title: child.name, historical: historical) }
                    }
                }.padding(.horizontal, 10).padding(.bottom, 9).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(Color(white: 0.92))
        .background(Color(red: 0.035, green: 0.035, blue: 0.04))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.14), lineWidth: 1) }
        .preferredColorScheme(.dark)
    }

    private func row(_ row: TabActivitySnapshot.AgentRow, title: String, historical: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Group {
                    if let agent = row.agent { AgentBadge(agent: agent) }
                    else { Image(systemName: "terminal").font(.system(size: 9)).foregroundStyle(.secondary) }
                }.frame(width: 12, height: 12)
                Text(title).font(.system(size: 11, weight: row.depth == 0 ? .medium : .regular)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text(historical ?? row.state.rawValue.capitalized)
                    .font(.system(size: 10)).foregroundStyle(historical == nil ? activityColor(row.state) : Color.secondary)
            }
            if TabActivitySnapshot.showsReason(row) {
                Text(row.reason).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 18)
            }
        }.frame(minHeight: 20).padding(.leading, CGFloat(min(4, row.depth)) * 14)
    }
}
