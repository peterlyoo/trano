import AppKit
import SwiftTerm
import TerminalCore

private struct SupervisorNativeSnapshot {
    let supervisor: SupervisorState
    let state: RuntimeState
    let sessions: [TerminalSession]
    let themes: ThemePreferences
    let interface: InterfacePreferences
    let terminal: TerminalPreferences
    let developer: DeveloperPreferences

    func validate(_ binding: SupervisorBinding) throws {
        try SupervisorRendererIdentity.validate(binding: binding, currentBinding: supervisor.binding,
            sessions: sessions, readBackendIdentity: SupervisorProcessIdentity.read)
    }
}

private final class SupervisorNativeSessionSource: @unchecked Sendable {
    private let runtime: TerminalRuntime
    private let operations: SupervisorCommandOperations
    private let lock = NSLock()
    private var snapshot: SupervisorNativeSnapshot?

    init(runtime: TerminalRuntime) {
        self.runtime = runtime
        operations = runtime.supervisorOperations()
    }

    func read() throws -> SupervisorState {
        try runtime.transaction {
            let next = SupervisorNativeSnapshot(supervisor: try operations.state(), state: try runtime.state(), sessions: try runtime.list(),
                                                themes: try runtime.themePreferences(), interface: try runtime.interfacePreferences(),
                                                terminal: try runtime.terminalPreferences(), developer: try DeveloperSettingsStore(root: runtime.root).load())
            lock.lock()
            snapshot = next
            lock.unlock()
            return next.supervisor
        }
    }

    func start(_ configuration: SupervisorConfiguration) throws -> SupervisorState {
        _ = try operations.start(configuration)
        return try read()
    }

    func stop(_ paneID: String, _ pid: Int32) throws -> SupervisorState {
        _ = try operations.stop(paneID, pid)
        return try read()
    }

    func validateTarget(_ authority: SupervisorContinuationAuthority, _ target: SupervisorContinuationIdentity) throws {
        try runtime.supervisorContinuationCoordinator().validateTarget(authority: authority, target: target)
    }

    func reviewInput(_ authority: SupervisorContinuationAuthority, _ target: SupervisorContinuationIdentity) throws {
        try runtime.supervisorContinuationCoordinator().review(authority: authority, target: target)
    }

    func readReadiness(_ previous: SupervisorState) throws -> SupervisorState {
        let updated = try runtime.refreshSupervisorInputReadiness(state: previous)
        lock.lock(); defer { lock.unlock() }
        guard let current = snapshot, current.supervisor == previous else { throw TerminalError.invalid("Supervisor snapshot changed") }
        snapshot = SupervisorNativeSnapshot(supervisor: updated, state: current.state, sessions: current.sessions,
            themes: current.themes, interface: current.interface, terminal: current.terminal, developer: current.developer)
        return updated
    }

    func cached() -> SupervisorNativeSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }
}

@MainActor final class SupervisorNativeRuntimeAdapter {
    private let runtime: TerminalRuntime
    private let source: SupervisorNativeSessionSource
    private var rendererStore: AppStore?
    private var rendererBinding: SupervisorBinding?
    private var fontSizeOverride: Double?
    private var watcher: DispatchSourceFileSystemObject?
    private var refreshWork: DispatchWorkItem?
    private var pendingFullRefresh = false
    private var readinessWatch: SupervisorReadinessDirectoryWatch?
    private weak var controller: SupervisorWindowController?

