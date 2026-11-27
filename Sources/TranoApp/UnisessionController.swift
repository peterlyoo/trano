import AppKit
import Combine
import SwiftUI
import TerminalCore

private struct UnisessionContent: View {
    @ObservedObject var store: AppStore
    let paneID: String
    var body: some View {
        let plan = store.interfacePresentation(for: paneID, in: store.terminalViews[paneID]?.window)
        ZStack {
            TerminalBackgroundView(settings: store.interfaceResolvedSettings(for: paneID), backgroundOpacity: plan.paneOpacity)
            TerminalPane(store: store, id: paneID, interfacePresentation: plan).id(paneID)
        }
    }
}

@MainActor final class UnisessionController: NSObject {
    private let runtime: TerminalRuntime
    private let worker = DispatchQueue(label: "trano.unisession", qos: .userInitiated)
    private var binding: UnisessionBinding?
    private var rendererStore: AppStore?
    private var rendererHost: NSHostingView<UnisessionContent>?
    private weak var sourceStore: AppStore?
    private weak var pendingOwner: NSWindow?
    private weak var pendingStore: AppStore?
    private var subscription: AnyCancellable?
    private var loading = false
    private var generation: UInt64 = 0
    private var fontSize: Double?
    private var focusGeneration: UInt64 = 0
    private(set) var isVisible = false
    var onVisibilityChange: (Bool) -> Void = { _ in }
    var onHideFocus: (NSWindow) -> Void = { _ in }
    private(set) lazy var presentation = UnisessionPresentation(renderer: makeProgress(), canMove: { [weak self] in self?.inputIsSafe == true })
    var renderer: TranoView? { binding.flatMap { rendererStore?.terminalViews[$0.paneID] } }
    private var inputIsSafe: Bool {
        renderer?.hasMarkedText() != true && (presentation.owner?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true
            && renderer?.window?.attachedSheet == nil && NSApp.modalWindow == nil
    }
    init(runtime: TerminalRuntime) { self.runtime = runtime; super.init() }

    func toggle(in owner: NSWindow, store: AppStore) {
        if isVisible && presentation.owner === owner { hide() }
        else { show(in: owner, store: store, focus: true, ensure: true) }
    }
    func reveal(in owner: NSWindow, store: AppStore) { show(in: owner, store: store, focus: true, ensure: true) }
    func follow(in owner: NSWindow, store: AppStore) {
        guard isVisible else { return }
        if presentation.owner === owner, sourceStore === store {
            pendingOwner = nil; pendingStore = nil
            return
        }
        show(in: owner, store: store, focus: false, ensure: false)
    }
    func anchorChanged(_ anchor: NSView, store: AppStore) {
        guard let owner = anchor.window, isVisible, presentation.owner === owner else { return }
        position(in: owner, store: store)
        applyOwner(store)
    }
    private func show(in owner: NSWindow, store: AppStore, focus: Bool, ensure: Bool) {
        guard owner.attachedSheet == nil, NSApp.modalWindow == nil, !store.showSettings else { return }
        focusGeneration &+= 1
        if (owner.firstResponder as? NSTextInputClient)?.hasMarkedText() == true && !ownsFocus(in: owner) {
            pendingOwner = owner; pendingStore = store; return
        }
        if presentation.owner != nil && presentation.owner !== owner && !inputIsSafe {
            pendingOwner = owner; pendingStore = store; return
        }
        pendingOwner = nil; pendingStore = nil
        renderer?.invalidateTerminalInteractions()
        sourceStore = store
        presentation.surface.apply(theme: store.toolPanelTheme)
        subscription = store.objectWillChange.sink { [weak self, weak store] in
            DispatchQueue.main.async { if let store, self?.sourceStore === store { self?.applyOwner(store) } }
        }
        isVisible = true
        presentation.onHide = { [weak self] released in self?.didHide(releasedFocus: released) }
        presentation.onLayout = { [weak self] in self?.configureContextActions() }
        position(in: owner, store: store)
        onVisibilityChange(true)
        if ensure || binding == nil { ensureTerminal(cwd: launchDirectory(store), focus: focus) }
        else { applyOwner(store); if focus { focusTerminal() } }
    }
    private func position(in owner: NSWindow, store: AppStore) {
        let frame = store.unisessionAnchor.flatMap { anchor -> NSRect? in
            guard anchor.window === owner, let content = owner.contentView else { return nil }
            return content.convert(anchor.bounds, from: anchor)
        }
        _ = presentation.show(in: owner, topInset: frame == nil ? 40 : 0, anchorFrame: frame)
    }
    private func ensureTerminal(cwd: String, focus: Bool) {
        guard !loading else { return }
        loading = true; generation &+= 1
        let token = generation, runtime = runtime
        let intent = focus ? presentation.owner.map { UnisessionFocusIntent(owner: $0, generation: focusGeneration) } : nil
        worker.async { [weak self] in
            let result = Result { () -> (UnisessionBinding, RuntimeState, [TerminalSession]) in
                let binding = try runtime.ensureUnisession(cwd: cwd)
                try runtime.validateUnisession(binding)
                return (binding, try runtime.state(), try runtime.list())
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.loading = false
                switch result {
                case .success(let snapshot):
                    self.install(snapshot.0, state: snapshot.1, sessions: snapshot.2)
                    if let owner = self.sourceStore { self.applyOwner(owner) }
                    if self.isVisible, let owner = self.presentation.owner, owner.isKeyWindow,
                       intent?.permitsFocus(in: owner, generation: self.focusGeneration) == true { self.focusTerminal() }
                case .failure(let error): self.showError(error.localizedDescription)
                }
            }
        }
    }
    private func install(_ binding: UnisessionBinding, state: RuntimeState, sessions: [TerminalSession]) {
        if self.binding != binding || rendererHost == nil {
            discardRenderer()
            self.binding = binding
            let store = AppStore(runtime: runtime, bootstrapIfEmpty: false, recoverOnStartup: false, unisessionBinding: binding)
            store.isActiveWindow = { [weak self] in self?.presentation.owner?.isKeyWindow == true }
            store.applyExternalSnapshot(state, sessions: sessions)
            rendererStore = store
            let host = NSHostingView(rootView: UnisessionContent(store: store, paneID: binding.paneID))
            rendererHost = host; presentation.surface.setRenderer(host)
        } else {
            rendererStore?.applyExternalSnapshot(state, sessions: sessions)
            if let rendererHost { presentation.surface.setRenderer(rendererHost) }
        }
        presentation.surface.needsLayout = true; presentation.surface.layoutSubtreeIfNeeded()
        configureContextActions()
    }
    private func applyOwner(_ owner: AppStore) {
        presentation.surface.apply(theme: owner.toolPanelTheme)
        guard let store = rendererStore, let binding else { return }
        var snapshot = owner.state
        if let current = store.sessions.first(where: { $0.id == binding.paneID }), !snapshot.sessions.contains(where: { $0.id == binding.paneID }) { snapshot.sessions.append(current) }
        let sessions = owner.sessions.contains(where: { $0.id == binding.paneID }) ? owner.sessions : store.sessions
        store.applyExternalSnapshot(snapshot, sessions: sessions)
        store.themePreferences = owner.themePreferences; store.interfacePreferences = owner.interfacePreferences
        store.terminalPreferences = owner.terminalPreferences; store.developerPreferences = owner.developerPreferences
        store.windowOpacityPreview = owner.windowOpacityPreview
        if let fontSize {
            store.externalPanePolicy?.applyLocalFontSize(fontSize, settings: &store.state.settings, preferences: &store.terminalPreferences)
        }
        let obstructed = owner.picker != nil || owner.showSettings || owner.showAccounts || owner.showRemoteHosts || owner.showExtensions || owner.showVoice || owner.decisionPaneID != nil || owner.conversationResume != nil || presentation.owner?.attachedSheet != nil
        if obstructed && !presentation.host.isHidden { presentation.releaseInputFocus(); renderer?.invalidateTerminalInteractions() }
        presentation.host.isHidden = !isVisible || obstructed
        configureContextActions()
    }
    private func configureContextActions() {
        guard let renderer else { return }
        renderer.terminalContextSupports = { [weak self] in self?.supports($0) == true }
        renderer.terminalContextAction = { [weak self] in self?.perform($0) == true }
    }
    func ownsFocus(in window: NSWindow?) -> Bool {
        guard isVisible, !presentation.host.isHidden, let window, window === presentation.owner, let renderer else { return false }
        return presentation.ownsInputFocus
    }
    func noteInput(_ event: NSEvent) {
        guard loading else { return }
        let key = event.type == .keyDown && !ownsFocus(in: event.window)
        let pointer = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) && !containsPointer(event)
        if key || pointer { focusGeneration &+= 1 }
    }
    func route(_ event: NSEvent, action: ActionID?) -> Bool? {
        let pointer = [.scrollWheel, .magnify, .rightMouseDown, .otherMouseDown].contains(event.type) && containsPointer(event)
        guard pointer || ownsFocus(in: event.window) else { return nil }
        guard let renderer else { return nil }
        if event.type == .scrollWheel { return renderer.handleHistoryScrollWheel(event) }
        if event.type == .magnify {
            var context = InterfaceContext(); context.isActiveWindow = presentation.owner?.isKeyWindow == true; context.inputIsProtected = !inputIsSafe
            if let action = sourceStore?.interfacePreferences.gesture(.magnify(Double(event.magnification)), context: context) {
                if action == .zoomPane && !presentation.expanded || action == .restorePane && presentation.expanded { presentation.toggleExpanded() }
            }
            return true
        }
        if event.type == .keyDown {
            if (presentation.owner?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true { return false }
            if presentation.owner?.firstResponder !== renderer {
                if let action, [.closePane, .closeTab, .zoom, .increaseFont, .decreaseFont, .resetFont, .findNext, .findPrevious].contains(action) { return perform(action) }
                return false
            }
            if renderer.urlHints.isActive && renderer.urlHints.handle(event) { return true }
            if renderer.handleHistoryKeyDown(event) { return true }
            if let action, supports(action) { return perform(action) }
            if action == nil, renderer.handleInterruptHandoff(event) { return true }
        }
        return event.type == .keyDown && action != nil ? nil : false
    }
    func containsPointer(_ event: NSEvent) -> Bool {
        guard isVisible, !presentation.host.isHidden, event.window === presentation.owner else { return false }
        let point = presentation.surface.convert(event.locationInWindow, from: nil)
        return presentation.surface.bounds.contains(point)
    }
    func supports(_ action: ActionID) -> Bool {
        [.copy, .paste, .selectAll, .clear, .find, .findNext, .findPrevious, .increaseFont, .decreaseFont, .resetFont, .closePane, .closeTab, .zoom, .urlHints].contains(action)
    }
    @discardableResult func perform(_ action: ActionID) -> Bool {
        guard supports(action), inputIsSafe, let renderer, renderer.window === presentation.owner, let store = rendererStore else { return false }
        if let editor = presentation.owner?.firstResponder as? NSText, editor !== renderer {
            let selector: Selector?
            switch action {
            case .copy: selector = #selector(NSText.copy(_:))
            case .paste: selector = #selector(NSText.paste(_:))
            case .selectAll: selector = #selector(NSText.selectAll(_:))
            default: selector = nil
            }
            if let selector { return NSApp.sendAction(selector, to: editor, from: self) }
        }
        switch action {
        case .closePane, .closeTab: hide()
        case .zoom: presentation.toggleExpanded()
        case .copy: renderer.copy(self)
        case .paste: renderer.paste(self)
        case .selectAll: renderer.selectAllWithTerminalPreferences(self)
        case .clear: renderer.clearScrollback()
        case .urlHints: if renderer.urlHints.isActive { renderer.urlHints.dismiss() } else { renderer.urlHints.start() }
        case .find, .findNext, .findPrevious:
            let item = NSMenuItem(); item.tag = Int((action == .find ? NSFindPanelAction.showFindPanel : action == .findNext ? .next : .previous).rawValue)
            renderer.performFindPanelAction(item)
        case .increaseFont, .decreaseFont, .resetFont:
            fontSize = action == .resetFont ? nil : min(40, max(9, Double(renderer.font.pointSize) + (action == .increaseFont ? 1 : -1)))
            if let sourceStore { applyOwner(sourceStore) }
            if let binding { renderer.synchronize(store: store, id: binding.paneID) }
        default: return false
        }
        return true
    }
    func hide() {
        let owned = presentation.ownsInputFocus
        guard presentation.hide() else { return }
        renderer?.invalidateTerminalInteractions(); didHide(releasedFocus: owned)
    }
    private func didHide(releasedFocus: Bool) {
        renderer?.invalidateTerminalInteractions()
        focusGeneration &+= 1
        pendingOwner = nil; pendingStore = nil
        isVisible = false; onVisibilityChange(false)
        if releasedFocus, let owner = presentation.owner { onHideFocus(owner) }
    }
    func ownerWillClose(_ owner: NSWindow) {
        if pendingOwner === owner { pendingOwner = nil; pendingStore = nil }
        guard presentation.owner === owner else { return }
        focusGeneration &+= 1
        renderer?.invalidateTerminalInteractions(); presentation.detach(); subscription = nil; sourceStore = nil
    }
    func reconcilePendingOwner() {
        guard let owner = pendingOwner, let store = pendingStore, inputIsSafe, owner.isVisible, owner.isKeyWindow else { return }
        show(in: owner, store: store, focus: false, ensure: binding == nil)
    }
    private func focusTerminal() {
        guard inputIsSafe, let owner = presentation.owner, owner.attachedSheet == nil,
              (owner.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return }
        rendererHost?.layoutSubtreeIfNeeded()
        configureContextActions()
        if let renderer { owner.makeFirstResponder(renderer) }
    }
    private func makeProgress() -> NSView {
        let view = NSProgressIndicator(); view.style = .spinning; view.controlSize = .small; view.startAnimation(nil); return view
    }
    private func showError(_ message: String) {
        let label = NSTextField(wrappingLabelWithString: message)
        let retry = NSButton(title: "Retry", target: self, action: #selector(UnisessionController.retry))
        let stack = NSStackView(views: [label, retry]); stack.orientation = .vertical; stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        presentation.surface.setRenderer(stack)
    }
    private func launchDirectory(_ store: AppStore?) -> String {
        let pane = store?.sessions.first { $0.id == store?.focusedID }
        return UnisessionLaunchDirectory.resolve(pane, home: FileManager.default.homeDirectoryForCurrentUser.path)
    }
    @objc private func retry() { ensureTerminal(cwd: launchDirectory(sourceStore), focus: true) }
    private func discardRenderer() {
        if let store = rendererStore { for view in store.terminalViews.values { view.terminate() } }
        rendererStore = nil; rendererHost = nil; binding = nil
    }
    func shutdownFrontend() { generation &+= 1; subscription = nil; presentation.detach(); discardRenderer() }
}
