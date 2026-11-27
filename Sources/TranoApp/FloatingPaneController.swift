import AppKit
import Combine
import SwiftUI
import TerminalCore

@MainActor final class FloatingPaneController: NSObject, NSWindowDelegate {
    private weak var store: AppStore?
    private var entries: [String: Entry] = [:]
    private var presentationObserver: AnyCancellable?
    private var presentationQueued = false
    private var presentingOwner = false
    private var lastInteractionPaneID: String?
    private var returnFocusPaneID: String?
    var panelFactory: (NSRect) -> NSPanel = {
        NSPanel(contentRect: $0, styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView], backing: .buffered, defer: false)
    }

    private final class Entry {
        let paneID: String
        let terminal: TranoView
        let tabID: String
        let workspaceID: String
        weak var owner: NSWindow?
        var panel: NSPanel?
        var header: FloatingPaneHeader?
        var background: NSHostingView<TerminalBackgroundView>?
        var material: NSVisualEffectView?
        var backgroundSettings: TerminalSettings?
        var backgroundOpacity: Double?
        var originalLevel: NSWindow.Level?
        var restoreVisibility: Bool?
        var attaching = false

        init(paneID: String, terminal: TranoView, tabID: String, workspaceID: String) {
            self.paneID = paneID
            self.terminal = terminal
            self.tabID = tabID
            self.workspaceID = workspaceID
            owner = terminal.window
        }
    }

    init(store: AppStore) {
        self.store = store
        super.init()
        presentationObserver = store.objectWillChange.sink { [weak self] in self?.scheduleOwnerPresentation() }
    }

    func toggle(_ paneID: String) {
        if entries[paneID] != nil { returnPane(paneID); return }
        guard let store else { return }
        if let owner = WorkspaceOwners.floatingOwner(paneID: paneID, root: store.runtime.root), owner !== store {
            owner.floatingPanes.focus(paneID)
            return
        }
        guard let tab = store.selectedTab, let workspaceID = tab.workspaceID, tab.panes.contains(paneID),
              store.followUpPaneID == nil, store.decisionPaneID == nil,
              let terminal = store.terminalViews[paneID], !terminal.hasMarkedText() else { return }
        store.commandKeyHints.cancel()
        store.showActivity = false
        store.picker = nil
        store.zoomed = false
        entries[paneID] = Entry(paneID: paneID, terminal: terminal, tabID: tab.id, workspaceID: workspaceID)
        store.floatingPaneIDs.insert(paneID)
        if terminal.superview == nil { rendererDetached(terminal) }
    }

    func rendererDetached(_ terminal: TranoView) {
        guard let entry = entries[terminal.paneID], entry.terminal === terminal,
              entry.panel == nil, !entry.attaching else { return }
        entry.attaching = true
        DispatchQueue.main.async { [weak self, weak entry] in
            guard let self, let entry, self.entries[entry.paneID] === entry,
                  self.store?.floatingPaneIDs.contains(entry.paneID) == true else { return }
            self.present(entry)
        }
    }

    func returnPane(_ paneID: String) {
        guard let entry = entries[paneID] else { return }
        if let panel = entry.panel { panel.close() }
        else { finish(entry) }
    }

    func didCloseWindow(_ window: NSWindow) {
        guard let entry = entries.values.first(where: { $0.panel === window }) else { return }
        finish(entry)
    }

    func paneID(in window: NSWindow) -> String? {
        entries.values.first { $0.panel === window }?.paneID
    }

    func focus(_ paneID: String) {
        guard let entry = entries[paneID], let panel = entry.panel else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(entry.terminal)
    }

    func noteInteraction(in window: NSWindow?) {
        lastInteractionPaneID = window.flatMap { paneID(in: $0) }
    }

    func presentationOwner(for window: NSWindow) -> NSWindow? {
        guard let entry = entries.values.first(where: { $0.panel === window }) else { return window }
        return entry.owner
    }

    func suppressOwnerReturnFocus() { returnFocusPaneID = nil }

    func closeAll() {
        for paneID in Array(entries.keys) { returnPane(paneID) }
    }

    func synchronize() {
        guard let store else { return }
        for entry in Array(entries.values) {
            guard let tab = store.state.layout.tabs.first(where: { $0.panes.contains(entry.paneID) }),
                  tab.id == entry.tabID, tab.workspaceID == entry.workspaceID,
                  !store.state.layout.workspaces.contains(where: { $0.id == entry.workspaceID && $0.closed }) else { returnPane(entry.paneID); continue }
            entry.terminal.synchronize(store: store, id: entry.paneID)
            let plan = store.interfacePresentation(for: entry.paneID, in: entry.panel)
            entry.terminal.applyInterfacePresentation(plan)
            if let material = entry.material {
                InterfaceMaterialBackground(enabled: plan.glassChrome, dark: plan.isDark, opacity: store.effectiveWindowOpacity).apply(to: material)
            }
            let settings = store.state.settings.resolvedAppearance(for: entry.paneID)
            if let background = entry.background, (entry.backgroundSettings != settings || entry.backgroundOpacity != plan.paneOpacity) {
                entry.backgroundSettings = settings
                entry.backgroundOpacity = plan.paneOpacity
                background.rootView = TerminalBackgroundView(settings: settings, backgroundOpacity: plan.paneOpacity)
            }
            let title = store.sessions.first { $0.id == entry.paneID }?.displayTitle(preferGeneratedTitles: store.terminalPreferences.preferGeneratedTitles) ?? "Terminal"
            entry.panel?.title = title
            entry.header?.update(title: title, background: NSColor(hex: settings.background).withAlphaComponent(plan.paneOpacity))
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { didCloseWindow(window) }
    }

    private func scheduleOwnerPresentation() {
        guard !presentationQueued else { return }
        presentationQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.presentationQueued = false
            self.updateOwnerPresentation()
        }
    }

    private var needsOwnerPresentation: Bool {
        guard let store else { return false }
        return store.conversationResume != nil || store.picker != nil || store.followUpPaneID != nil || store.decisionPaneID != nil ||
            store.showActivity || store.showSettings || store.showVoice || store.showRemoteHosts ||
            store.showAccounts || store.showExtensions || store.remotePathRequest != nil || store.message != nil
    }

    private func updateOwnerPresentation(reconcile: Bool = false) {
        let active = needsOwnerPresentation
        let changed = active != presentingOwner
        guard changed || (active && reconcile) else { return }
        presentingOwner = active
        if active {
            if changed { returnFocusPaneID = lastInteractionPaneID }
            let owner = entries.values.first { $0.panel != nil }?.owner
            for entry in entries.values {
                guard let panel = entry.panel else { continue }
                if entry.originalLevel == nil { entry.originalLevel = panel.level }
                if entry.restoreVisibility == nil { entry.restoreVisibility = panel.isVisible }
                panel.orderOut(nil)
                panel.level = .normal
            }
            if let owner {
                if owner.isMiniaturized { owner.deminiaturize(nil) }
                if NSApp.isActive { owner.makeKeyAndOrderFront(nil) }
                else { owner.orderFrontRegardless() }
            }
        } else {
            for entry in entries.values {
                if let level = entry.originalLevel {
                    entry.panel?.level = level
                    entry.originalLevel = nil
                }
                if entry.restoreVisibility == true { entry.panel?.orderFrontRegardless() }
                entry.restoreVisibility = nil
            }
            let paneID = returnFocusPaneID
            returnFocusPaneID = nil
            if NSApp.isActive, let paneID { focus(paneID) }
        }
    }

    private func present(_ entry: Entry) {
        guard let store else { finish(entry); return }
        let terminal = entry.terminal
        let width = max(480, min(1100, terminal.bounds.width))
        let height = max(300, min(800, terminal.bounds.height + 28))
        let ownerFrame = entry.owner?.frame ?? NSRect(x: 160, y: 160, width: width, height: height)
        let rect = NSRect(x: ownerFrame.midX - width / 2, y: ownerFrame.midY - height / 2, width: width, height: height)
        let panel = panelFactory(rect)
        panel.identifier = NSUserInterfaceItemIdentifier("floating-pane-" + entry.paneID)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.minSize = NSSize(width: 360, height: 220)
        panel.delegate = self

        let container = NSView(frame: NSRect(origin: .zero, size: rect.size))
        let material = NSVisualEffectView()
        material.material = .underWindowBackground
        material.blendingMode = .behindWindow
        material.state = .active
        InterfaceMaterialBackground(enabled: store.interfacePreferences.style == .glass, dark: store.interfaceThemeMode == .dark, opacity: store.effectiveWindowOpacity).apply(to: material)
        material.translatesAutoresizingMaskIntoConstraints = false
        entry.material = material
        container.addSubview(material)
        NSLayoutConstraint.activate([
            material.leadingAnchor.constraint(equalTo: container.leadingAnchor), material.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            material.topAnchor.constraint(equalTo: container.topAnchor), material.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        let settings = store.state.settings.resolvedAppearance(for: entry.paneID)
        let plan = store.interfacePresentation(for: entry.paneID, in: panel)
        let background = NSHostingView(rootView: TerminalBackgroundView(settings: settings, backgroundOpacity: plan.paneOpacity))
        background.identifier = NSUserInterfaceItemIdentifier("floating-pane-background")
        background.translatesAutoresizingMaskIntoConstraints = false
        let header = FloatingPaneHeader()
        let paneID = entry.paneID
        header.returnButton.onAction = { [weak self] in self?.returnPane(paneID) }
        header.translatesAutoresizingMaskIntoConstraints = false
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(background)
        container.addSubview(header)
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 28),
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: header.bottomAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            background.leadingAnchor.constraint(equalTo: terminal.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: terminal.trailingAnchor),
            background.topAnchor.constraint(equalTo: terminal.topAnchor),
            background.bottomAnchor.constraint(equalTo: terminal.bottomAnchor)
        ])
        panel.contentView = container
        entry.panel = panel
        entry.header = header
        entry.background = background
        entry.backgroundSettings = settings
        entry.backgroundOpacity = plan.paneOpacity
        let title = store.sessions.first { $0.id == entry.paneID }?.displayTitle(preferGeneratedTitles: store.terminalPreferences.preferGeneratedTitles) ?? "Terminal"
        panel.title = title
        terminal.applyInterfacePresentation(plan)
        header.update(title: title, background: NSColor(hex: settings.background).withAlphaComponent(plan.paneOpacity))
        store.onFloatingWindowChange?(panel, true)
        if needsOwnerPresentation {
            entry.restoreVisibility = true
            updateOwnerPresentation(reconcile: true)
        }
        else {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(terminal)
        }
        terminal.viewDidUnhide()
    }

    private func finish(_ entry: Entry) {
        guard entries[entry.paneID] === entry else { return }
        if let panel = entry.panel {
            entry.terminal.removeFromSuperview()
            entry.terminal.translatesAutoresizingMaskIntoConstraints = true
            panel.contentView = nil
            store?.onFloatingWindowChange?(panel, false)
        }
        entry.panel = nil
        entry.header = nil
        entry.background = nil
        entry.backgroundSettings = nil
        entries.removeValue(forKey: entry.paneID)
        store?.floatingPaneIDs.remove(entry.paneID)
        if lastInteractionPaneID == entry.paneID { lastInteractionPaneID = nil }
        if returnFocusPaneID == entry.paneID { returnFocusPaneID = nil }
        let paneID = entry.paneID
        DispatchQueue.main.async { [weak store = store, weak owner = entry.owner, weak terminal = entry.terminal] in
            guard let store, let owner, owner.isVisible, let terminal,
                  store.focusedID == paneID, terminal.window === owner else { return }
            owner.makeFirstResponder(terminal)
        }
    }
}

@MainActor private final class FloatingPaneHeader: NSView {
    private let label = NSTextField(labelWithString: "")
    let returnButton = FloatingPaneReturnButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        returnButton.title = "Return to Pane"
        returnButton.identifier = NSUserInterfaceItemIdentifier("floating-pane-return")
        returnButton.setAccessibilityLabel("Return to Pane")
        returnButton.target = returnButton
        returnButton.action = #selector(FloatingPaneReturnButton.invoke(_:))
        returnButton.isBordered = false
        returnButton.font = .systemFont(ofSize: 11)
        returnButton.contentTintColor = .secondaryLabelColor
        returnButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(returnButton)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 72),
            label.trailingAnchor.constraint(lessThanOrEqualTo: returnButton.leadingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            returnButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            returnButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) }
        else { window?.performDrag(with: event) }
    }
    func update(title: String, background: NSColor) {
        label.stringValue = title
        layer?.backgroundColor = background.cgColor
    }
}

@MainActor private final class FloatingPaneReturnButton: NSButton {
    var onAction: (() -> Void)?
    @objc func invoke(_ sender: Any?) { onAction?() }
}