    init(runtime: TerminalRuntime) {
        self.runtime = runtime
        source = SupervisorNativeSessionSource(runtime: runtime)
        let descriptor = open(runtime.root.path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor >= 0 {
            let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename], queue: .main)
            watcher.setEventHandler { [weak self] in
                self?.readinessWatch?.reconcile()
                self?.scheduleRefresh()
            }
            watcher.setCancelHandler { close(descriptor) }
            self.watcher = watcher
            watcher.resume()
        }
        readinessWatch = SupervisorReadinessDirectoryWatch(root: runtime.root, onChange: { [weak self] in
            self?.scheduleRefresh(readinessOnly: true)
        })
        readinessWatch?.reconcile()
    }

    func makeController(initialCWD: String,
                        makeLoadAccessory: @escaping @MainActor (SupervisorBinding) -> NSView? = { _ in nil },
                        captureTargetNavigation: @escaping @MainActor (SupervisorContinuationAuthority, SupervisorContinuationIdentity) -> SupervisorTargetActionOwner?) -> SupervisorWindowController {
        let source = source
        var services = SupervisorPanelServices(readState: { try source.read() }, start: { try source.start($0) },
            stop: { try source.stop($0, $1) },
            makeRenderer: { [weak self] in
                guard let self else { throw TerminalError.runtime("Supervisor renderer is unavailable") }
                return try self.makeRenderer($0)
            },
            synchronizeRenderer: { [weak self] view, binding in
                guard let self else { throw TerminalError.runtime("Supervisor renderer is unavailable") }
                try self.synchronize(view, binding: binding)
            },
            performRendererAction: { [weak self] action, view in self?.perform(action, view: view) ?? false },
            cachedAccounts: { source.cached()?.state.accounts ?? [] },
            cachedKeyBindings: { source.cached()?.state.settings.keyBindings ?? [:] },
            cachedKeySequenceHints: { source.cached()?.terminal.showKeySequenceHints ?? true })
        services.readReadiness = { try source.readReadiness($0) }
        let targetServices = SupervisorTargetActionServices(validateTarget: { try source.validateTarget($0, $1) },
            reviewInput: { try source.reviewInput($0, $1) }, captureOwner: { [weak self] authority, target in
                guard let self, let controller = self.controller, let window = controller.window,
                      controller.isPresented, controller.model.snapshot?.continuationAuthority == authority else { return nil }
                let navigation = captureTargetNavigation(authority, target)
                let open: (@MainActor (SupervisorContinuationIdentity) throws -> Void)?
                if let navigate = navigation?.goToSession {
                    open = { captured in
                        guard navigation?.isCurrent() == true else { throw TerminalError.invalid("Session window changed") }
                        try navigate(captured)
                    }
                } else { open = nil }
                return SupervisorTargetActionOwner(isCurrent: { [weak self, weak window] in
                    guard let self, let window, let current = self.controller else { return false }
                    return current.window === window && current.isPresented && window.isKeyWindow && NSApp.isActive &&
                        current.acceptsActions && current.model.snapshot?.continuationAuthority == authority
                }, goToSession: open)
            }, didReview: { [weak self] in self?.controller?.model.refreshReadiness() })
        let model = SupervisorPanelModel(services: services, configuration: SupervisorConfiguration(provider: .claude, cwd: initialCWD))
        let controller = SupervisorWindowController(model: model, makeLoadAccessory: makeLoadAccessory, targetActionServices: targetServices)
        self.controller = controller
        return controller
    }

    private func scheduleRefresh(readinessOnly: Bool = false) {
        if !readinessOnly { pendingFullRefresh = true }
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let full = self.pendingFullRefresh
            self.pendingFullRefresh = false
            guard let controller = self.controller, controller.isPresented else { return }
            if full { controller.model.refresh() } else { controller.model.refreshReadiness() }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
    }

    private func validatedSnapshot(_ binding: SupervisorBinding) throws -> SupervisorNativeSnapshot {
        guard let snapshot = source.cached() else { throw TerminalError.invalid("Load Supervisor state before connecting") }
        try snapshot.validate(binding)
        return snapshot
    }

    private func makeRenderer(_ binding: SupervisorBinding) throws -> NSView {
        do {
            let snapshot = try validatedSnapshot(binding)
            if rendererBinding?.paneID != binding.paneID || rendererBinding?.backendPID != binding.backendPID {
                discardRenderer()
            }
            let store = rendererStore ?? AppStore(runtime: runtime, bootstrapIfEmpty: false, recoverOnStartup: false, externalBinding: binding)
            store.isActiveWindow = { [weak self] in self?.controller?.window?.isKeyWindow == true }
            store.applyExternalSnapshot(snapshot.state, sessions: snapshot.sessions)
            store.themePreferences = snapshot.themes
            store.interfacePreferences = snapshot.interface
            store.terminalPreferences = snapshot.terminal
            store.developerPreferences = snapshot.developer
            let view = store.terminalViews[binding.paneID] ?? TranoView.makeClipboardTerminal(frame: .zero)
            view.paneID = binding.paneID
            view.store = store
            view.terminalContextSupports = { [weak self, weak view] action in
                guard let self, let view, self.rendererStore?.terminalViews[view.paneID] === view,
                      let controller = self.controller else { return false }
                return controller.acceptsActions && controller.supports(action)
            }
            view.terminalContextAction = { [weak self, weak view] action in
                guard let self, let view, self.rendererStore?.terminalViews[view.paneID] === view else { return false }
                return self.controller?.perform(action) ?? false
            }
            let theme = store.themeApplication(for: binding.paneID)
            configure(view, settings: theme.settings, store: store, paneID: binding.paneID, theme: theme)
            view.suspendsRenderingWhenNotVisible = true
            view.setAccessibilityLabel("Supervisor terminal")
            store.terminalViews[binding.paneID] = view
            rendererStore = store
            rendererBinding = binding
            return view
        } catch {
            discardRenderer()
            throw error
        }
    }

    private func synchronize(_ candidate: NSView, binding: SupervisorBinding) throws {
        do {
            let snapshot = try validatedSnapshot(binding)
            guard let view = candidate as? TranoView, let store = rendererStore,
                  rendererBinding?.paneID == binding.paneID, rendererBinding?.backendPID == binding.backendPID,
                  store.terminalViews[binding.paneID] === view else {
                throw TerminalError.invalid("Supervisor renderer binding changed")
            }
            store.applyExternalSnapshot(snapshot.state, sessions: snapshot.sessions)
            store.themePreferences = snapshot.themes
            store.interfacePreferences = snapshot.interface
            store.terminalPreferences = snapshot.terminal
            store.developerPreferences = snapshot.developer
            if fontSizeOverride != nil { store.terminalPreferences.fontSize = nil }
            view.window?.contentView?.layoutSubtreeIfNeeded()
            if view.bounds.width > 0 && view.bounds.height > 0 {
                view.synchronize(store: store, id: binding.paneID)
            }
            var settings = store.interfaceResolvedSettings(for: binding.paneID)
            if let size = fontSizeOverride { settings.fontSize = size }
            configure(view, settings: settings, store: store, paneID: binding.paneID, theme: store.themeApplication(for: binding.paneID))
        } catch {
            discardRenderer()
            throw error
        }
    }

    private func perform(_ action: ActionID, view candidate: NSView) -> Bool {
        guard let view = candidate as? TranoView, let store = rendererStore, let binding = rendererBinding,
              store.terminalViews[binding.paneID] === view else { return false }
        switch action {
        case .copy: view.copy(self)
        case .paste: view.paste(self)
        case .selectAll: view.selectAllWithTerminalPreferences(self)
        case .clear: view.clearScrollback()
        case .find, .findNext, .findPrevious:
            let item = NSMenuItem()
            item.tag = Int((action == .find ? NSFindPanelAction.showFindPanel : action == .findNext ? .next : .previous).rawValue)
            view.performFindPanelAction(item)
        case .increaseFont, .decreaseFont, .resetFont:
            var settings = store.interfaceResolvedSettings(for: binding.paneID)
            let current = fontSizeOverride ?? Double(view.font.pointSize)
            settings.fontSize = action == .resetFont ? 14 : min(40, max(9, current + (action == .increaseFont ? 1 : -1)))
            fontSizeOverride = settings.fontSize
            store.terminalPreferences.fontSize = nil
            configure(view, settings: settings, store: store, paneID: binding.paneID, theme: store.themeApplication(for: binding.paneID))
        default: return false
        }
        return true
    }

    private func configure(_ view: TranoView, settings: TerminalSettings, store: AppStore,
                           paneID: String, theme: ThemeApplication) {
        let profileAssigned = store.state.settings.paneAppearanceProfiles[paneID].map { id in
            store.state.settings.appearanceProfiles.contains { $0.id == id }
        } ?? false
        view.configure(settings, preferences: store.terminalPreferences, themeApplication: theme,
                       profileAssigned: profileAssigned)
    }

    private func discardRenderer() {
        if let store = rendererStore {
            for view in store.terminalViews.values { view.terminate() }
            store.terminalViews.removeAll()
        }
        rendererStore = nil
        rendererBinding = nil
        fontSizeOverride = nil
    }

    func shutdownFrontend() {
        readinessWatch?.stop()
        readinessWatch = nil
        watcher?.cancel()
        watcher = nil
        refreshWork?.cancel()
        discardRenderer()
    }

    deinit { watcher?.cancel(); refreshWork?.cancel() }
}
